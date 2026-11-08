import 'dart:convert';

import 'package:flutter/services.dart';

import 'ohos_linux_runtime.dart';

final checks = <String>[];
void check(String name, bool passed) {
  if (!passed) throw StateError(name);
  checks.add(name);
}

Map<String, Object?> status([Map<String, Object?> extra = const {}]) => {
  'v': 1,
  'instanceId': 'service-930',
  'attemptId': 'attempt-930',
  'state': 'enabled',
  'enabled': true,
  'admission': true,
  'guestOpened': true,
  'ownerRetained': true,
  'workspaceLease': false,
  'restartRequired': false,
  'shutdownComplete': false,
  'nextRequestId': 4,
  'ownerState': 'active',
  'backendState': 'opened',
  'progress': null,
  'lastErrorCode': null,
  'job': null,
  'retirement': null,
  ...extra,
};
Map<String, Object?> output(
  List<int> bytes, {
  int? total,
  bool truncated = false,
}) => {
  'encoding': 'base64',
  'data': base64Encode(bytes),
  'totalBytes': total ?? bytes.length,
  'retainedBytes': bytes.length,
  'truncated': truncated,
};
Map<String, Object?> job([Map<String, Object?> extra = const {}]) => {
  'id': 3,
  'state': 'running',
  'started': true,
  'cancelRequested': false,
  'outcome': null,
  'errorCode': null,
  'stdout': output([0, 255, 226, 130]),
  'stderr': output([]),
  ...extra,
};
Map<String, Object?> retirement([Map<String, Object?> extra = const {}]) => {
  'resourcesRetired': true,
  'filesRemoved': false,
  'dataRetained': true,
  'ownerQuarantined': true,
  'native': {'joined': true, 'retirementError': false, 'apiResult': -4},
  'releaseErrorCode': null,
  ...extra,
};
bool rejects(Map<String, Object?> value) {
  try {
    OhosLinuxSnapshot.fromWire(jsonEncode(value));
    return false;
  } on FormatException {
    return true;
  }
}

