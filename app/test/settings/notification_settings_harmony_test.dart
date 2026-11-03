// 通知 on HarmonyOS: what the page says must be true there. Live activities
// aren't available in this version, and an alert needs the app running.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/notify/notify_channel.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/notify_state.dart' show notifyChannelProvider;
import 'package:dsh_app/ui/settings/notification_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notify/support.dart' show FakeNotifyChannel;
import '../shell/golden_harness.dart';

class _Unsupported extends FakeNotifyChannel {
  @override
  Future<LiveSystemStatus> liveStatus() async => const LiveSystemStatus();
}

void main() {
  final zh = lookupL10n(AppLocale.zhCN);
  final en = lookupL10n(AppLocale.en);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pump(WidgetTester tester, String os) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(390 * 2, 2400 * 2);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      goldenApp(
        home: const NotificationSettingsPage(),
        brightness: Brightness.light,
        overrides: [
          operatingSystemProvider.overrideWithValue(os),
          notifyChannelProvider.overrideWithValue(_Unsupported()),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('on HarmonyOS: not available in this version, with no Android to talk about', (tester) async {
    await pump(tester, 'ohos');
    expect(find.text(zh.harmonyLiveUnavailable), findsOneWidget);
    expect(find.text(zh.liveUnsupported), findsNothing);
    expect(find.text(zh.liveSettingsFooter), findsNothing);
    expect(find.text(zh.liveSettingsSubtitle), findsNothing);
  });

  testWidgets('on HarmonyOS: alerts need the app running, wherever the reply runs', (tester) async {
    await pump(tester, 'ohos');
    expect(find.text(zh.harmonyAlertsRequirement), findsOneWidget);
    expect(find.text(zh.pluginsRemoteAlertsRequirement), findsNothing);
  });

  testWidgets('on Android: its own words', (tester) async {
    await pump(tester, 'android');
    expect(find.text(zh.liveUnsupported), findsOneWidget);
    expect(find.text(zh.liveSettingsFooter), findsOneWidget);
    expect(find.text(zh.pluginsRemoteAlertsRequirement), findsOneWidget);
    expect(find.text(zh.harmonyLiveUnavailable), findsNothing);
    expect(find.text(zh.harmonyAlertsRequirement), findsNothing);
  });

  test('none of it names Android or a maker', () {
    for (final l in [zh, en]) {
      for (final text in [l.harmonyLiveUnavailable, l.harmonyAlertsRequirement]) {
        for (final word in ['Android', 'Xiaomi', 'OPPO', '小米']) {
          expect(text, isNot(contains(word)), reason: text);
        }
      }
    }
  });
}
