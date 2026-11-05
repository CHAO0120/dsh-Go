// What makes the shared UI feel at home on iOS, and stay as it was elsewhere.

import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/common/overscroll_forwarder.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:dsh_app/ui/theme/motion.dart';
import 'package:dsh_app/ui/theme/sheet_recede.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _page = Key('page');
const _open = Key('open');

const _screen = 400.0;

Widget _app({required bool fluid}) => MediaQuery(
  data: const MediaQueryData(size: Size(_screen, 800)),
  child: MaterialApp(
    theme: buildLightTheme(),
    builder: (context, child) => AppMotionScope(fluid: fluid, child: child!),
    home: Scaffold(
      key: _page,
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            key: _open,
            onPressed: () => showAppSheet<void>(context, builder: (_) => const SizedBox(height: 300)),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  void useScreen(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(_screen, 800);
    addTearDown(tester.view.reset);
  }

  testWidgets('a press is a highlight on iOS, with no ripple', (tester) async {
    expect(buildLightTheme().splashFactory, NoSplash.splashFactory);
    expect(buildDarkTheme().splashFactory, NoSplash.splashFactory);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('other platforms keep their ripple', (tester) async {
    expect(buildLightTheme().splashFactory, isNot(NoSplash.splashFactory));
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('a drag past the end of an inner scroller moves the list around it', (tester) async {
    useScreen(tester);
    final outer = ScrollController();
    addTearDown(outer.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: outer,
            children: [
              SizedBox(
                height: 200,
                child: OverscrollForwarder(
                  child: SingleChildScrollView(
                    key: const Key('inner'),
                    child: Container(height: 210, color: const Color(0xFFEEEEEE)),
                  ),
                ),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    );
    await tester.drag(find.byKey(const Key('inner')), const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(outer.offset, greaterThan(50));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('the page sits back while a sheet is up, and comes back whole', (tester) async {
    useScreen(tester);
    await tester.pumpWidget(_app(fluid: true));
    await tester.pump();
    expect(tester.getRect(find.byKey(_page)).width, _screen);
    final page = tester.state(find.byKey(_page));

    await tester.tap(find.byKey(_open));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(_page)).width, closeTo(_screen * SheetRecede.scale, 0.5));

    await tester.tapAt(const Offset(_screen / 2, 40));
    await tester.pumpAndSettle();
    await tester.pump();
    expect(SheetRecede.amount.value, 0);
    expect(tester.getRect(find.byKey(_page)).width, _screen);
    expect(tester.state(find.byKey(_page)), same(page));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('off the fluid tier the page stays where it is', (tester) async {
    useScreen(tester);
    await tester.pumpWidget(_app(fluid: false));
    await tester.tap(find.byKey(_open));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(_page)).width, _screen);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('on Android the page stays where it is', (tester) async {
    useScreen(tester);
    await tester.pumpWidget(_app(fluid: true));
    await tester.tap(find.byKey(_open));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(_page)).width, _screen);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
