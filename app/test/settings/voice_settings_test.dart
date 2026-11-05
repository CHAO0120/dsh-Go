import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/voice_settings.dart';
import 'package:dsh_app/ui/settings/voice_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../phone/support.dart' show FixedActiveHost, FixedHosts;

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  test('saved route is ready before first use and persists across provider recreation', () async {
    SharedPreferences.setMockInitialValues({VoiceSettingsController.preferenceKey: 'engine'});
    final first = ProviderContainer();
    expect(await first.read(voiceSettingsProvider.notifier).ready(), VoiceMode.engine);
    await first.read(voiceSettingsProvider.notifier).setMode(VoiceMode.system);
    first.dispose();
    final next = ProviderContainer();
    addTearDown(next.dispose);
    expect(await next.read(voiceSettingsProvider.notifier).ready(), VoiceMode.system);
    expect((await SharedPreferences.getInstance()).getString(VoiceSettingsController.preferenceKey), 'system');
  });

  test('an unknown stored route safely resolves to automatic', () async {
    SharedPreferences.setMockInitialValues({VoiceSettingsController.preferenceKey: 'future-mode'});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(await container.read(voiceSettingsProvider.notifier).ready(), VoiceMode.auto);
  });

  group('语音模型 on HarmonyOS', () {
    final zh = lookupL10n(AppLocale.zhCN);
    Future<void> page(WidgetTester tester, String os, {HostRef host = HostRef.local}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1400);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        testApp(
          const VoiceSettingsPage(),
          overrides: [
            operatingSystemProvider.overrideWithValue(os),
            activeHostProvider.overrideWith(() => FixedActiveHost(host)),
            hostsProvider.overrideWith(FixedHosts.new),
          ],
        ),
      );
      await tester.pumpAndSettle();
    }

    const engine = ValueKey('voice-mode-engine');

    testWidgets('on its own engine: a plain line instead of a mode that can only loop', (tester) async {
      await page(tester, 'ohos');
      expect(find.byKey(engine), findsNothing);
      expect(find.byType(VoiceModelCard), findsNothing);
      expect(find.text(zh.harmonyVoiceLocalLine), findsOneWidget);
      expect(find.byKey(const ValueKey('voice-mode-system')), findsOneWidget);
    });

    testWidgets('a remote host keeps it: its recognizer is that host\'s', (tester) async {
      await page(tester, 'ohos', host: const HostRef.ssh('pc'));
      expect(find.byKey(engine), findsOneWidget);
      expect(find.text(zh.harmonyVoiceLocalLine), findsNothing);
    });

    testWidgets('on Android: as ever', (tester) async {
      await page(tester, 'android');
      expect(find.byKey(engine), findsOneWidget);
      expect(find.byType(VoiceModelCard), findsOneWidget);
      expect(find.text(zh.harmonyVoiceLocalLine), findsNothing);
    });

    test('a mode saved for a remote host is automatic on its own engine', () {
      expect(voiceModeOnHarmonyLocal(VoiceMode.engine), VoiceMode.auto);
      expect(voiceModeOnHarmonyLocal(VoiceMode.system), VoiceMode.system);
      expect(voiceModeOnHarmonyLocal(VoiceMode.auto), VoiceMode.auto);
    });
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('voice choices at 320dp, scale $scale, ${brightness.name} remain selectable', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 800);
        addTearDown(tester.view.reset);
        if (scale == 2) AppLocale.use(AppLocale.en);
        await tester.pumpWidget(
          testApp(
            Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                child: const VoiceSettingsPage(),
              ),
            ),
            brightness: brightness,
          ),
        );
        await tester.pumpAndSettle();
        final rows = [for (final mode in VoiceMode.values) find.byKey(ValueKey('voice-mode-${mode.name}'))];
        for (final row in rows) {
          await tester.ensureVisible(row);
          await tester.pumpAndSettle();
          expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
          expect(tester.getRect(row).left, greaterThanOrEqualTo(0));
          expect(tester.getRect(row).right, lessThanOrEqualTo(320));
        }
        await tester.tap(rows.last);
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(tester.element(find.byType(VoiceSettingsPage)));
        expect(container.read(voiceSettingsProvider), VoiceMode.engine);
        expect((await SharedPreferences.getInstance()).getString(VoiceSettingsController.preferenceKey), 'engine');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
