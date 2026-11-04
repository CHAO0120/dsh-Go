// 「我的分享链接」, the hosted links made on this phone. Each holds its
// decryption key and delete token, so the list lives in the Keystore-backed
// secure storage, like the API keys (settings_state.dart).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../secrets/secure_storage.dart';
import 'hosted_client.dart';
import 'hosted_link.dart';

abstract class HostedLinkStore {
  Future<List<HostedLink>> load();
  Future<void> save(List<HostedLink> links);
}

class SecureHostedLinkStore implements HostedLinkStore {
  const SecureHostedLinkStore([this._injected]);

  static const storageKey = 'hosted_links';
  final FlutterSecureStorage? _injected;
  AppSecureStorage get _storage => AppSecureStorage(_injected);

  @override
  Future<List<HostedLink>> load() async {
    final raw = await _storage.read(key: storageKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return [for (final item in list) ?HostedLink.fromJson(item)];
    } on FormatException {
      return const [];
    }
  }

  @override
  Future<void> save(List<HostedLink> links) =>
      _storage.write(key: storageKey, value: jsonEncode([for (final l in links) l.toJson()]));
}

final hostedLinkStoreProvider = Provider<HostedLinkStore>((ref) => const SecureHostedLinkStore());

final hostedShareClientProvider = Provider<HostedShareClient>((ref) {
  final client = HostedShareClient();
  ref.onDispose(client.close);
  return client;
});

/// A delete that didn't go through; the link is back in the list.
class HostedDeleteFailure {
  const HostedDeleteFailure(this.link, this.error);
  final HostedLink link;
  final HostedShareException error;
}

enum HostedStorageError { read, save }

enum HostedUndoResult { restored, sessionOnly, unavailable }

class HostedStorageException implements Exception {
  const HostedStorageException();
}

class HostedLinksState {
  const HostedLinksState({this.links = const [], this.loaded = false, this.failure, this.storageError});

  /// Newest first, including links waiting out the undo window.
  final List<HostedLink> links;
  final bool loaded;
  final HostedDeleteFailure? failure;
  final HostedStorageError? storageError;

  /// What 「我的分享链接」 shows.
  List<HostedLink> get visible => [
    for (final l in links)
      if (!l.deleting) l,
  ];
}

class HostedLinksController extends Notifier<HostedLinksState> {
  /// How long a deleted link can be brought back.
  static const undoWindow = Duration(seconds: 4);

  /// Expired links stay listed (as 已过期) this long, then drop off.
  static const keepExpired = Duration(days: 30);

  final _timers = <String, Timer>{};
  final _cancelled = <String>{};
  final _deleting = <String>{};
  final _unsaved = <String>{};
  final _revisions = <String, int>{};
  Future<void> _tail = Future.value();
  late Future<void> _ready;

  // Only local read/modify/save operations belong here. Never await HTTP here.
  Future<T> _local<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  @override
  HostedLinksState build() {
    ref.onDispose(() {
      for (final t in _timers.values) {
        t.cancel();
      }
      _timers.clear();
    });
    _ready = _local(() async {
      await _load();
    });
    return const HostedLinksState();
  }

  /// Completes once the saved list is in.
  Future<void> get ready => _ready;
  bool isPersisted(String id) => !_unsaved.contains(id);

  void _put(List<HostedLink> links, {HostedStorageError? error, HostedDeleteFailure? failure}) {
    state = HostedLinksState(
      links: links,
      loaded: state.loaded,
      storageError: error,
      failure: failure ?? state.failure,
    );
  }

  Future<bool> _load() async {
    if (!ref.mounted) return false;
    try {
      final saved = await ref.read(hostedLinkStoreProvider).load();
      if (!ref.mounted) return false;
      final cutoff = DateTime.now().subtract(keepExpired);
      final links = [
        for (final l in saved)
          if (l.expiresAt == null || l.expiresAt!.isAfter(cutoff)) l,
      ];
      state = HostedLinksState(links: links, loaded: true);
      if (links.length != saved.length) await _save(links);
      for (final l in links) {
        if (l.deleting) unawaited(_commit(l.id));
      }
      return true;
    } catch (_) {
      if (ref.mounted) state = const HostedLinksState(storageError: HostedStorageError.read);
      return false;
    }
  }

  /// Opening the page or the next operation retries an unsuccessful read.
  Future<bool> ensureLoaded() async {
    await _ready;
    if (!ref.mounted) return false;
    if (state.loaded) return true;
    return _local(() async => ref.mounted && (state.loaded || await _load()));
  }

