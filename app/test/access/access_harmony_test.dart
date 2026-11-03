// The system-permission pages on HarmonyOS: notifications are asked for with
// the system's dialog, and only what works there is read or offered. Android
// beside it wherever the OS is a parameter.

import 'package:dsh_app/notify/notify_channel.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/access_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/ui/access/access_walk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support.dart';

const _primary = ValueKey('access-primary');

Future<void> _frames(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String _primaryLabel(WidgetTester tester) =>
    (tester.widget<FilledButton>(find.byKey(_primary)).child! as Text).data!;

/// The runtime's answers on HarmonyOS: no storage, and no battery exemption to ask about.
class _HarmonyBridge extends RuntimeBridge {
  @override
  Future<StorageAccess> storageStatus() async => const StorageAccess(granted: false, permission: false, legacy: false);

  @override
  Future<bool?> batteryExempt() => Future.error(PlatformException(code: 'ohos_unsupported'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const notify = MethodChannel('dsh/notify');
  const voice = MethodChannel('dsh/voice');
  final calls = <String>[];
  late Future<Object?> Function(MethodCall) answer;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    answer = (_) async => true;
    messenger.setMockMethodCallHandler(notify, (call) {
      calls.add(call.method);
      return answer(call);
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(notify, null);
    messenger.setMockMethodCallHandler(voice, null);
  });

  group('the channel\'s permission dialog', () {
    test('answers what the native side says; refused is false', () async {
      expect(await NotifyChannel().requestPermission(), isTrue);
      answer = (_) async => false;
      expect(await NotifyChannel().requestPermission(), isFalse);
      expect(calls, ['requestPermission', 'requestPermission']);
    });

    test('a failure or no native side is not a grant', () async {
      answer = (_) async => throw PlatformException(code: 'no_ability');
      expect(await NotifyChannel().requestPermission(), isFalse);
      messenger.setMockMethodCallHandler(notify, null);
      expect(await NotifyChannel().requestPermission(), isFalse);
    });
  });

  group('notifications, by OS', () {
    test('a dialog item on HarmonyOS only', () {
      expect(AccessItem.notifications.dialogOn('ohos'), isTrue);
      expect(AccessItem.notifications.dialogOn('android'), isFalse);
      for (final item in AccessItem.values.where((i) => i != AccessItem.notifications)) {
        expect(item.dialogOn('ohos'), item.dialogOn('android'), reason: item.name);
      }
    });

    AccessDriver driver(String os) {
      final container = ProviderContainer(overrides: [operatingSystemProvider.overrideWithValue(os)]);
      addTearDown(container.dispose);
      return container.read(accessDriverProvider);
    }

    test('HarmonyOS: the first try asks, again opens settings', () async {
      final phone = driver('ohos');
      expect(await phone.open(AccessItem.notifications), isTrue);
      expect(calls, ['requestPermission']);
      expect(await phone.open(AccessItem.notifications, again: true), isTrue);
      expect(calls, ['requestPermission', 'openSettings']);
    });

    test('HarmonyOS: a refusal or a failed dialog still came back, for the step to say so', () async {
      final phone = driver('ohos');
      answer = (_) async => false;
      expect(await phone.open(AccessItem.notifications), isTrue);
      answer = (_) async => throw PlatformException(code: 'no_ability');
      expect(await phone.open(AccessItem.notifications), isTrue);
    });

    test('Android: settings, first and again', () async {
      final phone = driver('android');
      expect(await phone.open(AccessItem.notifications), isTrue);
      expect(await phone.open(AccessItem.notifications, again: true), isTrue);
      expect(calls, ['openSettings', 'openSettings']);
    });
  });

  group('the step', () {
    Future<FakeAccessDriver> pump(WidgetTester tester, String os) async {
      final phone = FakeAccessDriver(readingsWith(offPhone, notifications: false));
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: AccessWalk(items: const [AccessItem.notifications], onDone: () {}),
          brightness: Brightness.light,
          overrides: [...accessOverrides(phone), operatingSystemProvider.overrideWithValue(os)],
        ),
      );
      await _frames(tester);
      return phone;
    }

    testWidgets('on HarmonyOS the dialog answers at once; 重试 goes to settings', (tester) async {
      final phone = await pump(tester, 'ohos');
      expect(_primaryLabel(tester), '去开启');
      await tester.tap(find.byKey(_primary));
      await _frames(tester);
      expect(phone.opened, ['notifications']);
      expect(find.text('还没开启'), findsOneWidget);
      expect(_primaryLabel(tester), '重试');

      await tester.tap(find.byKey(_primary));
      await _frames(tester);
      expect(phone.opened, ['notifications', 'notifications+']);
    });

    testWidgets('on HarmonyOS allowed in the dialog: its check, without leaving the app', (tester) async {
      final phone = await pump(tester, 'ohos');
      phone.answer = (_, r) => readingsWith(r, notifications: true);
      await tester.tap(find.byKey(_primary));
      await _frames(tester);
      expect(find.text('已开启'), findsOneWidget);
    });

    testWidgets('on Android a settings page: nothing to say until the person is back', (tester) async {
      final phone = await pump(tester, 'android');
      await tester.tap(find.byKey(_primary));
      await _frames(tester);
      expect(phone.opened, ['notifications']);
      expect(find.text('还没开启'), findsNothing);
      await awayAndBack(tester);
      expect(find.text('还没开启'), findsOneWidget);
    });
  });
}
