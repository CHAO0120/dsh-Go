// PhoneController: loading, events, the master switch and its engine restart,
// safe mode and remote hosts, app rules.

import 'dart:async';

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/phone_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PhoneTestRuntime runtime;

  ProviderContainer make({RuntimeStatus engine = runningRuntime, HostRef host = HostRef.local}) {
    runtime = PhoneTestRuntime(LocalRuntimeState(loaded: true, status: engine));
    final c = ProviderContainer(
      overrides: [
        localRuntimeProvider.overrideWith(() => runtime),
        activeHostProvider.overrideWith(() => FixedActiveHost(host)),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Map<String, Object?> orderedStatus(int revision, int taskId, {bool active = true}) => {
    ...phoneStatus(taskId: taskId, taskActive: active),
    'statusRevision': revision,
    'taskProtocol': 1,
    'selectedTaskId': taskId,
    'tasks': [{'id': taskId, 'active': active, 'stopped': !active}],
  };

  test('status reads and events share one revision gate before task side effects', () async {
    final old = orderedStatus(1, 71, active: false);
    final latest = orderedStatus(2, 72);
    final native = FakePhoneNative(status: old)..install();
    final c = make();
    c.read(phoneProvider);
    await settle();
    expect(c.read(phoneProvider).status.task.id, 71);
    native.status = latest;
    expect(await c.read(phoneProvider.notifier).refreshStatus(), isTrue);
    expect(c.read(phoneProvider).status.task.id, 72);
    native.calls.clear();
    native.push(old);
    await settle();
    expect(c.read(phoneProvider).status.task.id, 72);
    expect(c.read(phoneProvider).status.task.active, isTrue);
    expect(native.callsOf('actionLog'), isEmpty);
    expect(await c.read(phoneProvider.notifier).refreshStatus(), isFalse);
    expect(c.read(phoneProvider).status.task.id, 72);
    expect(native.callsOf('actionLog'), isEmpty);
    for (final revision in <Object?>[null, 0, -1, 2, 1.0, '3', true]) {
      native.push({...old, 'statusRevision': revision});
      await settle();
      expect(c.read(phoneProvider).status.task.id, 72);
    }
    native.push(phoneStatus(taskId: 71));
    await settle();
    expect(c.read(phoneProvider).status.task.id, 72);
    expect(native.callsOf('actionLog'), isEmpty);
    native.push(orderedStatus(3, 73));
    await settle();
    expect(c.read(phoneProvider).status.task.id, 73);
    expect(c.read(phoneProvider).status.statusRevision, 3);
  });

  test('transport failure preserves modern task facts and cannot erase a newer event', () async {
    final native = FakePhoneNative(status: orderedStatus(1, 71))..install();
    final c = make();
    c.read(phoneProvider);
    await settle();
    final late = Completer<Map<String, Object?>>();
    native.onStatus = () => late.future;
    final pending = c.read(phoneProvider.notifier).refreshStatus();
    await settle();
    native.push(orderedStatus(2, 72));
    await settle();
    late.completeError(PlatformException(code: 'offline', message: 'old failure'));
    expect(await pending, isFalse);
    expect(c.read(phoneProvider).status.ready, isTrue);
    expect(c.read(phoneProvider).status.task.id, 72);
    native.calls.clear();
    native.onStatus = () async => throw PlatformException(code: 'offline', message: 'current failure');
    expect(await c.read(phoneProvider.notifier).refreshStatus(), isFalse);
    expect(c.read(phoneProvider).status.ready, isFalse);
    expect(c.read(phoneProvider).status.error, 'current failure');
    expect(c.read(phoneProvider).status.task.id, 72);
    expect(c.read(phoneProvider).status.task.active, isTrue);
    expect(c.read(phoneProvider).status.statusRevision, 2);
    expect(native.callsOf('actionLog'), isEmpty);
    native.push(orderedStatus(1, 71, active: false));
    await settle();
    expect(c.read(phoneProvider).status.ready, isFalse);
    expect(c.read(phoneProvider).status.task.id, 72);
    native.push(orderedStatus(3, 73));
    await settle();
    expect(c.read(phoneProvider).status.ready, isTrue);
    expect(c.read(phoneProvider).status.error, isNull);
    expect(c.read(phoneProvider).status.task.id, 73);
  });

  test('missing revision remains compatible until the first modern snapshot', () async {
    final native = FakePhoneNative(status: phoneStatus(taskId: 71))..install();
    final c = make();
    c.read(phoneProvider);
    await settle();
    expect(c.read(phoneProvider).status.task.id, 71);
    native.push({...phoneStatus(taskId: 99), 'statusRevision': 'invalid'});
    await settle();
    expect(c.read(phoneProvider).status.task.id, 71);
    native.push(phoneStatus(taskId: 72));
    await settle();
    expect(c.read(phoneProvider).status.task.id, 72);
    native.push(orderedStatus(1, 73));
    await settle();
    native.push(phoneStatus(taskId: 74));
    await settle();
    expect(c.read(phoneProvider).status.task.id, 73);
  });

  for (final ruleFirst in [true, false]) {
    test('full policy writes preserve rule and mode with ruleFirst=$ruleFirst', () async {
      const package = 'org.example.serial';
      final native = FakePhoneNative(policies: {
        'denyPackages': <String>[],
        'confirmEveryWritePackages': <String>[],
        'confirmMode': 'ask',
      })..install();
      final c = make();
      final controller = c.read(phoneProvider.notifier);
      await controller.refreshPolicies();
      final entered = Completer<void>();
      final release = Completer<void>();
      final writes = <Map<String, Object?>>[];
      native.onSetPolicies = (args) async {
        writes.add(args);
        if (writes.length == 1) {
          entered.complete();
          await release.future;
        }
        return true;
      };
      final first = ruleFirst
          ? controller.setRule(package, AppRule.deny, expectedFrom: AppRule.normal)
          : controller.setConfirmMode(PhoneConfirmMode.task);
      Future<bool>? second;
      try {
        await entered.future;
        second = ruleFirst
            ? controller.setConfirmMode(PhoneConfirmMode.task)
            : controller.setRule(package, AppRule.deny, expectedFrom: AppRule.normal);
        release.complete();
        expect(await first, isTrue);
        expect(await second, isTrue);
        expect(writes, hasLength(2));
        expect(writes.last['denyPackages'], contains(package));
        expect(writes.last['confirmMode'], 'task');
        expect(c.read(phoneProvider).policies!.ruleFor(package), AppRule.deny);
        expect(c.read(phoneProvider).policies!.confirmMode, PhoneConfirmMode.task);
      } finally {
        if (!release.isCompleted) {
          release.complete();
        }
        await first;
        if (second != null) {
          await second;
        }
      }
    });
  }

  test('refused policy write releases the next intent without accepting its fields', () async {
    const firstPackage = 'org.example.refused';
    const secondPackage = 'org.example.accepted';
    final native = FakePhoneNative(policies: {
      'denyPackages': <String>[],
      'confirmEveryWritePackages': <String>[],
    })..install();
    final c = make();
    final controller = c.read(phoneProvider.notifier);
    await controller.refreshPolicies();
    final entered = Completer<void>();
    final release = Completer<void>();
    final writes = <Map<String, Object?>>[];
    native.onSetPolicies = (args) async {
      writes.add(args);
      if (writes.length == 1) {
        entered.complete();
        await release.future;
        return false;
      }
      return true;
    };
    final first = controller.setRule(firstPackage, AppRule.deny, expectedFrom: AppRule.normal);
    Future<bool>? second;
    try {
      await entered.future;
      second = controller.setRule(secondPackage, AppRule.confirmEachStep, expectedFrom: AppRule.normal);
      release.complete();
      expect(await first, isFalse);
      expect(await second, isTrue);
      expect(writes, hasLength(2));
      expect(writes.last['denyPackages'], isNot(contains(firstPackage)));
      expect(writes.last['confirmEveryWritePackages'], contains(secondPackage));
      expect(c.read(phoneProvider).policies!.ruleFor(firstPackage), AppRule.normal);
      expect(c.read(phoneProvider).policies!.ruleFor(secondPackage), AppRule.confirmEachStep);
    } finally {
      if (!release.isCompleted) {
        release.complete();
      }
      await first;
      if (second != null) {
        await second;
      }
    }
  });

  test('disposing the controller prevents a queued policy intent from reaching native', () async {
    final native = FakePhoneNative(policies: {
      'denyPackages': <String>[],
      'confirmEveryWritePackages': <String>[],
    })..install();
    final c = ProviderContainer(overrides: [
      localRuntimeProvider.overrideWith(
        () => PhoneTestRuntime(LocalRuntimeState(loaded: true, status: runningRuntime)),
      ),
      activeHostProvider.overrideWith(() => FixedActiveHost(HostRef.local)),
    ]);
    var disposed = false;
    final entered = Completer<void>();
    final release = Completer<void>();
    final writes = <Map<String, Object?>>[];
    Future<bool>? first;
    Future<bool>? second;
    try {
      final controller = c.read(phoneProvider.notifier);
      await controller.refreshPolicies();
      native.onSetPolicies = (args) async {
        writes.add(args);
        if (writes.length == 1) {
          entered.complete();
          await release.future;
        }
        return true;
      };
      first = controller.setRule('org.example.started', AppRule.deny, expectedFrom: AppRule.normal);
      await entered.future;
      second = controller.setRule('org.example.queued', AppRule.deny, expectedFrom: AppRule.normal);
      c.dispose();
      disposed = true;
      release.complete();
      expect(await first, isFalse);
      expect(await second, isFalse);
      expect(writes, hasLength(1));
      expect(writes.single['denyPackages'], contains('org.example.started'));
    } finally {
      if (!release.isCompleted) {
        release.complete();
      }
      if (first != null) {
        await first;
      }
      if (second != null) {
        await second;
      }
      if (!disposed) {
        c.dispose();
      }
    }
  });

  for (final (expected, actual, target, accepted) in [
    (AppRule.confirmEachStep, AppRule.deny, AppRule.confirmEachStep, false),
    (AppRule.normal, AppRule.confirmEachStep, AppRule.normal, false),
    (AppRule.deny, AppRule.confirmEachStep, AppRule.normal, false),
    (AppRule.normal, AppRule.confirmEachStep, AppRule.deny, true),
    (AppRule.deny, AppRule.normal, AppRule.confirmEachStep, true),
    (AppRule.confirmEachStep, AppRule.deny, AppRule.deny, true),
    (AppRule.deny, AppRule.deny, AppRule.confirmEachStep, true),
    (AppRule.confirmEachStep, AppRule.confirmEachStep, AppRule.normal, true),
  ]) {
    test('queued rule checks its original basis: $expected / $actual / $target', () async {
      const package = 'org.example.basis';
      final native = FakePhoneNative(policies: {
        'denyPackages': [if (expected == AppRule.deny) package],
        'confirmEveryWritePackages': [if (expected == AppRule.confirmEachStep) package],
      })..install();
      final c = make();
      final controller = c.read(phoneProvider.notifier);
      await controller.refreshPolicies();
      final entered = Completer<void>();
      final release = Completer<void>();
      final writes = <Map<String, Object?>>[];
      native.onSetPolicies = (args) async {
        writes.add(args);
        if (writes.length == 1) {
          entered.complete();
          await release.future;
        }
        return true;
      };
      final first = controller.setRule(package, actual, expectedFrom: expected);
      Future<bool>? second;
      try {
        await entered.future;
        second = controller.setRule(package, target, expectedFrom: expected);
        release.complete();
        expect(await first, isTrue);
        expect(await second, accepted);
        expect(writes, hasLength(accepted ? 2 : 1));
        expect(c.read(phoneProvider).policies!.ruleFor(package), accepted ? target : actual);
        // A local refusal must release the same tail for the next legal intent.
        expect(
          await controller.setRule(package, AppRule.deny, expectedFrom: accepted ? target : actual),
          isTrue,
        );
        expect(writes, hasLength(accepted ? 3 : 2));
        expect(writes.last['denyPackages'], contains(package));
      } finally {
        if (!release.isCompleted) {
          release.complete();
        }
        await first;
        if (second != null) {
          await second;
        }
      }
    });
  }

  test('different app rule writes preserve both native lists while the first reply is pending', () async {
    const firstPackage = 'org.example.first';
    const secondPackage = 'org.example.second';
    final native = FakePhoneNative(policies: {
      'denyPackages': <String>[], 'confirmEveryWritePackages': <String>[],
    })..install();
    final c = make();
    final controller = c.read(phoneProvider.notifier);
    await controller.refreshPolicies();
    final entered = Completer<void>();
    final release = Completer<void>();
    final firstPersisted = Completer<void>();
    final writes = <Map<String, Object?>>[];
    native.onSetPolicies = (args) async {
      writes.add(args);
      if (writes.length == 1) {
        entered.complete();
        await release.future;
        native.policies = {...native.policies, ...args};
        firstPersisted.complete();
      } else {
        // The production plugin also executes policy writes serially.
        await firstPersisted.future;
        native.policies = {...native.policies, ...args};
      }
      return true;
    };
    final first = controller.setRule(firstPackage, AppRule.deny, expectedFrom: AppRule.normal);
    Future<bool>? second;
    try {
      await entered.future;
      second = controller.setRule(secondPackage, AppRule.confirmEachStep, expectedFrom: AppRule.normal);
      release.complete();
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(writes, hasLength(2));
      expect(writes.first['denyPackages'], contains(firstPackage));
      // The second actual wire map must preserve the first accepted change.
      expect(writes.last['denyPackages'], contains(firstPackage));
      expect(native.policies['denyPackages'], contains(firstPackage));
      expect(native.policies['confirmEveryWritePackages'], contains(secondPackage));
      await controller.refreshPolicies();
      expect(c.read(phoneProvider).policies!.ruleFor(firstPackage), AppRule.deny);
      expect(c.read(phoneProvider).policies!.ruleFor(secondPackage), AppRule.confirmEachStep);
    } finally {
      if (!release.isCompleted) {
        release.complete();
      }
      await first;
      if (second != null) {
        await second;
      }
    }
  });

  for (final scenario in ['different', 'same', 'refused']) {
    test('automatic pending consumption preserves a later choice: $scenario', () async {
      final native = FakePhoneNative()..install();
      final c = make();
      final controller = c.read(phoneProvider.notifier);
      await controller.refresh();
      final prefs = await SharedPreferences.getInstance();
      const firstMode = PhoneConfirmMode.task;
      final laterMode = scenario == 'same' ? firstMode : PhoneConfirmMode.ask;
      await prefs.setString(PhoneController.confirmPendingKey, firstMode.name);
      final entered = Completer<void>();
      final release = Completer<void>();
      final writes = <Map<String, Object?>>[];
      native.onSetPolicies = (args) async {
        writes.add(args);
        if (writes.length == 1) {
          entered.complete();
          await release.future;
          if (scenario == 'refused') return false;
        }
        native.policies = {...native.policies, ...args};
        return true;
      };
      // Exercise automatic replay, not two arbitrary public setter calls.
      final automatic = controller.applyPendingConfirmMode();
      Future<bool>? later;
      try {
        await entered.future;
        expect(writes.single['confirmMode'], firstMode.name);
        later = controller.chooseConfirmMode(laterMode);
        // Both calls await the existing singleton; choose's earlier continuation
        // updates its cache before yielding for the platform setString result.
        final stored = await SharedPreferences.getInstance();
        expect(stored.getString(PhoneController.confirmPendingKey), laterMode.name);
        release.complete();
        expect(await automatic, scenario != 'refused');
        expect(await later, isTrue);
        expect(writes.map((write) => write['confirmMode']).toList(),
            scenario == 'same' ? [firstMode.name] : [firstMode.name, laterMode.name]);
        expect(native.policies['confirmMode'], laterMode.name);
        expect(prefs.containsKey(PhoneController.confirmPendingKey), isFalse);
        await controller.refreshPolicies();
        expect(c.read(phoneProvider).policies!.confirmMode, laterMode);
      } finally {
        if (!release.isCompleted) release.complete();
        await automatic;
        if (later != null) await later;
      }
    });
  }

  test('direct confirm mode setting still supersedes a different pending choice', () async {
    final native = FakePhoneNative()..install();
    final c = make();
    final controller = c.read(phoneProvider.notifier);
    await controller.refresh();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(PhoneController.confirmPendingKey, PhoneConfirmMode.always.name);
    expect(await controller.setConfirmMode(PhoneConfirmMode.ask), isTrue);
    expect(native.policies['confirmMode'], PhoneConfirmMode.ask.name);
    expect(prefs.containsKey(PhoneController.confirmPendingKey), isFalse);
  });

  test('loads status, policies and the log; then follows events', () async {
    final native = FakePhoneNative()..install();
    final c = make();
    c.read(phoneProvider);
    await settle();
    final s = c.read(phoneProvider);
    expect(s.loaded, isTrue);
    expect(s.status.ready, isTrue);
    expect(s.policies!.denyPackages, contains('com.eg.android.AlipayGphone'));
    expect(s.log, hasLength(4));
    // Newest first.
    expect(s.log.first.summary, '点「路线」');
    expect(native.listening, isTrue);

    native.push(phoneStatus(a11y: true));
    await settle();
    expect(c.read(phoneProvider).status.a11y.ok, isTrue);
  });

  test('a finished task refreshes the log', () async {
    final native = FakePhoneNative(status: phoneStatus(taskActive: true, taskApp: '美团'))..install();
    final c = make();
    c.read(phoneProvider);
    await settle();
    final before = native.callsOf('actionLog').length;
    native.push(phoneStatus());
    await settle();
    expect(native.callsOf('actionLog').length, before + 1);
  });

  test('no native side: 未就绪, no event subscription, blocker notReady', () async {
    removePhoneNative();
    final c = make();
    c.read(phoneProvider);
    await settle();
    expect(c.read(phoneProvider).loaded, isTrue);
    expect(c.read(phoneProvider).status.ready, isFalse);
    expect(c.read(phoneBlockerProvider), PhoneBlocker.notReady);
  });

  test('turning on restarts a running engine', () async {
    final native = FakePhoneNative(status: phoneStatus(enabled: false))..install();
    final c = make();
    c.read(phoneProvider);
    await settle();
    final r = await c.read(phoneProvider.notifier).setEnabled(true);
    await settle();
    expect(r.ok, isTrue);
    expect(r.restarting, isTrue);
    expect(native.callsOf('setEnabled').single.arguments, {'enabled': true});
    expect(c.read(phoneProvider).status.enabled, isTrue);
    expect(runtime.stops, 1);
    expect(runtime.starts, ['start']);
  });

  test('turning on with the engine stopped does not start it', () async {
    FakePhoneNative(status: phoneStatus(enabled: false)).install();
    final c = make(engine: const RuntimeStatus(phase: RuntimePhase.installed));
    c.read(phoneProvider);
    await settle();
    final r = await c.read(phoneProvider.notifier).setEnabled(true);
    await settle();
    expect(r.ok, isTrue);
    expect(r.restarting, isFalse);
    expect(runtime.starts, isEmpty);
  });

  test('a refused setEnabled changes nothing', () async {
    final native = FakePhoneNative(status: phoneStatus(enabled: false))
      ..accept = false
      ..install();
    final c = make();
    c.read(phoneProvider);
    await settle();
    final r = await c.read(phoneProvider.notifier).setEnabled(true);
    await settle();
    expect(r.ok, isFalse);
    expect(native.callsOf('setEnabled'), hasLength(1));
    expect(c.read(phoneProvider).status.enabled, isFalse);
    expect(c.read(phoneProvider).toggling, isFalse);
    expect(runtime.stops, 0);
  });

  test('safe mode: blocks turning on, turns off without a restart', () async {
    final native = FakePhoneNative(status: phoneStatus(enabled: false))..install();
    final c = make(engine: safeRuntime);
    c.read(phoneProvider);
    await settle();
    expect(c.read(phoneBlockerProvider), PhoneBlocker.safeMode);
    final on = await c.read(phoneProvider.notifier).setEnabled(true);
    expect(on.ok, isFalse);
    expect(native.callsOf('setEnabled'), isEmpty);

    native.push(phoneStatus(enabled: true));
    await settle();
    final off = await c.read(phoneProvider.notifier).setEnabled(false);
    await settle();
    expect(off.ok, isTrue);
    expect(off.restarting, isFalse);
    expect(runtime.stops, 0);
    expect(runtime.starts, isEmpty);
  });

  test('a remote host is a blocker; the local one is not', () async {
    FakePhoneNative().install();
    final remote = make(host: const HostRef.ssh('lab'));
    remote.read(phoneProvider);
    await settle();
    expect(remote.read(phoneBlockerProvider), PhoneBlocker.remoteHost);

    final local = make();
    local.read(phoneProvider);
    await settle();
    expect(local.read(phoneBlockerProvider), isNull);
  });

  test('the disclosure is remembered', () async {
    FakePhoneNative().install();
    final c = make();
    c.read(phoneProvider);
    await settle();
    expect(c.read(phoneProvider).disclosureAccepted, isFalse);
    await c.read(phoneProvider.notifier).acceptDisclosure();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PhoneController.disclosureKey), isTrue);

    final again = make();
    again.read(phoneProvider);
    await settle();
    expect(again.read(phoneProvider).disclosureAccepted, isTrue);
  });

  test('setRule saves both lists and keeps the app listed', () async {
    final native = FakePhoneNative()..install();
    final c = make();
    c.read(phoneProvider);
    await settle();
    final ok = await c.read(phoneProvider.notifier).setRule('com.tencent.mm', AppRule.normal, expectedFrom: AppRule.confirmEachStep);
    expect(ok, isTrue);
    expect(native.callsOf('setPolicies').single.arguments, {
      'denyPackages': ['com.eg.android.AlipayGphone', 'com.unionpay', 'cmb.pb', 'com.icbc'],
      'confirmEveryWritePackages': <String>[],
      'confirmMode': 'ask',
    });
    final s = c.read(phoneProvider);
    expect(s.policies!.ruleFor('com.tencent.mm'), AppRule.normal);
    expect(s.retained, ['com.tencent.mm']);

    native.accept = false;
    final refused = await c.read(phoneProvider.notifier).setRule('cmb.pb', AppRule.normal, expectedFrom: AppRule.deny);
    expect(refused, isFalse);
    expect(c.read(phoneProvider).policies!.ruleFor('cmb.pb'), AppRule.deny);
  });

  test('background calls refresh the status afterwards', () async {
    final native = FakePhoneNative()..install();
    final c = make();
    c.read(phoneProvider);
    await settle();
    final before = native.callsOf('status').length;
    final r = await c.read(phoneProvider.notifier).setBackgroundMode(PhoneBackgroundMode.shizuku);
    await settle();
    expect(r.ok, isTrue);
    expect(native.callsOf('status').length, before + 1);
    expect(c.read(phoneProvider).status.background.mode, PhoneBackgroundMode.shizuku);
  });
}