  /// Also persists a session-only undo or a newly uploaded, unsaved link.
  Future<bool> retry() async {
    await _ready;
    return _local(() async {
      if (!ref.mounted) return false;
      return state.loaded ? _save(state.links) : _load();
    });
  }

  Future<bool> _save(List<HostedLink> links) async {
    if (!ref.mounted) return false;
    try {
      await ref.read(hostedLinkStoreProvider).save(links);
      if (!ref.mounted) return false;
      _unsaved.clear();
      _put(state.links);
      return true;
    } catch (_) {
      if (ref.mounted) _put(state.links, error: HostedStorageError.save);
      return false;
    }
  }

  HostedLink? _find(String id) {
    for (final l in state.links) {
      if (l.id == id) return l;
    }
    return null;
  }

  /// Encrypts and uploads [file] (a `.dshgo` file's bytes), keeps the link and
  /// returns it. Throws [HostedShareException].
  Future<HostedLink> publish(Uint8List file, {required String title, HostedTtl ttl = HostedTtl.fallback}) async {
    if (!await ensureLoaded()) throw const HostedStorageException();
    final link = await ref.read(hostedShareClientProvider).upload(file, ttl, title: title);
    await add(link);
    return link;
  }

  Future<bool> add(HostedLink link) async {
    if (!await ensureLoaded()) return false;
    return _local(() async {
      if (!ref.mounted) return false;
      _revisions.update(link.id, (v) => v + 1, ifAbsent: () => 1);
      _unsaved.add(link.id);
      _put([
        link,
        for (final l in state.links)
          if (l.id != link.id) l,
      ], error: state.storageError);
      return _save(state.links);
    });
  }

  /// Hides [id] once that's saved, and deletes it on the host when [undoWindow]
  /// passes without [undo]. False if it couldn't be saved, and the link stays.
  Future<bool> remove(String id) async {
    if (!await ensureLoaded()) return false;
    return _local(() async {
      if (!ref.mounted || _find(id) == null || _deleting.contains(id)) return false;
      final marked = [for (final l in state.links) l.id == id ? l.copyWith(deleting: true) : l];
      if (!await _save(marked)) return false;
      _cancelled.remove(id);
      _put(marked);
      _timers.remove(id)?.cancel();
      _timers[id] = Timer(undoWindow, () {
        _timers.remove(id);
        unawaited(_commit(id));
      });
      return true;
    });
  }

  Future<HostedUndoResult> undo(String id) async {
    // Cancel immediately, even if an earlier local write is still outstanding.
    _timers.remove(id)?.cancel();
    _cancelled.add(id);
    if (!await ensureLoaded()) return HostedUndoResult.unavailable;
    return _local(() async {
      if (!ref.mounted || _find(id) == null || _deleting.contains(id)) return HostedUndoResult.unavailable;
      _put([for (final l in state.links) l.id == id ? l.copyWith(deleting: false) : l], error: state.storageError);
      return await _save(state.links) ? HostedUndoResult.restored : HostedUndoResult.sessionOnly;
    });
  }

  Future<void> _commit(String id) async {
    final pending = await _local(() async {
      if (!ref.mounted || _cancelled.contains(id) || _deleting.contains(id)) return null;
      final link = _find(id);
      if (link == null || !link.deleting) return null;
      _deleting.add(id);
      return (link, _revisions[id] ?? 0);
    });
    if (pending == null) return;
    final (link, revision) = pending;
    HostedShareException? failure;
    try {
      await ref.read(hostedShareClientProvider).delete(link);
    } catch (e) {
      failure = e is HostedShareException ? e : const HostedShareException(HostedShareError.network);
    }
    await _local(() async {
      _deleting.remove(id);
      if (!ref.mounted || (_revisions[id] ?? 0) != revision) return;
      // Merge into the current list: uploads and unrelated edits may have finished.
      if (failure == null) {
        _put([
          for (final l in state.links)
            if (l.id != id) l,
        ], error: state.storageError);
      } else {
        _put(
          [for (final l in state.links) l.id == id ? l.copyWith(deleting: false) : l],
          error: state.storageError,
          failure: HostedDeleteFailure(link.copyWith(deleting: false), failure),
        );
      }
      await _save(state.links);
    });
  }
}

final hostedLinksProvider = NotifierProvider<HostedLinksController, HostedLinksState>(HostedLinksController.new);
