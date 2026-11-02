import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether this OS has what only Android has: an accessibility service to
/// drive the phone (手机操控), windows over other apps, battery exemptions and
/// the makers' switches (后台保活, 系统权限) and refresh-rate caps, launcher icons
/// and shortcuts, a launch screen of one's own. Without them their pages and rows aren't there
/// at all, in the hub, search and links alike.
///
/// HarmonyOS has none of these and won't grow them, so this asks the OS, where
/// [LocalRuntimeState.available] and [AppUpdateState.installable] ask for a
/// channel handler that may still come. `Platform.isOhos` only exists on
/// oh-flutter's Dart, hence the string.
final androidSystemFeaturesProvider = Provider<bool>((ref) => Platform.operatingSystem != 'ohos');
