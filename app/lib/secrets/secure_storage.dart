import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The four secret-storage operations used by this app.
///
/// OH uses the app's HUKS channel. Other platforms and explicit test injections
/// keep the original flutter_secure_storage implementation and options.
class AppSecureStorage {
  const AppSecureStorage([this._injected]) : _platform = null;

  @visibleForTesting
  const AppSecureStorage.forPlatform(String operatingSystem, [this._injected]) : _platform = operatingSystem;

  final FlutterSecureStorage? _injected;
  final String? _platform;
  static const _channel = MethodChannel('dsh/secrets');

  bool get _ohos => _injected == null && (_platform ?? Platform.operatingSystem) == 'ohos';
  FlutterSecureStorage get _fallback => _injected ?? const FlutterSecureStorage();

  Future<String?> read({required String key}) async {
    if (!_ohos) return _fallback.read(key: key);
    final value = await _channel.invokeMethod<Object?>('read', {'key': key});
    if (value == null || value is String) return value as String?;
    throw const FormatException('Invalid secret-storage response');
  }

  Future<void> write({required String key, required String? value}) async {
    if (!_ohos) return _fallback.write(key: key, value: value);
    if (value == null) return delete(key: key);
    await _channel.invokeMethod<void>('write', {'key': key, 'value': value});
  }

  Future<void> delete({required String key}) async {
    if (!_ohos) return _fallback.delete(key: key);
    await _channel.invokeMethod<void>('delete', {'key': key});
  }

  Future<Map<String, String>> readAll() async {
    if (!_ohos) return _fallback.readAll();
    final value = await _channel.invokeMethod<Object?>('readAll');
    if (value is! Map) throw const FormatException('Invalid secret-storage response');
    final result = <String, String>{};
    for (final entry in value.entries) {
      if (entry.key is! String || entry.value is! String) {
        throw const FormatException('Invalid secret-storage response');
      }
      result[entry.key as String] = entry.value as String;
    }
    return result;
  }
}
