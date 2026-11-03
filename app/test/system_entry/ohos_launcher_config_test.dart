// How the HarmonyOS project wires the launcher's ways in: the parts a build
// accepts even when they're wrong, and a device only shows by doing nothing.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/links/launcher_entries.dart';
import 'package:flutter_test/flutter_test.dart';

const _project = 'ohos';
const _entryRes = '$_project/entry/src/main/resources';

Map<String, dynamic> _json(String path) => jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

/// `$media:name` as a layered icon under [resources]: both layers exist, 1024 px.
void _expectLayered(String resources, String reference) {
  expect(reference, startsWith(r'$media:'));
  final icon = _json('$resources/base/media/${reference.substring(7)}.json')['layered-image'] as Map<String, dynamic>;
  for (final layer in icon.values.cast<String>()) {
    final file = File('$resources/base/media/${layer.substring(7)}.png');
    expect(file.existsSync(), isTrue, reason: layer);
    final bytes = file.readAsBytesSync();
    final data = ByteData.sublistView(bytes);
    expect((data.getUint32(16), data.getUint32(20)), (1024, 1024), reason: layer);
  }
}

void main() {
  group('static shortcuts', () {
    final shortcuts = (_json('$_entryRes/base/profile/shortcuts_config.json')['shortcuts'] as List)
        .cast<Map<String, dynamic>>();

    test('EntryAbility declares them', () {
      final module = _json('$_project/entry/src/main/module.json5')['module'] as Map<String, dynamic>;
      final ability = (module['abilities'] as List).single as Map<String, dynamic>;
      expect(ability['name'], 'EntryAbility');
      expect(ability['metadata'], [
        {'name': 'ohos.ability.shortcuts', 'resource': r'$profile:shortcuts_config'},
      ]);
    });

    test('新对话 and 语音输入 go to this app, with what Dart parses', () {
      final app = _json('$_project/AppScope/app.json5')['app'] as Map<String, dynamic>;
      final entries = {
        for (final shortcut in shortcuts)
          shortcut['shortcutId'] as String: () {
            final want = (shortcut['wants'] as List).single as Map<String, dynamic>;
            expect(want['bundleName'], app['bundleName']);
            expect(want['moduleName'], 'entry');
            expect(want['abilityName'], 'EntryAbility');
            return LauncherEntry.parse({'kind': (want['parameters'] as Map)['dshShortcut']});
          }(),
      };
      expect(entries.keys, ['new_chat', 'voice_input']);
      expect(entries['new_chat'], isA<NewChatEntry>().having((e) => e.voice, 'voice', isFalse));
      expect(entries['voice_input'], isA<NewChatEntry>().having((e) => e.voice, 'voice', isTrue));
    });

    test('every label is there in both languages, in Android\'s words', () {
      final android = {
        'shortcut_new_chat': ('New chat', '新对话'),
        'shortcut_voice_input': ('Voice input', '语音输入'),
      };
      String? value(String locale, String name) {
        final strings = (_json('$_entryRes/$locale/element/string.json')['string'] as List).cast<Map<String, dynamic>>();
        return strings.where((s) => s['name'] == name).single['value'] as String?;
      }

      for (final shortcut in shortcuts) {
        final name = (shortcut['label'] as String).replaceFirst(r'$string:', '');
        expect(value('base', name), android[name]!.$1);
        expect(value('en_US', name), android[name]!.$1);
        expect(value('zh_CN', name), android[name]!.$2);
      }
    });

    test('every icon is layered, and follows dark mode as Android\'s does', () {
      for (final shortcut in shortcuts) {
        _expectLayered(_entryRes, shortcut['icon'] as String);
        final icon = _json('$_entryRes/base/media/${(shortcut['icon'] as String).substring(7)}.json')['layered-image'] as Map;
        for (final layer in icon.values.cast<String>()) {
          expect(File('$_entryRes/dark/media/${layer.substring(7)}.png').existsSync(), isTrue, reason: layer);
        }
      }
    });
  });
}
