import 'package:dsh_app/state/phone_state.dart';
import 'package:dsh_app/ui/phone/phone_control_screen.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness.dart';
import 'support.dart';

const waitingHint = '等待你处理，请在原提示中继续或停止。';

Map<String, Object?> task(int id, {Object? waiting = true}) => {
  'id': id, 'sessionId': 'session-$id', 'generation': 1,
  'active': true, 'app': 'App$id', 'handoffWaiting': waiting,
};

Map<String, Object?> status(int revision, {int selected = 7, Map<String, Object?>? original}) => {
  ...phoneStatus(a11y: true),
  'statusRevision': revision, 'taskProtocol': 1, 'selectedTaskId': selected,
  'task': task(99),
  'tasks': [original ?? task(7), task(8, waiting: false)],
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('handoff requires exact bool through the real status channel', (tester) async {
    final native = FakePhoneNative(status: status(1));
    await pumpPhone(tester, const PhoneControlScreen(), native: native);
    expect(phoneOf(tester).status.task.handoffWaiting, isTrue);
    expect(find.text(waitingHint), findsOneWidget);
    var revision = 1;
    for (final value in <Object?>[null, false, 1, 'true', <String, Object?>{}]) {
      native.status = status(++revision, original: task(7, waiting: value));
      expect(await containerOf(tester).read(phoneProvider.notifier).refreshStatus(), isTrue);
      await tester.pump();
      expect(phoneOf(tester).status.task.handoffWaiting, isFalse, reason: '$value');
      expect(find.text(waitingHint), findsNothing);
    }
    final missing = task(7)..remove('handoffWaiting');
    native.status = status(++revision, original: missing);
    expect(await containerOf(tester).read(phoneProvider.notifier).refreshStatus(), isTrue);
    await tester.pump();
    expect(phoneOf(tester).status.task.handoffWaiting, isFalse);
    expect(find.text(waitingHint), findsNothing);
  });

  testWidgets('selected modern task never borrows another task or legacy waiting', (tester) async {
    final native = FakePhoneNative(status: status(1, selected: 8));
    await pumpPhone(tester, const PhoneControlScreen(), native: native);
    expect(phoneOf(tester).status.tasks.first.handoffWaiting, isTrue);
    expect(phoneOf(tester).status.task.id, 8);
    expect(find.text(waitingHint), findsNothing);
    native.status = status(2);
    expect(await containerOf(tester).read(phoneProvider.notifier).refreshStatus(), isTrue);
    await tester.pump();
    expect(phoneOf(tester).status.task.id, 7);
    expect(find.text(waitingHint), findsOneWidget);
    native.status = {...phoneStatus(a11y: true), 'statusRevision': 3, 'task': task(99)};
    expect(await containerOf(tester).read(phoneProvider.notifier).refreshStatus(), isTrue);
    await tester.pump();
    expect(phoneOf(tester).status.task.id, 99);
    expect(find.text(waitingHint), findsOneWidget);
  });

  testWidgets('older status cannot revive a completed handoff', (tester) async {
    final native = FakePhoneNative(status: status(2, original: task(7, waiting: false)));
    await pumpPhone(tester, const PhoneControlScreen(), native: native);
    native.status = status(1);
    expect(await containerOf(tester).read(phoneProvider.notifier).refreshStatus(), isFalse);
    await tester.pump();
    expect(phoneOf(tester).status.task.handoffWaiting, isFalse);
    expect(find.text(waitingHint), findsNothing);
    native.status = status(3);
    expect(await containerOf(tester).read(phoneProvider.notifier).refreshStatus(), isTrue);
    await tester.pump();
    expect(find.text(waitingHint), findsOneWidget);
  });

  testWidgets('unavailable status retains waiting fact without displaying it as current', (tester) async {
    final native = FakePhoneNative(status: status(1));
    await pumpPhone(tester, const PhoneControlScreen(), native: native);
    expect(find.text(waitingHint), findsOneWidget);
    native.onStatus = () async => throw PlatformException(code: 'offline');
    expect(await containerOf(tester).read(phoneProvider.notifier).refreshStatus(), isFalse);
    await tester.pump();
    expect(phoneOf(tester).status.ready, isFalse);
    expect(phoneOf(tester).status.task.id, 7);
    expect(phoneOf(tester).status.task.handoffWaiting, isTrue);
    expect(find.text(waitingHint), findsNothing);
    native.onStatus = null;
    native.status = status(2);
    expect(await containerOf(tester).read(phoneProvider.notifier).refreshStatus(), isTrue);
    await tester.pump();
    expect(find.text(waitingHint), findsOneWidget);
  });

  testWidgets('pause stop retirement and cleanup facts take precedence over waiting', (tester) async {
    final native = FakePhoneNative(status: status(1));
    await pumpPhone(tester, const PhoneControlScreen(), native: native);
    var revision = 1;
    for (final field in ['paused', 'stopped', 'retiring', 'finishing', 'draining', 'settling', 'cleanupFailed']) {
      native.status = status(++revision, original: {...task(7), field: true});
      expect(await containerOf(tester).read(phoneProvider.notifier).refreshStatus(), isTrue);
      await tester.pump();
      expect(phoneOf(tester).status.task.handoffWaiting, isTrue);
      expect(find.text(waitingHint), findsNothing, reason: field);
      if (field == 'paused') {
        expect(find.text('已暂停'), findsWidgets);
      }
    }
    expect(native.callsOf('resumeTask'), isEmpty);
    expect(native.callsOf('stopTask'), isEmpty);
    expect(native.callsOf('retryTaskCleanup'), isEmpty);
  });
}
