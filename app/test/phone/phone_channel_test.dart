// The typed wrapper over `dsh/phone`: parsing the contract's maps, and staying
// usable when the native side is missing or throws.

import 'dart:async';

import 'package:dsh_app/phone/phone_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final channel = PhoneChannel();

  test('status parses every field of the contract', () async {
    final native = FakePhoneNative(
      status: phoneStatus(
        a11y: true,
        notifications: false,
        mode: 'shizuku',
        backgroundReady: false,
        backgroundReason: 'Shizuku 没有在运行',
        shizukuInstalled: true,
        wirelessDebugging: null,
        paired: true,
        taskActive: true,
        taskApp: '美团',
        taskPaused: true,
      ),
    )..install();
    final s = await channel.status();
    expect(native.methods, ['status']);
    expect(s.ready, isTrue);
    expect(s.enabled, isTrue);
    expect(s.bridgeListening, isTrue);
    expect(s.a11y.ok, isTrue);
    expect(s.notifications, isFalse);
    expect(s.background.mode, PhoneBackgroundMode.shizuku);
    expect(s.background.reason, 'Shizuku 没有在运行');
    expect(s.background.androidOk, isTrue);
    expect(s.background.shizuku.installed, isTrue);
    expect(s.background.shizuku.running, isFalse);
    expect(s.background.adb.wirelessDebugging, isNull);
    expect(s.background.adb.paired, isTrue);
    expect(s.task.active, isTrue);
    expect(s.task.app, '美团');
    expect(s.task.paused, isTrue);
    expect(s.device.manufacturer, 'vivo');
    expect(s.device.sdkInt, 35);
    expect(s.device.mayNeedRestrictedSettings, isTrue);
  });

  test('a status without the optional device entry still parses', () async {
    FakePhoneNative(status: phoneStatus(device: null)).install();
    final s = await channel.status();
    expect(s.ready, isTrue);
    expect(s.device.manufacturer, isNull);
    // Unknown → the restricted-settings hint may apply.
    expect(s.device.mayNeedRestrictedSettings, isTrue);
    expect(const PhoneDevice(sdkInt: 32, sideloaded: true).mayNeedRestrictedSettings, isFalse);
    expect(const PhoneDevice(sdkInt: 34, sideloaded: false).mayNeedRestrictedSettings, isFalse);
  });

  test('a missing native side reads as 未就绪 and every call degrades', () async {
    removePhoneNative();
    final s = await channel.status();
    expect(s.ready, isFalse);
    expect(await channel.setEnabled(true), isFalse);
    expect(await channel.openAccessibilitySettings(), isFalse);
    final test = await channel.testScreen();
    expect(test.ok, isFalse);
    expect(test.reason, phoneNotReadyReason);
    final pair = await channel.adbPair('123456');
    expect(pair.ok, isFalse);
    expect(pair.reason, phoneNotReadyReason);
    expect(await channel.getPolicies(), isNull);
    expect(await channel.actionLog(), isEmpty);
  });

  test('PlatformException becomes a reason, not a crash', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(phoneMethods, (
      call,
    ) async {
      throw PlatformException(code: 'boom', message: '无障碍服务没有连接');
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        phoneMethods,
        null,
      ),
    );
    final s = await channel.status();
    expect(s.ready, isFalse);
    expect(s.error, '无障碍服务没有连接');
    final r = await channel.testScreen();
    expect(r.ok, isFalse);
    expect(r.reason, '无障碍服务没有连接');
    expect((await channel.adbConnect()).reason, '无障碍服务没有连接');
  });

  test('method arguments follow the contract', () async {
    final native = FakePhoneNative()..install();
    await channel.setEnabled(true);
    await channel.setBackgroundMode(PhoneBackgroundMode.adb);
    await channel.adbPair('482913', port: 37123);
    await channel.adbConnect(port: 45269);
    await channel.actionLog(limit: 7);
    await channel.setPolicies(
      const PhonePolicies(
        denyPackages: ['cmb.pb'],
        confirmEveryWritePackages: ['com.tencent.mm'],
        labels: {'cmb.pb': '招商银行'},
      ),
    );
    expect(native.callsOf('setEnabled').single.arguments, {'enabled': true});
    expect(native.callsOf('setBackgroundMode').single.arguments, {'mode': 'adb'});
    expect(native.callsOf('adbPair').single.arguments, {'code': '482913', 'port': 37123});
    expect(native.callsOf('adbConnect').single.arguments, {'port': 45269});
    expect(native.callsOf('actionLog').single.arguments, {'limit': 7});
    // Only the two lists and the confirm mode go over the wire.
    expect(native.callsOf('setPolicies').single.arguments, {
      'denyPackages': ['cmb.pb'],
      'confirmEveryWritePackages': ['com.tencent.mm'],
      'confirmMode': 'ask',
    });
  });

  test('policies: rules, labels, defaults and edits', () async {
    FakePhoneNative(
      policies: {
        ...defaultPolicies(),
        'labels': {'com.unionpay': '云闪付 App'},
        'defaults': {
          'denyPackages': ['com.eg.android.AlipayGphone', 'com.unionpay'],
          'confirmEveryWritePackages': ['com.tencent.mm'],
        },
      },
    ).install();
    final p = (await channel.getPolicies())!;
    expect(p.ruleFor('com.eg.android.AlipayGphone'), AppRule.deny);
    expect(p.ruleFor('com.tencent.mm'), AppRule.confirmEachStep);
    expect(p.ruleFor('com.taobao.taobao'), AppRule.normal);
    expect(p.labelFor('com.unionpay'), '云闪付 App'); // native label wins
    expect(p.labelFor('com.tencent.mm'), '微信'); // built-in fallback
    expect(p.labelFor('org.example.x'), 'org.example.x');
    expect(p.defaultRuleFor('com.tencent.mm'), AppRule.confirmEachStep);

    final edited = p.withRule('com.tencent.mm', AppRule.normal).withRule('com.taobao.taobao', AppRule.deny);
    expect(edited.confirmEveryWritePackages, isEmpty);
    expect(edited.denyPackages, contains('com.taobao.taobao'));
    expect(edited.defaultConfirm, ['com.tencent.mm']);
  });

  test('action log entries tolerate time formats and odd decisions', () async {
    FakePhoneNative(
      log: [
        {'time': 1761000000, 'tool': 'tap', 'decision': 'denied'},
        {'time': '2026-10-23T08:00:00Z', 'tool': 'type', 'decision': 'confirmed-app'},
        {'tool': 'scroll', 'decision': 'something-new'},
        {'time': 1761000000000, 'tool': 'handoff', 'decision': 'timeout'},
        {'time': 1761000000000, 'tool': 'tap', 'decision': 'allowed'},
        {'time': 1761000000000, 'tool': 'open', 'decision': 'refused:system-page'},
        {'time': 1761000000000, 'tool': 'tap', 'decision': 'paused'},
      ],
    ).install();
    final log = await channel.actionLog();
    expect(log, hasLength(7));
    expect(log[0].time, DateTime.fromMillisecondsSinceEpoch(1761000000 * 1000));
    expect(log[0].decision, PhoneDecision.denied);
    expect(log[1].time, DateTime.utc(2026, 10, 23, 8).toLocal());
    expect(log[1].decision, PhoneDecision.allowed);
    expect(log[2].time, isNull);
    expect(log[2].decision, PhoneDecision.unknown);
    expect(log[2].rawDecision, 'something-new');
    // Native `timeout` is the tool running out of time, not an unanswered question.
    expect(log[3].decision, PhoneDecision.failed);
    // Native `allowed` means no question was needed.
    expect(log[4].decision, PhoneDecision.done);
    expect(log[5].decision, PhoneDecision.blocked);
    expect(log[6].decision, PhoneDecision.stopped);
  });
  test('preview reads the existing JPEG and capture metadata with one method only', () async {
    final bytes = Uint8List.fromList([0xff, 0xd8, 7, 0xff, 0xd9]);
    final native = FakePhoneNative()
      ..preview = {'revision': 4, 'available': true, 'jpegBytes': bytes, 'taskId': 12, 'capturedAt': 1762045200123}
      ..install();
    final snapshot = await PhoneChannel().previewSnapshot();
    expect(snapshot.available, isTrue);
    expect(snapshot.revision, 4);
    expect(snapshot.jpegBytes, bytes);
    expect(snapshot.taskId, 12);
    expect(snapshot.capturedAt, 1762045200123);
    expect(snapshot.reason, isNull);
    expect(native.methods, ['previewSnapshot']);
    expect(native.calls.single.arguments, isNull);
    expect(native.listening, isFalse);
    expect(native.previewListening, isFalse);
  });

  for (final reason in ['noImage', 'inactive', 'locked', 'unavailable']) {
    test('preview $reason never exposes old image metadata', () async {
      final native = FakePhoneNative()
        ..preview = {
          'revision': 8,
          'available': false,
          'reason': reason,
          'jpegBytes': Uint8List.fromList([1]),
          'taskId': 2,
          'capturedAt': 3,
        }
        ..install();
      final snapshot = await PhoneChannel().previewSnapshot();
      expect(snapshot.available, isFalse);
      expect(snapshot.revision, 8);
      expect(snapshot.reason, reason);
      expect(snapshot.jpegBytes, isNull);
      expect(snapshot.taskId, isNull);
      expect(snapshot.capturedAt, isNull);
      expect(native.methods, ['previewSnapshot']);
    });
  }

  test('preview missing fields or unknown reason stays unavailable', () {
    for (final map in <Map<Object?, Object?>>[
      {},
      {'available': true},
      {'available': false, 'reason': 'futureReason'},
      {'revision': 1, 'available': true, 'jpegBytes': Uint8List(0), 'taskId': 1, 'capturedAt': 2},
      {
        'available': true,
        'jpegBytes': Uint8List.fromList([1]),
        'taskId': 1,
        'capturedAt': 2,
      },
      {
        'revision': 1,
        'available': true,
        'jpegBytes': Uint8List.fromList([1]),
        'capturedAt': 2,
      },
      {
        'revision': 1,
        'available': true,
        'jpegBytes': Uint8List.fromList([1]),
        'taskId': 1,
      },
    ]) {
      final snapshot = PhonePreviewSnapshot.fromMap(map);
      expect(snapshot.available, isFalse);
      expect(snapshot.reason, 'unavailable');
      expect(snapshot.jpegBytes, isNull);
    }
  });

  test('preview missing plugin, null or platform error makes no fallback call', () async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    removePhoneNative();
    expect((await PhoneChannel().previewSnapshot()).reason, 'unavailable');
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(phoneMethods, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(phoneMethods, null));
    expect((await PhoneChannel().previewSnapshot()).available, isFalse);
    messenger.setMockMethodCallHandler(phoneMethods, (call) async {
      calls.add(call);
      throw PlatformException(code: 'nativeFailed', message: 'not a preview reason');
    });
    expect((await PhoneChannel().previewSnapshot()).reason, 'unavailable');
    expect(calls.map((c) => c.method), ['previewSnapshot', 'previewSnapshot']);
  });

  test('preview events are separate and cancelling them leaves status alive', () async {
    final native = FakePhoneNative()..install();
    final channel = PhoneChannel();
    final statuses = <PhoneStatus>[];
    final revisions = <int>[];
    var statusArrived = Completer<void>();
    final previewArrived = Completer<void>();
    final statusSub = channel.statusChanges.listen((s) {
      statuses.add(s);
      statusArrived.complete();
    });
    final previewSub = channel.previewChanges.listen((r) {
      revisions.add(r);
      previewArrived.complete();
    });
    addTearDown(statusSub.cancel);
    addTearDown(previewSub.cancel);
    await Future.wait([native.statusStarted.future, native.previewStarted.future]);
    expect(native.listening, isTrue);
    expect(native.previewListening, isTrue);
    native.pushPreview(2);
    await previewArrived.future;
    expect(revisions, [2]);
    expect(statuses, isEmpty);
    expect(native.methods, isEmpty);
    native.push(phoneStatus(taskActive: true, taskApp: 'existing task'));
    await statusArrived.future;
    expect(statuses.single.task.app, 'existing task');
    expect(revisions, [2]);
    await previewSub.cancel();
    expect(native.previewListening, isFalse);
    expect(native.listening, isTrue);
    statusArrived = Completer<void>();
    native.push(phoneStatus(taskActive: false));
    await statusArrived.future;
    expect(statuses, hasLength(2));
    expect(statuses.last.task.active, isFalse);
  });

  test('preview stream shares one native listener until its last subscriber cancels', () async {
    final native = FakePhoneNative()..install();
    final channel = PhoneChannel();
    final first = <int>[];
    final second = <int>[];
    final arrivedA = Completer<void>();
    var arrivedB = Completer<void>();
    final a = channel.previewChanges.listen((r) {
      first.add(r);
      arrivedA.complete();
    });
    final b = channel.previewChanges.listen((r) {
      second.add(r);
      arrivedB.complete();
    });
    addTearDown(a.cancel);
    addTearDown(b.cancel);
    await native.previewStarted.future;
    native.pushPreview(3);
    await Future.wait([arrivedA.future, arrivedB.future]);
    expect(first, [3]);
    expect(second, [3]);
    await a.cancel();
    expect(native.previewListening, isTrue);
    arrivedB = Completer<void>();
    native.pushPreview(4);
    await arrivedB.future;
    expect(first, [3]);
    expect(second, [3, 4]);
    await b.cancel();
    expect(native.previewListening, isFalse);
  });

  test('late snapshot retains its own revision after a newer invalidation', () async {
    final native = FakePhoneNative()..install();
    final reply = Completer<Map<String, Object?>>();
    final requested = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(phoneMethods, (call) {
      requested.complete();
      return reply.future;
    });
    final channel = PhoneChannel();
    final revisions = <int>[];
    final eventArrived = Completer<void>();
    final sub = channel.previewChanges.listen((r) {
      revisions.add(r);
      eventArrived.complete();
    });
    addTearDown(sub.cancel);
    await native.previewStarted.future;
    final pending = channel.previewSnapshot();
    await requested.future;
    native.pushPreview(6);
    await eventArrived.future;
    reply.complete({'revision': 5, 'available': false, 'reason': 'noImage'});
    final snapshot = await pending;
    expect(snapshot.revision, 5);
    expect(revisions.single, greaterThan(snapshot.revision));
    expect(snapshot.available, isFalse);
  });
}
