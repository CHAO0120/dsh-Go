import 'dart:io' show Platform;

import 'package:dsh_app/performance/performance_state.dart';
import 'package:dsh_app/performance/refresh_rate.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RefreshRateService.instance.resetForTest();
    RefreshRateService.operatingSystem = Platform.operatingSystem;
  });

  tearDown(() {
    RefreshRateService.instance.resetForTest();
    RefreshRateService.operatingSystem = Platform.operatingSystem;
  });

  Future<void> waitLoaded(ProviderContainer container) async {
    final notifier = container.read(performancePrefsProvider.notifier);
    await notifier.ready;
    for (var i = 0; i < 40; i++) {
      if (container.read(performancePrefsProvider).loaded) return;
      await Future<void>.delayed(Duration.zero);
    }
    fail('preferences did not finish loading');
  }

  test('the stored choice loads and saves', () async {
    SharedPreferences.setMockInitialValues({'performance.refresh_rate': 'system'});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await waitLoaded(container);
    expect(container.read(performancePrefsProvider).refreshRate, RefreshRateMode.system);
    await container.read(performancePrefsProvider.notifier).setRefreshRate(RefreshRateMode.max);
    expect(container.read(performancePrefsProvider).refreshRate, RefreshRateMode.max);
    expect((await SharedPreferences.getInstance()).getString('performance.refresh_rate'), 'max');
  });

  test('the default is auto, and old installs read as auto', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await waitLoaded(container);
    expect(container.read(performancePrefsProvider).refreshRate, RefreshRateMode.auto);
  });

  test('mode changes reach the platform once', () async {
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(RefreshRateService.channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(RefreshRateService.channel, null));

    final service = RefreshRateService.instance;
    service.start();
    await service.setMode(RefreshRateMode.max);
    await service.setMode(RefreshRateMode.max); // same value: no second call
    await Future<void>.delayed(Duration.zero);

    final modes = calls
        .where((call) => call.method == 'setRefreshRateMode')
        .map((call) => (call.arguments as Map<Object?, Object?>)['mode'])
        .toList();
    expect(modes, ['auto', 'max']);
  });

  /// Every call on the channel, as `method` then its only argument.
  List<String> record() {
    final calls = <String>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(RefreshRateService.channel, (call) async {
      calls.add('${call.method} ${(call.arguments as Map<Object?, Object?>).values.single}');
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(RefreshRateService.channel, null));
    return calls;
  }

  /// [count] frames [gap] apart, starting [gap] after [from]. Returns the last frame's time.
  Duration frames(int count, Duration gap, {Duration from = Duration.zero}) {
    var at = from;
    for (var i = 0; i < count; i++) {
      at += gap;
      RefreshRateService.instance.frameForTest(at);
    }
    return at;
  }

  const cadence = Duration(milliseconds: 8);
  const blink = Duration(milliseconds: 500);

  group('on Android', () {
    setUp(() => RefreshRateService.operatingSystem = 'android');

    testWidgets('any frame is activity, and its traffic is one edge each way', (tester) async {
      final calls = record();
      final service = RefreshRateService.instance;
      service.start();
      frames(1, blink);
      await tester.pump();
      expect(calls, ['setRefreshRateMode auto', 'setFrameActive true']);
      await tester.pump(RefreshRateService.idleAfter);
      expect(calls, ['setRefreshRateMode auto', 'setFrameActive true', 'setFrameActive false']);
    });

    testWidgets('a blinking cursor still holds it up, as it always did', (tester) async {
      final calls = record();
      RefreshRateService.instance.start();
      var at = Duration.zero;
      for (var i = 0; i < 10; i++) {
        at = frames(1, blink, from: at);
        await tester.pump(blink);
      }
      expect(calls, ['setRefreshRateMode auto', 'setFrameActive true']);
      await tester.pump(RefreshRateService.idleAfter);
      expect(calls.last, 'setFrameActive false');
    });

    testWidgets('long motion says active once, with no renewals', (tester) async {
      final calls = record();
      RefreshRateService.instance.start();
      frames(1000, cadence);
      await tester.pump();
      expect(calls, ['setRefreshRateMode auto', 'setFrameActive true']);
      await tester.pump(RefreshRateService.idleAfter);
    });

    testWidgets('modes pass through and frames do nothing outside auto', (tester) async {
      final calls = record();
      final service = RefreshRateService.instance;
      service.start();
      await service.setMode(RefreshRateMode.max);
      frames(10, cadence);
      await service.setMode(RefreshRateMode.system);
      await tester.pump();
      expect(calls, ['setRefreshRateMode auto', 'setRefreshRateMode max', 'setRefreshRateMode system']);
    });
  });

  group('on HarmonyOS', () {
    setUp(() => RefreshRateService.operatingSystem = 'ohos');

    testWidgets('the mode reaches the platform: it is a real choice here', (tester) async {
      final calls = record();
      final service = RefreshRateService.instance;
      service.start();
      await service.setMode(RefreshRateMode.max);
      await service.setMode(RefreshRateMode.system);
      await tester.pump();
      expect(calls, ['setRefreshRateMode auto', 'setRefreshRateMode max', 'setRefreshRateMode system']);
    });

    testWidgets('a blinking cursor never starts it', (tester) async {
      final calls = record();
      RefreshRateService.instance.start();
      var at = Duration.zero;
      for (var i = 0; i < 20; i++) {
        at = frames(1, blink, from: at);
        await tester.pump(blink);
      }
      expect(calls, ['setRefreshRateMode auto']);
    });

    testWidgets('a keystroke\'s couple of frames never start it', (tester) async {
      final calls = record();
      RefreshRateService.instance.start();
      var at = Duration.zero;
      for (var i = 0; i < 20; i++) {
        at = frames(1, const Duration(milliseconds: 200), from: at);
        at = frames(RefreshRateService.motionFrames - 1, cadence, from: at);
      }
      await tester.pump();
      expect(calls, ['setRefreshRateMode auto']);
    });

    testWidgets('frames at animation cadence start it within a few frames', (tester) async {
      final calls = record();
      RefreshRateService.instance.start();
      var at = frames(1, blink);
      at = frames(RefreshRateService.motionFrames - 1, cadence, from: at);
      await tester.pump();
      expect(calls, ['setRefreshRateMode auto']);
      frames(1, cadence, from: at);
      await tester.pump();
      expect(calls, ['setRefreshRateMode auto', 'setFrameActive true']);
      await tester.pump(RefreshRateService.idleAfter);
    });

    testWidgets('a 30 Hz panel still counts as motion', (tester) async {
      final calls = record();
      RefreshRateService.instance.start();
      frames(RefreshRateService.motionFrames + 1, const Duration(milliseconds: 34), from: blink);
      await tester.pump();
      expect(calls.last, 'setFrameActive true');
      await tester.pump(RefreshRateService.idleAfter);
    });

    testWidgets('it ends after the motion even with a cursor still blinking', (tester) async {
      final calls = record();
      RefreshRateService.instance.start();
      var at = frames(10, cadence, from: blink);
      await tester.pump(blink);
      at = frames(1, blink, from: at);
      await tester.pump(const Duration(milliseconds: 199));
      expect(calls, ['setRefreshRateMode auto', 'setFrameActive true']);
      await tester.pump(const Duration(milliseconds: 1));
      expect(calls, ['setRefreshRateMode auto', 'setFrameActive true', 'setFrameActive false']);
      frames(1, blink, from: at);
      await tester.pump(RefreshRateService.idleAfter);
      expect(calls.length, 3);
    });

    testWidgets('one slow frame in a long motion doesn\'t release it', (tester) async {
      final calls = record();
      RefreshRateService.instance.start();
      var at = frames(10, cadence, from: blink);
      await tester.pump(const Duration(milliseconds: 80));
      at = frames(1, const Duration(milliseconds: 80), from: at);
      frames(10, cadence, from: at);
      await tester.pump();
      expect(calls, ['setRefreshRateMode auto', 'setFrameActive true']);
      await tester.pump(RefreshRateService.idleAfter);
    });

    testWidgets('motion renews about once a second, so the native side can stop without it', (tester) async {
      final calls = record();
      RefreshRateService.instance.start();
      // 2.5 s of frames from the first active: renewed at 1 s and at 2 s.
      final at = frames(RefreshRateService.motionFrames, cadence, from: blink);
      frames(2500 ~/ cadence.inMilliseconds, cadence, from: at);
      await tester.pump();
      expect(calls, ['setRefreshRateMode auto', 'setFrameActive true', 'setFrameActive true', 'setFrameActive true']);
      await tester.pump(RefreshRateService.idleAfter);
      expect(calls.last, 'setFrameActive false');
    });

    testWidgets('frames do nothing outside auto', (tester) async {
      final calls = record();
      final service = RefreshRateService.instance;
      service.start();
      await service.setMode(RefreshRateMode.max);
      frames(10, cadence, from: blink);
      await tester.pump();
      expect(calls, ['setRefreshRateMode auto', 'setRefreshRateMode max']);
    });

    testWidgets('leaving max for auto starts inactive, as the native side does', (tester) async {
      final calls = record();
      final service = RefreshRateService.instance;
      service.start();
      frames(10, cadence, from: blink);
      await service.setMode(RefreshRateMode.max);
      await service.setMode(RefreshRateMode.auto);
      await tester.pump();
      expect(calls, [
        'setRefreshRateMode auto',
        'setFrameActive true',
        'setRefreshRateMode max',
        'setRefreshRateMode auto',
      ]);
      await tester.pump(RefreshRateService.idleAfter);
      expect(calls.length, 4);
    });
  });
}