Future<void> main() async {
  final scope = OhosLinuxSnapshot.fromWire(jsonEncode(status()));
  check(
    'opened private guest admits explicit jobs without granting host workspace',
    scope.admission && !scope.workspaceLease,
  );
  final installing = OhosLinuxSnapshot.fromWire(
    jsonEncode(status({'state': 'installing', 'guestOpened': false})),
  );
  check('installation acceptance is not admission', !installing.admission);
  final future = OhosLinuxSnapshot.fromWire(
    jsonEncode(status({'state': 'future-state'})),
  );
  check(
    'future state fails closed',
    future.state == OhosLinuxState.unknown && !future.admission,
  );
  final running = OhosLinuxSnapshot.fromWire(
    jsonEncode(status({'job': job()})),
  );
  check(
    'binary tail retains NUL, non-UTF8 and partial UTF8 without replacing bytes',
    base64Encode(running.job!.stdout.bytes) ==
            base64Encode([0, 255, 226, 130]) &&
        !running.job!.settled,
  );
  bool immutable = false;
  try {
    running.job!.stdout.bytes[0] = 1;
  } on UnsupportedError {
    immutable = true;
  }
  check('output observation is immutable', immutable);
  final cancelled = OhosLinuxSnapshot.fromWire(
    jsonEncode(
      status({
        'job': job({
          'state': 'settled',
          'cancelRequested': true,
          'outcome': {
            'exitCode': null,
            'signal': 'SIGKILL',
            'cancelled': true,
            'requestedSignal': 'SIGTERM',
          },
        }),
      }),
    ),
  );
  check(
    'actual signal and requested signal remain separate',
    cancelled.job!.outcome!.signal == 'SIGKILL' &&
        cancelled.job!.outcome!.requestedSignal == 'SIGTERM' &&
        cancelled.job!.outcome!.exitCode == null,
  );
  final unknown = OhosLinuxSnapshot.fromWire(
    jsonEncode(
      status({
        'state': 'unknown',
        'job': job({'state': 'unknown'}),
        'shutdownComplete': true,
        'retirement': retirement(),
      }),
    ),
  );
  check(
    'historical job unknown survives proven resource retirement',
    unknown.job!.state == 'unknown' &&
        unknown.job!.outcome == null &&
        unknown.shutdownComplete &&
        unknown.retirement!.dataRetained &&
        !unknown.retirement!.filesRemoved,
  );
  check(
    'false join cannot confirm shutdown',
    rejects(
      status({
        'shutdownComplete': true,
        'retirement': retirement({
          'native': {'joined': false, 'retirementError': false, 'apiResult': 0},
        }),
      }),
    ),
  );
  check(
    'retirement error cannot confirm shutdown',
    rejects(
      status({
        'shutdownComplete': true,
        'retirement': retirement({
          'native': {'joined': true, 'retirementError': true, 'apiResult': -8},
        }),
      }),
    ),
  );
  check(
    'unobserved retirement cannot confirm shutdown',
    rejects(status({'shutdownComplete': true})),
  );
  final unjoined = OhosLinuxSnapshot.fromWire(
    jsonEncode(
      status({
        'state': 'unknown',
        'retirement': retirement({
          'resourcesRetired': false,
          'native': {
            'joined': false,
            'retirementError': null,
            'apiResult': null,
          },
        }),
      }),
    ),
  );
  check(
    'actual unjoined native null facts remain visible',
    unjoined.retirement!.nativeJoined == false &&
        unjoined.retirement!.nativeRetirementError == null &&
        unjoined.retirement!.nativeApiResult == null &&
        !unjoined.shutdownComplete,
  );
  check(
    'missing retirement error fact cannot confirm even a joined native',
    rejects(
      status({
        'shutdownComplete': true,
        'retirement': retirement({
          'native': {
            'joined': true,
            'retirementError': null,
            'apiResult': null,
          },
        }),
      }),
    ),
  );
  check(
    'unknown protocol version cannot grant admission',
    rejects(status({'v': 2})),
  );
  check(
    'host workspace grant cannot be inferred',
    rejects(status({'workspaceLease': true})),
  );
  check(
    'unsafe request integer rejected',
    rejects(status({'nextRequestId': 9007199254740992})),
  );
  check(
    'output metadata mismatch rejected',
    rejects(
      status({
        'job': job({
          'stdout': {
            ...output([1]),
            'retainedBytes': 2,
          },
        }),
      }),
    ),
  );
  check(
    'unknown job cannot carry fabricated success',
    rejects(
      status({
        'job': job({
          'state': 'unknown',
          'outcome': {'exitCode': 0, 'signal': null, 'cancelled': false},
        }),
      }),
    ),
  );

  final calls = <Map<String, Object?>>[];
  MethodChannel.handler = (channel, method, arguments) async {
    calls.add({'channel': channel, 'method': method, 'arguments': arguments});
    return jsonEncode(status());
  };
  const client = OhosLinuxRuntime();
  await client.getStatus();
  await client.setEnabled(false);
  final argv = ['python3', '-c', 'print("中文")'];
  await client.runPrivateGuest(
    scope: scope,
    argv: argv,
    cwd: '/workspace',
    environment: {'TEST_VALUE': 'a b'},
    stdin: 'input\n',
  );
  await client.runPrivateGuest(
    scope: scope,
    argv: argv,
    cwd: '/workspace',
    environment: {'TEST_VALUE': 'a b'},
    stdin: 'input\n',
  );
  check(
    'uses existing OH runtime MethodChannel with no host URL or token argument',
    calls.every((row) => row['channel'] == 'dsh/runtime') &&
        calls.first['method'] == 'getLinuxStatus' &&
        calls.first['arguments'] == null,
  );
  check(
    'switch false is explicit',
    (calls[1]['arguments'] as Map)['enabled'] == false,
  );
  check(
    'retry keeps the original identity, argv and private cwd',
    jsonEncode(calls[2]) == jsonEncode(calls[3]) &&
        (calls[2]['arguments'] as Map)['requestId'] == 4 &&
        (calls[2]['arguments'] as Map)['cwd'] == '/workspace',
  );
  MethodChannel.handler = (_, __, ___) async =>
      throw PlatformException(code: 'ERR_OHOS_LINUX_STALE');
  bool preserved = false;
  try {
    await client.getStatus();
  } on PlatformException catch (error) {
    preserved = error.code == 'ERR_OHOS_LINUX_STALE';
  }
  check('platform failure code remains inspectable', preserved);
  print(
    jsonEncode({
      'status': 'PASS',
      'checks': checks,
      'calls': calls.length,
      'scope': 'actual Dart model and channel client; explicit Flutter services boundary, not Flutter engine or OH device',
    }),
  );
}
