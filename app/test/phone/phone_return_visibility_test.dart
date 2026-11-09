import 'dart:async';

import 'package:dsh_app/notify/chat_alerts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/chat_reveal.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_app/state/phone_turn_end.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notify/support.dart' as notify;
import 'support.dart';

class _Client extends DshClient {
  _Client() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));
  final ownerSnapshot = Completer<List<SessionSummary>>();
  final requests = <Completer<List<SessionSummary>>>[];
  final events = StreamController<HostEvent>.broadcast(sync: true);

  @override
  Stream<HostEvent> get hostEvents => events.stream;

  @override
  Future<List<SessionSummary>> listSessions() {
    final request = requests.isEmpty ? ownerSnapshot : Completer<List<SessionSummary>>();
    requests.add(request);
    return request.future;
  }
}

// Observe the real deferral rather than infer it from an empty notification list.
class _ObservedTurnEnd extends PhoneTurnEndController {
  final deferred = Completer<void>();
  final resumed = Completer<void>();

  @override
  bool deferTurnEnd(ChatAlert alert, void Function() ready) {
    final accepted = super.deferTurnEnd(alert, () {
      ready();
      if (!resumed.isCompleted) resumed.complete();
    });
    if (accepted && !deferred.isCompleted) deferred.complete();
    return accepted;
  }
}

class _Local extends LocalConnectionController {
  _Local(this.client);
  final DshClient client;

