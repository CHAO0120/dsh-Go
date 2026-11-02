#!/usr/bin/env python3
"""Real tiny archive/manifest tests; Python + PATH tar/xz, no downloaded inputs."""
import argparse
import contextlib
import copy
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('rtbuild_layers', ROOT / 'lib/rtbuild.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
sha = lambda data: hashlib.sha256(data).hexdigest()


def input_tar(path, rows):
    with tarfile.open(path, 'w:gz') as archive:
        for name, data, mode, kind, link in rows:
            item = tarfile.TarInfo(name)
            item.mode, item.mtime = mode, 1767225600
            item.type, item.linkname = kind, link
            item.size = len(data) if kind == tarfile.REGTYPE else 0
            archive.addfile(item, io.BytesIO(data) if item.isreg() else None)


def inventory(fileobj):
    with tarfile.open(fileobj=fileobj, mode='r:*') as archive:
        return {m.name: (m.type, m.mode, m.uid, m.gid, m.uname, m.gname,
                         m.mtime, m.linkname, archive.extractfile(m).read() if m.isfile() else None)
                for m in archive}


class RuntimeLayers(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.inputs = self.path / 'inputs'
        self.inputs.mkdir()
        input_tar(self.inputs / 'base.tgz', [
            ('usr/bin/sh', b'shell\n', 0o755, tarfile.REGTYPE, ''),
            ('bin', b'', 0o777, tarfile.SYMTYPE, '/usr/bin'),
            ('usr/bin/sh-copy', b'', 0o755, tarfile.LNKTYPE, 'usr/bin/sh'),
            ('etc/locked', b'configuration', 0o400, tarfile.REGTYPE, ''),
            ('etc/' + 'long-' * 30 + '中文', b'unicode', 0o644, tarfile.REGTYPE, ''),
        ])
        input_tar(self.inputs / 'node.tgz', [
            ('node-fixture/bin/node', b'node\n', 0o755, tarfile.REGTYPE, ''),
        ])
        for name in ('dsh/node_modules/pkg/index.js', 'dsh/node_modules/pkg/addon.node', 'bridge/lib/index.js'):
            p = self.inputs / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(b'fixture-v1\n')
            p.chmod(0o644)
        self.info = dict(abi='arm64-v8a', dshVersion='fixture', nodeVersion='fixture')
        self.versions = {key: 'fixture' for key in ('dshVersion', 'nodeVersion', 'pnpmVersion',
                         'ubuntuVersion', 'prootVersion', 'tallocVersion', 'androidShmemVersion')}
        self.versions['build'] = {'inputsSha256_12': 'descriptive-only'}
        self.jni = {'libproot.so': {'sha256': sha(b'jni'), 'bytes': 3, 'source': 'description'}}

    def build(self, label='one', compress='gz', level=9, epoch=1767225600, info=None, versions=None, jni=None):
        out = self.path / label
        out.mkdir()
        args = argparse.Namespace(abi='arm64-v8a', base=str(self.inputs / 'base.tgz'),
            node=str(self.inputs / 'node.tgz'), dsh_prefix=str(self.inputs / 'dsh'),
            bridge=str(self.inputs / 'bridge'), pnpm_prefix=None, deb=None, python=None,
            prune_dev_metadata=False, runtime_info=json.dumps(self.info if info is None else info),
            out=str(out), report=str(out / 'report.json'), compress=compress, gzip_level=level,
            xz_preset='1', threads=1, epoch=epoch)
        (out / 'jni.json').write_text(json.dumps(self.jni if jni is None else jni))
        with contextlib.redirect_stdout(io.StringIO()):
            r.cmd_assemble(args)
            r.cmd_manifest(argparse.Namespace(abi=args.abi, report=args.report,
                jnilibs=str(out / 'jni.json'), versions=json.dumps(self.versions if versions is None else versions),
                out=str(out / 'manifest.json')))
        return out, json.loads((out / 'manifest.json').read_text()), args

    def test_union_matches_original_normalized_tree_and_metadata(self):
        out, manifest, args = self.build()
        entries, _ = r.assemble_entries(args)
        entries[r.RUNTIME_IDENTITY].data = (out / 'runtime-info.json').read_bytes()
        reference = io.BytesIO()
        r.write_tar(entries, reference, args.epoch)
        reference.seek(0)
        expected = inventory(reference)
        actual = {}
        for name in r.LAYER_NAMES:
            item = manifest['layers'][name]
            raw = (out / item['asset']).read_bytes()
            decoded = gzip.decompress(raw)
            self.assertEqual((sha(raw), len(raw)), (item['archiveSha256'], item['bytes']))
            self.assertEqual((sha(decoded), len(decoded)), (item['contentSha256'], item['tarBytes']))
            part = inventory(io.BytesIO(decoded))
            self.assertFalse(actual.keys() & part.keys())
            self.assertNotIn(r.RUNTIME_IDENTITY, part)
            actual.update(part)
        identity = (out / 'runtime-info.json').read_bytes()
        actual[r.RUNTIME_IDENTITY] = (tarfile.REGTYPE, 0o644, 0, 0, 'root', 'root', args.epoch, '', identity)
        self.assertEqual(expected, actual)
        self.assertEqual(actual['bin'][7], 'usr/bin')
        self.assertEqual(actual['usr/bin/sh-copy'][8], b'shell\n')
        self.assertEqual(actual['etc/locked'][1], 0o600)
        self.assertEqual(manifest['rootfsBytes'], sum(manifest['layers'][n]['bytes'] for n in r.LAYER_NAMES) + len(identity))
        self.assertEqual(manifest['uncompressedBytes'], sum(len(v[8]) for v in actual.values() if v[8] is not None))
        self.assertEqual(sum(manifest['entries'].values()), len(actual))

    def test_identity_only_and_provenance_do_not_invalidate_code_layers(self):
        _, first, _ = self.build()
        info = {**self.info, 'dshVersion': 'new-description'}
        versions = {**self.versions, 'build': {'inputsSha256_12': 'changed-comment-or-recipe'}}
        _, second, _ = self.build('two', info=info, versions=versions)
        self.assertEqual(first['layers'], second['layers'])
        self.assertEqual(first['runtimeVersion'], second['runtimeVersion'])
        self.assertNotEqual(first['runtimeIdentity']['sha256'], second['runtimeIdentity']['sha256'])

    def test_compression_changes_archive_not_content_or_version(self):
        _, first, _ = self.build(level=1)
        _, second, _ = self.build('two', level=9)
        self.assertEqual(first['runtimeVersion'], second['runtimeVersion'])
        self.assertTrue(any(first['layers'][n]['archiveSha256'] != second['layers'][n]['archiveSha256'] for n in r.LAYER_NAMES))
        for n in r.LAYER_NAMES:
            self.assertEqual(first['layers'][n]['contentSha256'], second['layers'][n]['contentSha256'])

    @unittest.skipUnless(shutil.which('xz'), 'PATH xz required for supported xz output')
    def test_xz_and_gzip_have_same_content_identity(self):
        _, a, _ = self.build()
        _, b, _ = self.build('two', compress='xz')
        self.assertEqual(a['runtimeVersion'], b['runtimeVersion'])
        for n in r.LAYER_NAMES:
            self.assertEqual(a['layers'][n]['contentSha256'], b['layers'][n]['contentSha256'])

    def test_layer_changes_and_native_inventory_dependency(self):
        _, baseline, _ = self.build()
        for label, relative, expected in (
            ('go', 'bridge/lib/index.js', {'go'}),
            ('dsh', 'dsh/node_modules/pkg/index.js', {'dsh'}),
            ('addon', 'dsh/node_modules/pkg/addon.node', {'dsh', 'go'})):
            source = self.inputs / relative
            before = source.read_bytes()
            source.write_bytes(b'fixture-v2\n')
            _, changed, _ = self.build(label)
            source.write_bytes(before)
            self.assertEqual(expected, {n for n in r.LAYER_NAMES if baseline['layers'][n]['contentSha256'] != changed['layers'][n]['contentSha256']})
            self.assertNotEqual(baseline['runtimeVersion'], changed['runtimeVersion'])

    def test_tar_metadata_and_jni_are_output_identity(self):
        _, first, _ = self.build()
        _, epoch, _ = self.build('epoch', epoch=1767225601)
        self.assertNotEqual(first['runtimeVersion'], epoch['runtimeVersion'])
        jni = copy.deepcopy(self.jni)
        jni['libproot.so']['sha256'] = sha(b'new')
        _, changed, _ = self.build('jni', jni=jni)
        self.assertEqual(first['layers'], changed['layers'])
        self.assertNotEqual(first['runtimeVersion'], changed['runtimeVersion'])

    def test_base_mode_and_link_changes_are_not_lost(self):
        _, first, _ = self.build()
        input_tar(self.inputs / 'node.tgz', [
            ('node-fixture/bin/node', b'new-node\n', 0o755, tarfile.REGTYPE, ''),
        ])
        _, base, _ = self.build('base')
        self.assertEqual({'base'}, {n for n in r.LAYER_NAMES if first['layers'][n]['contentSha256'] != base['layers'][n]['contentSha256']})
        source = self.inputs / 'dsh/node_modules/pkg/index.js'
        source.chmod(0o755)
        link = source.parent / 'alias'
        link.symlink_to('index.js')
        _, a, _ = self.build('mode-and-link')
        self.assertNotEqual(base['layers']['dsh']['contentSha256'], a['layers']['dsh']['contentSha256'])
        link.unlink()
        link.symlink_to('addon.node')
        _, b, _ = self.build('changed-link')
        self.assertNotEqual(a['layers']['dsh']['contentSha256'], b['layers']['dsh']['contentSha256'])
        self.assertNotEqual(a['runtimeVersion'], b['runtimeVersion'])

    def test_launch_semantics_but_not_launch_documentation_change_version(self):
        _, first, _ = self.build()
        template = r.launch_template()
        template['health']['tcp'] = 'documentation correction'
        with patch.object(r, 'launch_template', return_value=template):
            _, docs, _ = self.build('docs')
        self.assertEqual(first['runtimeVersion'], docs['runtimeVersion'])
        template['env']['UV_USE_IO_URING'] = '0'
        with patch.object(r, 'launch_template', return_value=template):
            _, launch, _ = self.build('launch')
        self.assertEqual(first['layers'], launch['layers'])
        self.assertNotEqual(first['runtimeVersion'], launch['runtimeVersion'])

    def test_recipe_comment_does_not_change_actual_cli_output(self):
        out, original, args = self.build()
        recipe = self.path / 'recipe'
        (recipe / 'lib').mkdir(parents=True)
        script = recipe / 'lib/rtbuild.py'
        script.write_text((ROOT / 'lib/rtbuild.py').read_text() + '\n# recipe-only comment\n')
        shutil.copytree(ROOT / 'boot', recipe / 'boot')
        shutil.copytree(ROOT / 'direct', recipe / 'direct')
        assets = self.path / 'comment-assets'
        command = [sys.executable, '-I', str(script), 'assemble', '--abi', args.abi,
            '--base', args.base, '--node', args.node, '--dsh-prefix', args.dsh_prefix,
            '--bridge', args.bridge, '--out', str(assets), '--report', str(assets / 'report.json'),
            '--runtime-info', args.runtime_info, '--compress', 'gz', '--epoch', str(args.epoch)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = subprocess.run([sys.executable, '-I', str(script), 'manifest', '--abi', args.abi,
            '--report', str(assets / 'report.json'), '--jnilibs', str(out / 'jni.json'),
            '--versions', json.dumps(self.versions), '--out', str(assets / 'manifest.json')],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        changed = json.loads((assets / 'manifest.json').read_text())
        self.assertEqual(original, changed)
        for name in r.LAYER_NAMES:
            self.assertEqual((out / original['layers'][name]['asset']).read_bytes(),
                             (assets / changed['layers'][name]['asset']).read_bytes())

    def test_actual_abi_index_skips_unrebuilt_old_format(self):
        _, manifest, _ = self.build()
        output = self.path / 'abi-output'
        current = output / 'arm64-v8a/assets/runtime'
        current.mkdir(parents=True)
        (current / 'manifest.json').write_text(json.dumps(manifest))
        old = output / 'x86_64/assets/runtime'
        old.mkdir(parents=True)
        (old / 'manifest.json').write_text(json.dumps({'schema': 1, 'rootfs': 'rootfs-x86_64.tar.xz'}))
        # Execute the actual write_index body, without downloading/building ABI inputs.
        script = (ROOT / 'build-runtime.sh').read_text().split('write_index() {\n', 1)[1]
        code = script.split("<<'PYEOF'\n", 1)[1].split('\nPYEOF', 1)[0]
        result = subprocess.run([sys.executable, '-I', '-', str(output)], input=code,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        index = json.loads((output / 'manifest.json').read_text())
        self.assertEqual(index['schema'], 2)
        self.assertEqual(set(index['abis']), {'arm64-v8a'})
        self.assertEqual(index['abis']['arm64-v8a']['layers'], manifest['layers'])
        self.assertTrue((old / 'manifest.json').exists())
        (old / 'manifest.json').write_text(json.dumps({**manifest, 'abi': 'x86_64'}))
        result = subprocess.run([sys.executable, '-I', '-', str(output)], input=code,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(set(json.loads((output / 'manifest.json').read_text())['abis']),
                         {'arm64-v8a', 'x86_64'})

    def test_layer_root_must_be_real_directory(self):
        _, _, args = self.build()
        entries, _ = r.assemble_entries(args)
        entries['opt/dsh'] = r.Entry('symlink', 0o777, link='elsewhere')
        with self.assertRaisesRegex(SystemExit, 'layer root must be a directory'):
            r.split_layers(entries)

    @unittest.skipUnless(shutil.which('tar'), 'PATH tar required by existing host extraction')
    def test_host_consumer_verifies_all_assets_before_materializing(self):
        out, manifest, _ = self.build()
        target = self.path / 'host'
        r.cmd_extract_host(argparse.Namespace(manifest=str(out / 'manifest.json'), out=str(target)))
        self.assertEqual((target / 'usr/bin/sh-copy').read_bytes(), b'shell\n')
        self.assertEqual(os.readlink(target / 'bin'), 'usr/bin')
        self.assertEqual((target / r.RUNTIME_IDENTITY).read_bytes(), (out / 'runtime-info.json').read_bytes())
        self.assertEqual((target / r.RUNTIME_IDENTITY).stat().st_mode & 0o777, 0o644)
        (out / manifest['layers']['go']['asset']).write_bytes(b'corrupt')
        refused = self.path / 'refused'
        with self.assertRaisesRegex(SystemExit, 'checksum mismatch'):
            r.cmd_extract_host(argparse.Namespace(manifest=str(out / 'manifest.json'), out=str(refused)))
        self.assertFalse(refused.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
