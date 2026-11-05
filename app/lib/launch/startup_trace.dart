// How far the app has got on its way to its first page, on iOS. A step that hangs before runApp
// would otherwise leave the launch screen up for good, and with a TestFlight build there's no
// console to read: StartupWatch (ios/Runner/LaunchChannel.swift) puts this on the screen if the
// app doesn't get there. Other platforms run the steps as they always did.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';

abstract final class StartupTrace {
  static const _channel = MethodChannel('dsh/startup');

  /// How long one step may hold up the first frame. Each normally takes a few milliseconds.
  @visibleForTesting
  static Duration limit = const Duration(seconds: 4);

  static bool get _on => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static void mark(String stage) {
    if (!_on) return;
    debugPrint('[dsh-startup] $stage');
    unawaited(_send('mark', stage));
  }

  /// The launch screen isn't in the way any more, or there was none.
  static void finished() {
    if (_on) unawaited(_send('finished', null));
  }

  /// One thing the first frame waits for. On iOS it can't stop the app from starting: a step that
  /// hangs or throws is noted and the app goes on without it.
  static Future<void> step(String name, Future<Object?> Function() run) async {
    if (!_on) {
      await run();
      return;
    }
    mark('$name…');
    try {
      await run().timeout(limit);
      mark('$name ok');
    } on TimeoutException {
      mark('$name timed out');
    } on Object catch (error) {
      mark('$name failed: $error');
    }
  }

  static Future<void> _send(String method, String? stage) async {
    try {
      await _channel.invokeMethod<void>(method, stage);
    } on Object {
      // Only ever a note: no native side here means nothing to tell.
    }
  }
}