  @override
  Future<HostConnection?> build() async => HostConnection(client: client, label: 'local', isLocal: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Client client;
  late FakePhoneNative native;
  late notify.FakeNotifyChannel channel;
  late notify.FakeAlertSource source;
  late ProviderContainer container;
  late Future<void> Function() close;

  Future<void> make({
    bool delayOwner = false,
    bool doneAllowed = false,
    WidgetTester? clock,
    _ObservedTurnEnd? observed,
  }) async {
    Future<void> flush() => clock == null ? notify.settle() : clock.pump();
    SharedPreferences.setMockInitialValues({'notify_done': doneAllowed});
    client = _Client();
    if (!delayOwner) client.ownerSnapshot.complete([notify.session('s1', running: true)]);
    native = FakePhoneNative(status: phoneStatus(taskActive: true, taskId: 1))..install();
    channel = notify.FakeNotifyChannel();
    source = notify.FakeAlertSource()..sessions = [notify.session('s1', running: true), notify.session('s2')];
    final connection = HostConnection(client: client, label: 'local', isLocal: true);
    container = ProviderContainer(
      overrides: [
        if (observed != null) phoneTurnEndProvider.overrideWith(() => observed),
        notifyChannelProvider.overrideWithValue(channel),
        alertSourceFactoryProvider.overrideWithValue((_) => source),
        alertTimingProvider.overrideWithValue((announce: Duration.zero, reconcile: const Duration(milliseconds: 30))),
        localConnectionProvider.overrideWith(() => _Local(client)),
        activeConnectionProvider.overrideWithValue(AsyncData(connection)),
      ],
    );
    Future<void>? closing;
    close = () => closing ??= () async {
      container.dispose();
      if (clock != null) {
        // Cancel the real Future.timeout even when an earlier assertion failed.
        for (final request in client.requests) {
          if (!request.isCompleted) request.complete([]);
        }
        await clock.pump();
      }
      await client.events.close();
      await client.close();
    }();
    addTearDown(close);
    try {
      container.listen(phoneTurnEndProvider, (_, _) {});
      container.listen(chatAlertsProvider, (_, _) {});
      await flush();
      container.read(appForegroundProvider.notifier).set(false);
      await flush();
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<void> end(String sessionId, {WidgetTester? clock}) async {
    source.outcomes[sessionId] = notify.outcome(10, 'completed', reply: 'fixture');
    source.emit(SessionStatusEvent(sessionId, false));
    if (clock == null) {
      await notify.settle();
    } else {
      await clock.pump();
    }
  }

  test('a rejected activity launch still leaves a result notification for the owning turn', () async {
    await make();
    native.finish = {'closed': true, 'opened': false, 'launched': false};
    await end('s1');
    expect(native.callsOf('finishTask'), hasLength(1));
    expect(
      channel.shown,
      hasLength(1),
      reason: 'No launch exception or silent BAL rejection may erase the return path.',
    );
    expect(channel.shown.single.sessionId, 's1');
  });

  test('an end arriving before the same task owner snapshot is handled once evidence arrives', () async {
    await make(delayOwner: true);
    await end('s1');
    expect(native.callsOf('finishTask'), isEmpty);
    // This is the initial request's delayed response, not a new post-end scan.
    client.ownerSnapshot.complete([notify.session('s1', running: true)]);
    await notify.settle();
    expect(native.callsOf('finishTask'), hasLength(1));
    expect((native.callsOf('finishTask').single.arguments as Map)['taskId'], 1);
  });

  test('a delayed owner snapshot never uses an unrelated ended conversation', () async {
    await make(delayOwner: true);
    await end('s2');
    client.ownerSnapshot.complete([notify.session('s1', running: true)]);
    await notify.settle();
    expect(native.callsOf('finishTask'), isEmpty);
  });

  test('a delayed ambiguous owner snapshot still refuses automatic finish', () async {
    await make(delayOwner: true);
    await end('s1');
    client.ownerSnapshot.complete([notify.session('s1', running: true), notify.session('s2', running: true)]);
    await notify.settle();
    expect(native.callsOf('finishTask'), isEmpty);
  });

  test('a new run while the initial owner read is pending retires the old end', () async {
    await make(delayOwner: true, doneAllowed: true);
    await end('s1');
    expect(channel.shown, isEmpty);
    client.events.add(const SessionStatusEvent('s1', true));
    source.emit(const SessionStatusEvent('s1', true));
    client.ownerSnapshot.complete([notify.session('s1', running: true)]);
    await notify.settle();
    expect(native.callsOf('finishTask'), isEmpty);
    expect(container.read(phoneTurnEndProvider.notifier).link.armed, isFalse);
    expect(channel.shown, isEmpty, reason: 'A retired end cannot fall back to an ordinary notification.');
  });

  test('a new native task cannot inherit the old deferred end', () async {
    await make(delayOwner: true, doneAllowed: true);
    await end('s1');
    expect(channel.shown, isEmpty);
    native.push(phoneStatus(taskActive: true, taskId: 2));
    await notify.settle();
    expect(client.requests, hasLength(2));
    client.requests.last.complete([notify.session('s2', running: true)]);
    client.ownerSnapshot.complete([notify.session('s1', running: true)]);
    await notify.settle();
    expect(native.callsOf('finishTask'), isEmpty);
    expect(container.read(phoneTurnEndProvider.notifier).link.candidates, {'s2'});
    expect(channel.shown, isEmpty, reason: 'Replacing the native task retires its pending ordinary notice too.');
    source.emit(const SessionStatusEvent('s2', true));
    await notify.settle();
    await end('s2');
    expect(native.callsOf('finishTask'), hasLength(1));
    expect((native.callsOf('finishTask').single.arguments as Map)['taskId'], 2);
  });

  test('a closed native task with a retired result cannot reveal or notify', () async {
    await make(doneAllowed: true);
    native.finish = {'closed': true, 'opened': true, 'launched': true, 'current': false};
    await end('s1');
    expect(native.callsOf('finishTask'), hasLength(1));
    expect(container.read(chatRevealProvider), isNull);
    expect(channel.shown, isEmpty);
  });

  test('the native result notification is not duplicated by Dart', () async {
    await make();
    native.finish = {'closed': true, 'opened': false, 'launched': false, 'notified': true};
    await end('s1');
    expect(native.callsOf('finishTask'), hasLength(1));
    expect(channel.shown, isEmpty);
  });

  testWidgets('a pending owner read times out without later finishing the task', (tester) async {
    final observed = _ObservedTurnEnd();
    await make(delayOwner: true, clock: tester, observed: observed);
    try {
      expect(container.read(phoneTurnEndProvider.notifier), same(observed));
      expect(client.requests, hasLength(1), reason: 'The actual owner read must have entered.');
      expect(client.ownerSnapshot.isCompleted, isFalse);
      await end('s1', clock: tester);
      expect(observed.deferred.isCompleted, isTrue, reason: 'The real controller must register the end.');
      expect(observed.resumed.isCompleted, isFalse);
      await tester.pump(PhoneTurnEndController.ownerWait);
      expect(observed.resumed.isCompleted, isTrue, reason: 'The original timeout must release the deferred end.');
      client.ownerSnapshot.complete([notify.session('s1', running: true)]);
      await tester.pump();
      expect(native.callsOf('finishTask'), isEmpty);
      expect(channel.shown, isEmpty);
    } finally {
      await close();
    }
  });

  test('an ambiguous initial owner still releases the ordinary notice exactly once', () async {
    await make(delayOwner: true, doneAllowed: true);
    await end('s1');
    expect(channel.shown, isEmpty);
    client.ownerSnapshot.complete([notify.session('s1', running: true), notify.session('s2', running: true)]);
    await notify.settle();
    expect(native.callsOf('finishTask'), isEmpty);
    expect(channel.shown.map((post) => (post.kind, post.sessionId)), [('done', 's1')]);
    await notify.settle();
    expect(channel.shown, hasLength(1));
  });

  test('a failed initial owner read still releases the ordinary notice', () async {
    await make(delayOwner: true, doneAllowed: true);
    await end('s1');
    expect(channel.shown, isEmpty);
    client.ownerSnapshot.completeError(StateError('fixture owner read failed'));
    await notify.settle();
    expect(native.callsOf('finishTask'), isEmpty);
    expect(channel.shown.map((post) => (post.kind, post.sessionId)), [('done', 's1')]);
  });

  testWidgets('an initial owner timeout releases one ordinary notice and ignores its late reply', (tester) async {
    final observed = _ObservedTurnEnd();
    await make(delayOwner: true, doneAllowed: true, clock: tester, observed: observed);
    try {
      expect(container.read(phoneTurnEndProvider.notifier), same(observed));
      expect(client.requests, hasLength(1), reason: 'The actual owner read must have entered.');
      expect(client.ownerSnapshot.isCompleted, isFalse);
      await end('s1', clock: tester);
      expect(observed.deferred.isCompleted, isTrue, reason: 'The real controller must register the end.');
      expect(observed.resumed.isCompleted, isFalse);
      expect(channel.shown, isEmpty);
      await tester.pump(PhoneTurnEndController.ownerWait);
      expect(observed.resumed.isCompleted, isTrue, reason: 'The original timeout must release the deferred end.');
      expect(native.callsOf('finishTask'), isEmpty);
      expect(channel.shown.map((post) => (post.kind, post.sessionId)), [('done', 's1')]);
      client.ownerSnapshot.complete([notify.session('s1', running: true)]);
      await tester.pump();
      expect(native.callsOf('finishTask'), isEmpty);
      expect(channel.shown, hasLength(1));
    } finally {
      await close();
    }
  });

  test('an expired native task discards its deferred ordinary notice', () async {
    await make(delayOwner: true, doneAllowed: true);
    await end('s1');
    expect(channel.shown, isEmpty);
    native.push(phoneStatus(taskActive: false, taskId: 1));
    await notify.settle();
    client.ownerSnapshot.complete([notify.session('s1', running: true)]);
    await notify.settle();
    expect(native.callsOf('finishTask'), isEmpty);
    expect(channel.shown, isEmpty);
    expect(container.read(phoneTurnEndProvider.notifier).link.armed, isFalse);
  });
}
