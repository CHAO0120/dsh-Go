#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('audit_dart_bridges',HERE.parent/'audit-dart-bridges.py')
audit=importlib.util.module_from_spec(spec);sys.modules[spec.name]=audit;spec.loader.exec_module(audit)

class BridgeInventoryTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
        self.dart=self.root/'app/lib/calls.dart';self.dart.parent.mkdir(parents=True)
        self.native=self.root/'app/ohos/entry/src/main/ets/plugins/FixturePlugin.ets';self.native.parent.mkdir(parents=True)
        self.entry=self.native.parent.parent/'entryability/EntryAbility.ets';self.entry.parent.mkdir()
        for source,target in [('calls.dart',self.dart),('FixturePlugin.ets',self.native),('EntryAbility.ets',self.entry)]:
            shutil.copy2(HERE/'fixtures/dart-bridges'/source,target)

    def report(self,required=('dsh/first','dsh/second')):
        return audit.audit(self.root,{},required)

    def test_literals_generics_inline_system_event_and_callback_are_distinct(self):
        report=self.report()
        self.assertEqual(report['gateStatus'],'PASS_SCOPED')
        self.assertEqual(len(report['dartCalls']),5)
        self.assertEqual(report['counts'],{'HANDLER_PRESENT':3,'SYSTEM_BUILTIN_NOT_APP_ARKTS':1,'EVENT_HANDLER_PRESENT':1})
        self.assertEqual(len(report['nativeToDartCallbacks']),1)
        self.assertEqual(report['nativeToDartCallbacks'][0]['classification'],'NATIVE_TO_DART_CALLBACK')

    def test_another_channel_and_unreachable_or_unrelated_cases_do_not_satisfy_call(self):
        with self.dart.open('a') as f:f.write("\nvoid missing() { first.invokeMethod('list'); second.invokeMethod('unreachable'); second.invokeMethod('unrelatedCase'); }\n")
        report=self.report()
        failed=[r for r in report['dartCalls'] if r['status']=='MISSING_METHOD']
        self.assertEqual([r['method'] for r in failed],['list','unreachable','unrelatedCase'])
        self.assertEqual(report['gateStatus'],'FAIL')

    def test_handler_definition_without_entry_registration_stays_unconfirmed(self):
        self.entry.write_text('const unrelated = new FixturePlugin();')
        report=self.report()
        self.assertEqual(report['gateStatus'],'FAIL')
        self.assertTrue(any(r['status']=='UNCONFIRMED_REGISTRATION' for r in report['dartCalls']))

    def test_dynamic_method_is_unknown_and_required_scope_fails(self):
        with self.dart.open('a') as f:f.write('\nvoid dynamicCall(String method) { first.invokeMethod(method); }\n')
        report=self.report()
        self.assertEqual(report['gateStatus'],'FAIL')
        self.assertEqual(report['fullInventoryStatus'],'INCOMPLETE')
        self.assertEqual(report['counts']['UNKNOWN_DYNAMIC'],1)

    def test_scoped_success_does_not_erase_other_channel_gap(self):
        with self.dart.open('a') as f:f.write("\nvoid missing() { const MethodChannel('dsh/unknown').invokeMethod('x'); }\n")
        report=self.report()
        self.assertEqual(report['gateStatus'],'PASS_SCOPED')
        self.assertEqual(report['fullInventoryStatus'],'INCOMPLETE')
        self.assertEqual(report['counts']['MISSING_CHANNEL'],1)

    def test_all_seven_forks_remain_in_report_even_missing_inputs(self):
        rows=self.report()['forks']
        self.assertEqual([row['package'] for row in rows],list(audit.FORKS))
        self.assertTrue(all(row['status']=='UNKNOWN_MISSING_PACKAGE' for row in rows))

    def test_unresolved_alias_in_required_channel_file_does_not_auto_pass(self):
        with self.dart.open('a') as f:f.write("\nvoid indirect(dynamic alias) { alias.invokeMethod('read'); }\n")
        report=self.report()
        self.assertEqual(report['gateStatus'],'FAIL')
        row=next(row for row in report['dartCalls'] if row['receiver']=='alias')
        self.assertEqual(row['status'],'UNKNOWN_DYNAMIC')

    def test_constructor_default_and_field_receiver_resolve_without_claiming_injected_value(self):
        self.dart.write_text("import 'package:flutter/services.dart'; class Consumer { Consumer({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('dsh/first'); final MethodChannel _channel; Future<void> run() async { await _channel.invokeMethod('read'); } }")
        report=self.report(('dsh/first',))
        self.assertEqual(report['gateStatus'],'PASS_SCOPED')
        self.assertEqual(report['dartCalls'][0]['channel'],'dsh/first')

    def test_selector_gap_is_not_hidden_by_channel_presence(self):
        fork=self.root/'secure';(fork/'lib').mkdir(parents=True)
        (fork/'pubspec.yaml').write_text('name: flutter_secure_storage\nflutter:\n  plugin:\n    platforms:\n      android:\n        pluginClass: SecurePlugin\n')
        (fork/'lib/flutter_secure_storage.dart').write_text("class Store { Map<String,String> _selectOptions() { if (defaultTargetPlatform == TargetPlatform.android) return {}; else throw UnsupportedError('unsupported_platform'); } }")
        report=audit.audit(self.root,{'flutter_secure_storage':fork},('dsh/first',))
        row=next(row for row in report['forks'] if row['package']=='flutter_secure_storage')
        self.assertEqual(row['status'],'NO_OH_DECLARATION')
        self.assertEqual(row['findings'][0]['kind'],'OH_SELECT_OPTIONS_MISSING_BRANCH')
        self.assertEqual(report['gateStatus'],'PASS_SCOPED')

    def test_unrelated_adapter_occurrence_does_not_certify_storage_default(self):
        wrapper=self.root/'app/lib/secrets/secure_storage.dart';wrapper.parent.mkdir()
        wrapper.write_text("class AppSecureStorage { bool get oh => _injected == null && (_platform ?? Platform.operatingSystem) == 'ohos'; }")
        consumers={
            'app/lib/remote/secret_store.dart': 'class SecureSecretStore { SecureSecretStore([FlutterSecureStorage? storage]) : _storage = AppSecureStorage(storage); final AppSecureStorage _storage; }',
            'app/lib/forum/forum_auth.dart': 'class SecureForumStore { SecureForumStore([FlutterSecureStorage? storage]) : _storage = AppSecureStorage(storage); final AppSecureStorage _storage; }',
            'app/lib/state/settings_state.dart': 'class SettingsController { static const _secure = AppSecureStorage(); }',
            'app/lib/state/provider_keys.dart': 'class SecureProviderKeyVault { const SecureProviderKeyVault([this._injected]); final FlutterSecureStorage? _injected; AppSecureStorage get _storage => AppSecureStorage(_injected); }',
            'app/lib/share_hosted/hosted_links_state.dart': 'class SecureHostedLinkStore { const SecureHostedLinkStore([this._injected]); final FlutterSecureStorage? _injected; AppSecureStorage get _storage => AppSecureStorage(_injected); }'}
        for relative,body in consumers.items():
            path=self.root/relative;path.parent.mkdir(parents=True,exist_ok=True);path.write_text(body)
        self.assertEqual(audit.application_overrides(self.root)['secrets']['status'],'EXPLICIT_SOURCE_DEFAULTS')
        for relative,body in consumers.items():
            with self.subTest(source=relative):
                path=self.root/relative
                path.write_text(body.replace('AppSecureStorage(', 'FlutterSecureStorage(')
                                + '\nvoid unrelated() { AppSecureStorage(); }')
                report=audit.application_overrides(self.root)['secrets']
                self.assertEqual(report['status'],'MISSING_OR_UNKNOWN_OH_DEFAULT')
                self.assertFalse(next(row for row in report['consumers'] if row['source']==relative)['explicitAdapterDefault'])
                path.write_text(body)
        path=self.root/'app/lib/state/settings_state.dart'
        path.write_text('class SettingsController { void unused() { const _secure = AppSecureStorage(); } } class Unrelated { static const _secure = AppSecureStorage(); }')
        self.assertEqual(audit.application_overrides(self.root)['secrets']['status'],'MISSING_OR_UNKNOWN_OH_DEFAULT')

if __name__=='__main__':unittest.main()
