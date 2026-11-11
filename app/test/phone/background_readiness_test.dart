import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/phone_state.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/phone/dnd_mode_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';
import 'support.dart';

Map<String, Object?> channelStatus(String mode, {int effective = 0, String? reason = 'peerUnsupported'}) {
  final status = privilegedStatus(
    mode: mode,
    ready: true,
    provider: mode == 'sui' ? 'sui' : 'shizuku',
    running: true,
    granted: true,
    root: {'checked': true, 'connected': true},
    adbConnected: true,
  );
  (status['background'] as Map)['parallelism'] = {
    'v': 1,
    'configuredLimit': 3,
    'effectiveLimit': effective,
    'heldSlots': 0,
    'reason': reason,
  };
  return status;
}

void main() {
  for (final mode in ['shizuku', 'sui', 'root', 'adb']) {
    test('$mode does not advertise ready after the privileged peer refuses background capability', () {
      final background = PhoneStatus.fromMap(channelStatus(mode)).background;
      expect(background.privileged!.ready, isTrue, reason: 'Keep the original native fact available.');
      expect(background.parallelism!.effectiveLimit, 0);
      expect(background.parallelism!.reason, 'peerUnsupported');
      expect(background.effectiveReady, isFalse);
      expect(dndSummary(background), isNot(contains(appL10n.phoneReady)));
    });
  }

  test('busy and serial capacity do not become a claim that the peer is unsupported', () {
    final busy = PhoneStatus.fromMap(channelStatus('root', reason: 'busy')).background;
    expect(busy.parallelism!.effectiveLimit, 0);
    expect(busy.effectiveReady, isTrue);
    final serial = PhoneStatus.fromMap(channelStatus('root', effective: 1, reason: 'transportSerial')).background;
    expect(serial.effectiveReady, isTrue);
  });

  test('missing or unknown capacity keeps the existing native readiness contract', () {
    final old = PhoneBackgroundStatus.fromMap({'mode': 'adb', 'ready': true, 'androidOk': true});
    expect(old.parallelism, isNull);
    expect(old.effectiveReady, isTrue);
    final unknown = channelStatus('root');
    ((unknown['background'] as Map)['parallelism'] as Map)['v'] = 2;
    final background = PhoneStatus.fromMap(unknown).background;
    expect(background.parallelism, isNull);
    expect(background.effectiveReady, isTrue);
  });

  test('an existing native failure reason remains available unchanged', () {
    final status = channelStatus('root');
    final privileged = (status['background'] as Map)['privileged'] as Map;
    privileged['ready'] = false;
    privileged['reason'] = 'The original channel needs explicit rechecking.';
    final background = PhoneStatus.fromMap(status).background;
    expect(background.effectiveReady, isFalse);
    expect(background.effectiveReason, privileged['reason']);
  });

  testWidgets('a connected unsupported root peer stays not ready and exposes explicit retest', (tester) async {
    final native = FakePhoneNative(status: channelStatus('root'));
    await pumpPhone(tester, const PhoneDndPage(), native: native);
    final heading = find.widgetWithText(ListPageRow, appL10n.phoneDndUsing(appL10n.phonePrivilegedRoot));
    expect(tester.widget<ListPageRow>(heading).subtitle, isNull);
    expect(find.text(appL10n.phoneDndStateInUse), findsNothing);
    expect(find.text(appL10n.phoneDndStateNotReady), findsOneWidget);
    expect(find.text(appL10n.phoneBackgroundParallelPeer), findsOneWidget);
    final retest = find.widgetWithText(FilledButton, appL10n.phoneGateRetest);
    expect(retest, findsOneWidget);
    expect(tester.widget<FilledButton>(retest).onPressed, isNotNull);
    expect(native.methods, [
      'status',
      'getPolicies',
      'actionLog',
    ], reason: 'Showing the failure must not connect, probe, or request root.');

    native.push(channelStatus('root', effective: 3, reason: null));
    await settlePhone(tester);
    expect(tester.widget<ListPageRow>(heading).subtitle, appL10n.phoneReady);
    expect(find.text(appL10n.phoneDndStateInUse), findsOneWidget);
    expect(find.text(appL10n.phoneDndStateNotReady), findsNothing);
    expect(retest, findsNothing);
    expect(native.methods, ['status', 'getPolicies', 'actionLog']);
  });
}
