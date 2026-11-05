// On iOS nothing before the first frame can keep the app from starting.

import 'dart:async';

import 'package:dsh_app/launch/startup_trace.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> said;

  setUp(() {
    said = [];
    StartupTrace.limit = const Duration(milliseconds: 20);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dsh/startup'),
      (call) async {
        said.add('${call.method}:${call.arguments}');
        return null;
      },
    );
  });

  testWidgets('a step that hangs is noted and the app goes on', (tester) async {
    await tester.runAsync(() => StartupTrace.step('launch', () => Completer<void>().future));
    expect(said, ['mark:launch…', 'mark:launch timed out']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a step that throws is noted and the app goes on', (tester) async {
    await tester.runAsync(() => StartupTrace.step('paths', () async => throw StateError('no')));
    expect(said.last, 'mark:paths failed: Bad state: no');
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a step that works just passes', (tester) async {
    await tester.runAsync(() => StartupTrace.step('language', () async => null));
    expect(said, ['mark:language…', 'mark:language ok']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('no native side is no problem', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dsh/startup'),
      null,
    );
    await tester.runAsync(() => StartupTrace.step('language', () async => null));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('other platforms run the step as they always did, and say nothing', (tester) async {
    await tester.runAsync(() async {
      var ran = false;
      await StartupTrace.step('language', () async => ran = true);
      expect(ran, isTrue);
      await expectLater(StartupTrace.step('launch', () async => throw StateError('no')), throwsStateError);
    });
    StartupTrace.mark('x');
    StartupTrace.finished();
    expect(said, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
