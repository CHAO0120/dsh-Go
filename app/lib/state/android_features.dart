import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The OS by Dart's name for it, read through here so a test can be on another
/// one. `Platform.isOhos` only exists on oh-flutter's Dart, hence the string.
final operatingSystemProvider = Provider<String>((ref) => Platform.operatingSystem);

/// Whether this OS has what only Android has: an accessibility service to
/// drive the phone (手机操控), windows over other apps, battery exemptions and
/// the makers' switches (后台保活, 系统权限) and refresh-rate caps, launcher icons
/// and shortcuts, a launch screen of one's own, and the rescue tools that work on
/// its Linux guest (安全模式, 重置和卸载运行环境, Direct 引擎). Without them their
/// pages and rows aren't there at all, in the hub, search and links alike.
///
/// HarmonyOS has none of these and won't grow them, so this asks the OS, where
/// [LocalRuntimeState.available] and [AppUpdateState.installable] ask for a
/// channel handler that may still come.
final androidSystemFeaturesProvider = Provider<bool>((ref) => ref.watch(operatingSystemProvider) != 'ohos');
