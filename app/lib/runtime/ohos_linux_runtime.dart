import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

enum OhosLinuxState {
  disabled,
  installing,
  enabled,
  disabling,
  stopping,
  stopped,
  unavailable,
  failed,
  unknown;

  static OhosLinuxState parse(Object? value) =>
      values.firstWhere((state) => state.name == value, orElse: () => unknown);
}

Never _invalid() =>
    throw const FormatException('Invalid OHOS Linux protocol response');
Map<Object?, Object?> _map(Object? value) => value is Map ? value : _invalid();
bool _bool(Object? value) => value is bool ? value : _invalid();
String _string(Object? value) => value is String ? value : _invalid();
String? _optionalString(Object? value) => value == null ? null : _string(value);
int _integer(Object? value) =>
    value is int && value >= 0 && value <= 9007199254740991
    ? value
    : _invalid();

/// Stable raw bytes already accepted by the Node collector. Reading this value
/// does not acknowledge guest output and cannot complete a running job.
class OhosLinuxOutput {
  OhosLinuxOutput._(this.bytes, this.totalBytes, this.truncated);

  factory OhosLinuxOutput.fromMap(Object? raw) {
    final value = _map(raw);
    if (value['encoding'] != 'base64') _invalid();
    final encoded = _string(value['data']);
    final bytes = base64.decode(encoded);
    final total = _integer(value['totalBytes']);
    final retained = _integer(value['retainedBytes']);
    final truncated = _bool(value['truncated']);
    if (base64.encode(bytes) != encoded ||
        bytes.length > 16384 ||
        retained != bytes.length ||
        total < retained ||
        (total > retained && !truncated))
      _invalid();
    return OhosLinuxOutput._(bytes.asUnmodifiableView(), total, truncated);
  }

  final Uint8List bytes;
  final int totalBytes;
  final bool truncated;
  String get text => utf8.decode(bytes, allowMalformed: true);
}

class OhosLinuxOutcome {
  OhosLinuxOutcome._(
    this.exitCode,
    this.signal,
    this.cancelled,
    this.notStarted,
    this.requestedSignal,
  );

  factory OhosLinuxOutcome.fromMap(Object? raw) {
    final value = _map(raw);
    final exit = value['exitCode'] == null ? null : _integer(value['exitCode']);
    final signal = _optionalString(value['signal']);
    final cancelled = _bool(value['cancelled']);
    final notStarted = value['notStarted'] == true;
    if ((exit != null && exit > 255) ||
        (signal != null && !RegExp(r'^SIG[A-Z0-9]+$').hasMatch(signal)) ||
        (exit != null && signal != null) ||
        (exit == null && signal == null && !(cancelled && notStarted)))
      _invalid();
    return OhosLinuxOutcome._(
      exit,
      signal,
      cancelled,
      notStarted,
      _optionalString(value['requestedSignal']),
    );
  }

  final int? exitCode;
  final String? signal;
  final bool cancelled;
  final bool notStarted;
  final String? requestedSignal;
}

class OhosLinuxJob {
  OhosLinuxJob._(
    this.id,
    this.state,
    this.started,
    this.cancelRequested,
    this.outcome,
    this.errorCode,
    this.stdout,
    this.stderr,
  );

  factory OhosLinuxJob.fromMap(Object? raw) {
    final value = _map(raw);
    final id = _integer(value['id']);
    final state = _string(value['state']);
    if (id < 1) _invalid();
    final knownState =
        const {'queued', 'running', 'settled', 'unknown'}.contains(state)
        ? state
        : 'unknown';
    final outcome = value['outcome'] == null
        ? null
        : OhosLinuxOutcome.fromMap(value['outcome']);
    if ((knownState == 'settled') != (outcome != null)) _invalid();
    return OhosLinuxJob._(
      id,
      knownState,
      _bool(value['started']),
      _bool(value['cancelRequested']),
      outcome,
      _optionalString(value['errorCode']),
      OhosLinuxOutput.fromMap(value['stdout']),
      OhosLinuxOutput.fromMap(value['stderr']),
    );
  }

  final int id;
  final String state;
  final bool started;
  final bool cancelRequested;
  final OhosLinuxOutcome? outcome;
  final String? errorCode;
  final OhosLinuxOutput stdout;
  final OhosLinuxOutput stderr;
  bool get settled => state == 'settled';
}

class OhosLinuxProgress {
  OhosLinuxProgress._(this.stage, this.done, this.total, this.step);

  factory OhosLinuxProgress.fromMap(Object? raw) {
    final value = _map(raw);
    return OhosLinuxProgress._(
      _string(value['stage']),
      value['done'] == null ? null : _integer(value['done']),
      value['total'] == null ? null : _integer(value['total']),
      _optionalString(value['step']),
    );
  }

  final String stage;
  final int? done;
  final int? total;
  final String? step;
}

class OhosLinuxRetirement {
  OhosLinuxRetirement._(
    this.resourcesRetired,
    this.filesRemoved,
    this.dataRetained,
    this.ownerQuarantined,
    this.nativeJoined,
    this.nativeRetirementError,
    this.nativeApiResult,
    this.releaseErrorCode,
  );

