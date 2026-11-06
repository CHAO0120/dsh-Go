"""Portable preparation and attribution tests; no device or network required."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class BuildInputs(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='dsh-phone-input-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.prepare = module('prepare_test', ROOT / 'prepare_upstream.py')
        self.prepare.HERE = self.root
        self.pins = {'commit': 'test', 'archive': 'https://invalid.example/unused',
                     'archiveSha256': '0' * 64, 'patch': 'local.patch'}
        (self.root / 'local.patch').write_text('test patch\n')
        self.save_pins()

    def save_pins(self):
        (self.root / 'source-pins.json').write_text(json.dumps(self.pins))

    def archive(self, name, *, link=None):
        path = self.root / 'test.tar.gz'
        with tarfile.open(path, 'w:gz') as archive:
            entry = tarfile.TarInfo(name)
            if link:
                entry.type = tarfile.SYMTYPE
                entry.linkname = link
                archive.addfile(entry)
            else:
                data = b'fixture'
                entry.size = len(data)
                archive.addfile(entry, io.BytesIO(data))
        self.pins['archiveSha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        self.save_pins()
        return path

    def test_checksum_is_verified_before_extraction(self):
        path = self.root / 'bad.tar.gz'
        path.write_bytes(b'not the pinned archive')
        with self.assertRaisesRegex(ValueError, 'SHA256'):
            self.prepare.prepare(path)
        self.assertFalse((self.root / '.upstream').exists())

    def test_archive_paths_cannot_escape_source_root(self):
        for name in ['/absolute/file', 'idevice-test/../outside', 'wrong-prefix/file']:
            with self.subTest(name=name):
                with self.assertRaisesRegex(ValueError, 'Unsafe'):
                    self.prepare.prepare(self.archive(name))
        self.assertFalse((self.root / 'outside').exists())

    def test_archive_links_must_match_the_single_materialized_readme(self):
        with self.assertRaisesRegex(ValueError, 'non-regular'):
            self.prepare.prepare(self.archive('idevice-test/idevice/README.md', link='../../outside'))

    def test_existing_symlinked_output_is_never_written(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (self.root / '.upstream').symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'symlinked'):
            self.prepare.prepare()
        self.assertEqual(list(outside.iterdir()), [])

    def test_changed_prepared_source_is_preserved_and_rejected(self):
        output = self.root / '.upstream'
        output.mkdir()
        (output / 'source.rs').write_text('changed\n')
        identity = {'commit': 'test', 'archiveSha256': self.pins['archiveSha256'],
                    'patchSha256': hashlib.sha256((self.root / 'local.patch').read_bytes()).hexdigest()}
        (output / '.dsh-source.json').write_text(json.dumps({'identity': identity, 'files': {'source.rs': 'wrong'}}))
        with self.assertRaisesRegex(ValueError, 'differs'):
            self.prepare.prepare()
        self.assertEqual((output / 'source.rs').read_text(), 'changed\n')

    def test_license_inventory_has_no_host_paths_or_raw_metadata(self):
        exporter = module('license_test', ROOT / 'license_inventory.py')
        packages = [{'name': 'idevice', 'version': '0.1.68', 'license': 'MIT', 'source': None,
                     'manifest_path': '/private/user/credentials/Cargo.toml'},
                    {'name': 'dsh-phone-self-runner', 'version': '0.1.0', 'license': 'AGPL-3.0-only', 'source': None},
                    {'name': 'serde', 'version': '1', 'license': 'MIT OR Apache-2.0', 'source': 'registry+https://github.com/rust-lang/crates.io-index'}]
        report = exporter.inventory({'packages': packages})
        self.assertNotIn('/private', json.dumps(report))
        self.assertEqual(set(report['packages'][0]), {'name', 'version', 'license', 'source'})
        with self.assertRaisesRegex(ValueError, 'Unexpected local'):
            exporter.inventory({'packages': [{'name': 'unknown-local', 'version': '1', 'source': None}]})


class BuildScript(unittest.TestCase):
    """Exercise publication with fixture tools, not an Apple compiler."""
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='dsh-phone-build-test-')
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name) / 'repo with spaces'
        native = self.repo / 'tooling/ios/phone-self-runner'
        native.mkdir(parents=True)
        self.script = native.parent / 'build-phone-self-runner.sh'
        shutil.copyfile(ROOT.parent / 'build-phone-self-runner.sh', self.script)
        for name in ['license_inventory.py', 'source-pins.json']:
            shutil.copyfile(ROOT / name, native / name)
        (native / 'prepare_upstream.py').write_text('print("fixture upstream only")\n')
        (native / '.upstream').mkdir()
        (native / '.upstream/LICENSE.txt').write_text('fixture upstream MIT license\n')
        self.tools = self.repo / 'tools'
        self.tools.mkdir()
        for name, body in {
            'uname': '#!/bin/sh\nprintf Darwin',
            'xcrun': '#!/bin/sh\nexit 0',
            'rustup': '#!/bin/sh\nexit 0',
            'cargo': '''#!/usr/bin/env python3
import json,os,pathlib,sys
if 'metadata' in sys.argv:
 print(json.dumps({'packages':[{'name':'idevice','version':'0.1.68','license':'MIT','source':None,'manifest_path':'/private/host/secret'}]}))
else:
 target=sys.argv[sys.argv.index('--target')+1]
 if os.environ.get('FAIL_SLICE')==target: sys.exit(23)
 base=pathlib.Path(sys.argv[sys.argv.index('--target-dir')+1])/target/'release'
 base.mkdir(parents=True,exist_ok=True)
 (base/'libdsh_phone_self_runner.a').write_text('fixture slice '+target)
''',
        }.items():
            path = self.tools / name
            path.write_text(body)
            path.chmod(0o755)
        self.out = self.repo / 'app/ios/PhoneSelfRunnerNative'

    def run_build(self, fail=None):
        env = {**os.environ, 'PATH': str(self.tools) + os.pathsep + os.environ['PATH']}
        if fail:
            env['FAIL_SLICE'] = fail
        return subprocess.run(['bash', str(self.script)], env=env, capture_output=True, text=True, timeout=20)

    def test_success_publishes_three_slices_and_sanitized_attribution(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for platform, arch in [('iphoneos','arm64'),('iphonesimulator','arm64'),('iphonesimulator','x86_64')]:
            self.assertTrue((self.out / platform / arch / 'libdsh_phone_self_runner.a').is_file())
        config = (self.out / 'PhoneSelfRunner.xcconfig').read_text()
        self.assertIn('DSH_PHONE_SELF_RUNNER_ENABLED = YES', config)
        self.assertIn('$(PLATFORM_NAME)/$(CURRENT_ARCH)', config)
        report = (self.out / 'THIRD_PARTY_CRATES.json').read_text()
        self.assertNotIn('/private', report)
        self.assertEqual(json.loads(report)['packages'][0]['license'], 'MIT')
        self.assertTrue((self.out / 'LICENSE.idevice.txt').is_file())
        self.assertEqual(list(self.out.glob('.build.*')), [])

    def test_failed_slice_cannot_enable_a_first_build(self):
        result = self.run_build('aarch64-apple-ios-sim')
        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
        self.assertFalse((self.out / 'PhoneSelfRunner.xcconfig').exists())
        self.assertFalse((self.out / 'iphoneos').exists())
        self.assertEqual(list(self.out.glob('.build.*')), [])


if __name__ == '__main__':
    unittest.main()
