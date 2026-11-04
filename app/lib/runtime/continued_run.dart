// iOS 26 lets a task the user started keep running after the app leaves the screen. The native
// side has to ask while the app is in front, so it needs to know as soon as a local turn starts
// (ios/Runner/ContinuedRun.swift). HarmonyOS and older iOS have nothing to ask for.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/android_features.dart';
import '../state/chat_state.dart';
import '../state/hosts_state.dart';
import '../state/sessions_state.dart';
import 'runtime_state.dart';

/// Whether a turn is going on the on-device engine: in any listed conversation, or in the open
/// one, which a list doesn't show until it has its first message.
final localTurnRunningProvider = Provider<bool>((ref) {
  if (!ref.watch(activeHostProvider).isLocal) return false;
  final listed = ref.watch(sessionsProvider.select((sessions) => sessions.value?.any((s) => s.running) ?? false));
  if (listed) return true;
  final open = ref.watch(currentSessionProvider);
  return open != null && ref.watch(chatProvider(open).select((chat) => chat.running));
});

/// Keep this watched while the shell is up. Draws nothing and holds nothing.
final continuedRunProvider = Provider<void>((ref) {
  if (ref.watch(operatingSystemProvider) != 'ios') return;
  ref.listen(localTurnRunningProvider, (was, now) {
    if (was == now) return;
    unawaited(_tell(ref, now));
  }, fireImmediately: true);
});

Future<void> _tell(Ref ref, bool running) async {
  try {
    await ref.read(runtimeBridgeProvider).setTurnRunning(running);
  } on MissingPluginException {
    // A build without the engine.
  } on PlatformException {
    // The engine's channel refused. Nothing depends on this: it would pause, as it does anyway.
  }
}