  factory OhosLinuxRetirement.fromMap(Object? raw) {
    final value = _map(raw);
    final native = value['native'] == null ? null : _map(value['native']);
    final result = native?['apiResult'];
    if (result != null && result is! int) _invalid();
    return OhosLinuxRetirement._(
      _bool(value['resourcesRetired']),
      _bool(value['filesRemoved']),
      _bool(value['dataRetained']),
      _bool(value['ownerQuarantined']),
      native == null ? null : _bool(native['joined']),
      native?['retirementError'] == null
          ? null
          : _bool(native!['retirementError']),
      result as int?,
      _optionalString(value['releaseErrorCode']),
    );
  }

  final bool resourcesRetired;
  final bool filesRemoved;
  final bool dataRetained;
  final bool ownerQuarantined;
  final bool? nativeJoined;
  final bool? nativeRetirementError;
  final int? nativeApiResult;
  final String? releaseErrorCode;
  bool get confirmed =>
      resourcesRetired &&
      (nativeJoined == null
          ? !ownerQuarantined
          : nativeJoined == true && nativeRetirementError == false);
}

/// A read-only observation of the one Node service. It does not grant a host
/// workspace or enable the generic shell/child_process routing.
class OhosLinuxSnapshot {
  OhosLinuxSnapshot._(
    this.instanceId,
    this.attemptId,
    this.state,
    this.enabled,
    this.admission,
    this.guestOpened,
    this.ownerRetained,
    this.restartRequired,
    this.shutdownComplete,
    this.nextRequestId,
    this.ownerState,
    this.backendState,
    this.progress,
    this.lastErrorCode,
    this.job,
    this.retirement,
  );

  factory OhosLinuxSnapshot.fromWire(String wire) {
    final value = _map(jsonDecode(wire));
    if (value['v'] != 1 || value['workspaceLease'] != false) _invalid();
    final instance = _string(value['instanceId']);
    final next = _integer(value['nextRequestId']);
    final state = OhosLinuxState.parse(value['state']);
    final opened = _bool(value['guestOpened']);
    final requestedAdmission = _bool(value['admission']);
    final shutdown = _bool(value['shutdownComplete']);
    final retirement = value['retirement'] == null
        ? null
        : OhosLinuxRetirement.fromMap(value['retirement']);
    if (instance.isEmpty ||
        next < 1 ||
        (shutdown && retirement?.confirmed != true))
      _invalid();
    return OhosLinuxSnapshot._(
      instance,
      _optionalString(value['attemptId']),
      state,
      _bool(value['enabled']),
      state == OhosLinuxState.enabled &&
          opened &&
          requestedAdmission &&
          !shutdown,
      opened,
      _bool(value['ownerRetained']),
      _bool(value['restartRequired']),
      shutdown,
      next,
      _optionalString(value['ownerState']),
      _optionalString(value['backendState']),
      value['progress'] == null
          ? null
          : OhosLinuxProgress.fromMap(value['progress']),
      _optionalString(value['lastErrorCode']),
      value['job'] == null ? null : OhosLinuxJob.fromMap(value['job']),
      retirement,
    );
  }

  final String instanceId;
  final String? attemptId;
  final OhosLinuxState state;
  final bool enabled;
  final bool admission;
  final bool guestOpened;
  final bool ownerRetained;
  final bool restartRequired;
  final bool shutdownComplete;
  final int nextRequestId;
  final String? ownerState;
  final String? backendState;
  final OhosLinuxProgress? progress;
  final String? lastErrorCode;
  final OhosLinuxJob? job;
  final OhosLinuxRetirement? retirement;
  bool get workspaceLease => false;
}

/// OHOS-only data/MethodChannel client. A 202 acceptance is a snapshot, not a
/// completed installation or command. The caller may poll [getStatus].
class OhosLinuxRuntime {
  const OhosLinuxRuntime({
    MethodChannel channel = const MethodChannel('dsh/runtime'),
  }) : _channel = channel;
  final MethodChannel _channel;

  Future<OhosLinuxSnapshot> _call(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    final wire = await _channel.invokeMethod<String>(method, arguments);
    if (wire == null) _invalid();
    return OhosLinuxSnapshot.fromWire(wire);
  }

  Future<OhosLinuxSnapshot> getStatus() => _call('getLinuxStatus');
  Future<OhosLinuxSnapshot> setEnabled(bool enabled) =>
      _call('setLinuxEnabled', {'enabled': enabled});

  /// Keep [scope] when retrying an uncertain transport result. Its fixed request
  /// identity prevents a retry from executing the command a second time.
  Future<OhosLinuxSnapshot> runPrivateGuest({
    required OhosLinuxSnapshot scope,
    required List<String> argv,
    required String cwd,
    Map<String, String> environment = const {},
    String stdin = '',
  }) {
    if (scope.attemptId == null)
      throw StateError('Linux has no installation attempt');
    return _call('runLinuxPrivateGuest', {
      'instanceId': scope.instanceId,
      'attemptId': scope.attemptId,
      'requestId': scope.nextRequestId,
      'argv': List<String>.of(argv),
      'cwd': cwd,
      'env': Map<String, String>.of(environment),
      'stdin': stdin,
    });
  }
}
