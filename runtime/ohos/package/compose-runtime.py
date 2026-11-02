#!/usr/bin/env python3
"""Assemble a fixed OHOS rawfile payload; never modifies the input prefixes.

Native libraries are separate HAP libs inputs. This does not build or sign a HAP.
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

sys.dont_write_bytecode = True


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def json_bytes(value) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()


def package_names(relative: str):
    parts = PurePosixPath(relative).parts
    for i, part in enumerate(parts[:-1]):
        if part == 'node_modules':
            yield '/'.join(parts[i + 1:i + 3]) if parts[i + 1].startswith('@') else parts[i + 1]


def package_path(relative: str) -> str:
    parts = PurePosixPath(relative).parts
    position = max(i for i, part in enumerate(parts) if part == 'node_modules')
    count = 3 if parts[position + 1].startswith('@') else 2
    return '/'.join(parts[:position + count])


def package_reason(relative: str, rules: dict[str, str]) -> str | None:
    for name in package_names(relative):
        for pattern, reason in rules.items():
            if fnmatch.fnmatchcase(name, pattern):
                return reason
    return None


def safe_path(relative: str) -> None:
    if ('\\' in relative or '\0' in relative or
            any(part in ('', '.', '..') for part in relative.split('/')) or
            re.search(r'(?:\.node|\.so(?:\.[0-9]+)*)$', relative, re.I)):
        raise ValueError(f'Not a P2 rawfile path: {relative}')


def records(root: Path):
    for parent, dirs, files in os.walk(root, followlinks=False):
        dirs.sort()
        files.sort()
        for name in dirs[:]:
            path = Path(parent) / name
            if path.is_symlink():
                dirs.remove(name)
                yield path
        for name in files:
            yield Path(parent) / name


class Composer:
    def __init__(self, files: Path):
        self.files = files
        self.inputs = []
        self.payload = {}
        self.removed = {}

    def add(self, source: Path, source_root: Path, label: str, destination: str,
            reason: str | None = None):
        relative = source.relative_to(source_root).as_posix()
        mode = source.lstat().st_mode
        if stat.S_ISLNK(mode):
            # npm executable links and the development-only DSH link are not a payload.
            if '/.bin/' not in '/' + relative and relative != 'node_modules/@deepseek-ai':
                raise ValueError(f'Unexpected input symlink: {label}/{relative}')
            self.inputs.append({'source': label, 'path': relative, 'link': os.readlink(source),
                                'decision': 'omit-development-link'})
            return
        if not stat.S_ISREG(mode):
            raise ValueError(f'Not a regular input: {source}')
        data = source.read_bytes()
        item = {'source': label, 'path': relative, 'size': len(data), 'sha256': digest(data)}
        if reason is not None:
            item['decision'] = 'omit'
            item['reason'] = reason
            summary = self.removed.setdefault(reason, {'files': 0, 'bytes': 0})
            summary['files'] += 1
            summary['bytes'] += len(data)
            self.inputs.append(item)
            return
        safe_path(destination)
        if data[:4] in (b'\x7fELF', b'\0asm', b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe',
                        b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe') or data[:2] == b'MZ':
            raise ValueError(f'Unclassified executable/wasm in rawfile payload: {label}/{relative}')
        if destination in self.payload:
            raise ValueError(f'Duplicate payload path: {destination}')
        target = self.files / destination
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        target.chmod(0o644)
        row = {'path': destination, 'size': len(data), 'sha256': item['sha256']}
        self.payload[destination] = row
        item['decision'] = 'include'
        item['destination'] = destination
        self.inputs.append(item)

    def dependencies(self, root: Path, label: str, destination: str, packages, rules, file_rules=None):
        file_rules = file_rules or {}
        allowed = {row['path'] for row in packages}
        for source in records(root / 'node_modules'):
            relative = source.relative_to(root).as_posix()
            reason = package_reason(relative, rules) or file_rules.get(relative)
            if reason is None and package_path(relative) not in allowed:
                reason = '不属于固定 npm 锁的额外包或开发链接；自有助手从仓库单独生成'
            if reason is None and (source.name.endswith(('.map', '.d.ts', '.d.cts', '.d.mts')) or
                                   '/.bin/' in '/' + relative or source.name == '.package-lock.json'):
                reason = '类型声明、源码映射、npm安装缓存和外部命令入口不参与设备运行'
            if reason is None and re.search(r'(?:\.node|\.so(?:\.[0-9]+)*)$', relative, re.I):
                raise ValueError(f'Native-named file was not assigned a composition rule: {label}/{relative}')
            target = '/'.join(part for part in (destination, relative) if part)
            self.add(source, root, label, target, reason)


def checked_lock(prefix: Path, expected: str):
    data = (prefix / 'package-lock.json').read_bytes()
    if digest(data) != expected:
        raise ValueError(f'Locked dependency input differs: {prefix}/package-lock.json')
    lock = json.loads(data)
    packages = []
    for relative, entry in lock['packages'].items():
        if not relative:
            continue
        manifest = prefix / relative / 'package.json'
        if not manifest.exists():
            if entry.get('optional'):
                continue
            raise ValueError(f'Missing locked package: {relative}')
        observed = json.loads(manifest.read_text())
        if observed.get('version') != entry.get('version'):
            raise ValueError(f'Installed package version differs: {relative}')
        packages.append({'path': relative, 'name': observed['name'], 'version': observed['version'],
                         'packageJsonSha256': digest(manifest.read_bytes()),
                         'integrity': entry.get('integrity'), 'license': observed.get('license')})
    return packages


def check_patches(repo: Path, prefix: Path, target_report: Path):
    spec = importlib.util.spec_from_file_location('ohos_rtbuild', repo / 'runtime/lib/rtbuild.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    pins = json.loads((repo / 'runtime/patches/pins.json').read_text())
    names, _ = module.select_dsh_patches(pins, str(repo / 'runtime/patches'), 'ohos')
    _, identity = module.dsh_patch_inputs(pins, str(repo / 'runtime/patches'), names, 'ohos', '0.2.1-rc.4')
    report = json.loads(target_report.read_text())
    if report.get('target') != 'ohos' or report.get('dshVersion') != '0.2.1-rc.4' or report.get('inputSha256') != identity:
        raise ValueError('Requires the current actual --target ohos patch report')
    final = {}
    for name in names:
        final.update(pins['patches'][name]['0.2.1-rc.4'])
    for relative, pin in final.items():
        if digest((prefix / relative).read_bytes()) != pin['after']:
            raise ValueError(f'Patched input is not the final selected OHOS state: {relative}')
    for name in ('ohos-hap-native-libraries.diff', 'zzzzzzzzzzzz-ohos-composition.diff'):
        if name not in names:
            raise ValueError(f'Required OHOS seam is absent: {name}')
    return identity


def assemble(args):
    repo = Path(__file__).resolve().parents[3]
    config_path = Path(__file__).with_name('composition.json')
    config = json.loads(config_path.read_text())
    if config['schema'] != 1 or args.target != config['target']:
        raise ValueError('Unsupported composition target/schema')
    dsh = args.dsh_prefix.resolve(strict=True)
    process = args.process_prefix.resolve(strict=True)
    output = args.out.absolute()
    for source in (repo, dsh, process):
        if output.resolve().is_relative_to(source) or source.is_relative_to(output.resolve()):
            raise ValueError('Output must be separate from repository and input prefixes')
    if output.exists() or output.is_symlink():
        raise ValueError('Output already exists; preserved')
    packages = {'dsh': checked_lock(dsh, config['dshLockSha256']),
                'process': checked_lock(process, config['processLockSha256'])}
    patch_identity = check_patches(repo, dsh, args.target_report)
    regex = args.regex_artifact.resolve(strict=True)
    if digest(regex.read_bytes()) != config['regexSha256']:
        raise ValueError('Private RE2 artifact differs from the locked output')
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.ohos-compose-', dir=output.parent))
    try:
        raw = staging / 'rawfile/dsh-runtime'
        composer = Composer(raw / 'files')
        # Only the npm prefix's node_modules, never a prior staged runtime subtree.
        composer.dependencies(dsh, 'dsh', '', packages['dsh'], config['dshRemovePackages'])
        composer.add(dsh / 'package.json', dsh, 'dsh', 'package.json')
        composer.dependencies(process, 'process-dependencies', 'runtime/ohos/process',
                              packages['process'], config['processRemovePackages'], config['processRemoveFiles'])
        source_runtime = repo / 'runtime/ohos'
        for directory in ('net', 'publication', 'capabilities', 'lifecycle', 'process'):
            for source in sorted((source_runtime / directory).glob('*.mjs')):
                if source.name.startswith(('build-', 'link-')):
                    continue
                composer.add(source, repo, 'repository', source.relative_to(repo).as_posix())
        for name in ('preload.mjs', 'node-version.json'):
            composer.add(source_runtime / name, repo, 'repository', 'runtime/ohos/' + name)
        helper = source_runtime / 'native/hap-loader'
        for name in ('index.cjs', 'package.json'):
            composer.add(helper / name, repo, 'repository', 'node_modules/@dsh-go/ohos-native/' + name)
        composer.add(repo / 'LICENSE', repo, 'repository', 'node_modules/@dsh-go/ohos-native/LICENSE')
        bridge = repo / 'runtime/bridge/dsh-go-bridge'
        for source in records(bridge / 'lib'):
            composer.add(source, repo, 'repository', source.relative_to(repo).as_posix())
        for name in ('package.json', 'cordis.patch.yml'):
            composer.add(bridge / name, repo, 'repository', (bridge / name).relative_to(repo).as_posix())
        for name in ('LICENSE', 'THIRD_PARTY_NOTICES.md'):
            composer.add(repo / name, repo, 'repository', name)
        for source in records(source_runtime / 'licenses/texts'):
            composer.add(source, repo, 'repository', source.relative_to(repo).as_posix())
        composer.add(source_runtime / 'licenses/manifest.json', repo, 'repository', 'runtime/ohos/licenses/input-manifest.json')
        built = staging / 'generated/just-bash'
        command = [sys.executable, '-I', '-B', str(source_runtime / 'process/build-just-bash.py'),
                   '--package', str(process / 'node_modules/just-bash'), '--out', str(built)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=60)
        (staging / 'build.stdout').write_text(result.stdout)
        (staging / 'build.stderr').write_text(result.stderr)
        if result.returncode:
            raise ValueError(f'Private just-bash build refused: {result.stderr}')
        for source in records(built):
            composer.add(source, built, 'generated-just-bash', 'runtime/ohos/process/build/just-bash/' + source.relative_to(built).as_posix())
        composer.add(regex, regex.parent, 'generated-regex', 'runtime/ohos/process/build/re2js-unicode.mjs')
        payload = sorted(composer.payload.values(), key=lambda row: row['path'])
        for row in payload:
            if any(name in {'just-bash', 'sql.js', 'typescript', 'run', 'minimisted'} for name in package_names(row['path'])):
                raise ValueError(f'Excluded interpreter/CLI dependency remained: {row["path"]}')
        identity = digest(json_bytes({'target': 'ohos', 'dsh': config['dshVersion'], 'node': config['nodeVersion'], 'files': payload}))
        manifest = {'schema': 1, 'runtimeVersion': 'ohos-' + identity[:24],
                    'dshVersion': config['dshVersion'], 'nodeVersion': config['nodeVersion'], 'files': payload}
        raw.mkdir(parents=True, exist_ok=True)
        (raw / 'manifest.json').write_bytes(json_bytes(manifest))
        validator = [str(args.node), str(Path(__file__).with_name('validate-manifest.mjs')),
                     str(args.runtime_core), str(raw / 'manifest.json')]
        validated = subprocess.run(validator, capture_output=True, text=True, timeout=30)
        (staging / 'manifest-validation.json').write_bytes(json_bytes({
            'command': validator, 'code': validated.returncode,
            'stdout': validated.stdout, 'stderr': validated.stderr}))
        if validated.returncode:
            raise ValueError(f'Actual P2 manifest consumer rejected the payload: {validated.stderr}')
        (staging / 'input-files.json').write_bytes(json_bytes(composer.inputs))
        (staging / 'payload-files.json').write_bytes(json_bytes(payload))
        (staging / 'input-packages.json').write_bytes(json_bytes(packages))
        archive = staging / 'dsh-runtime-rawfile.zip'
        with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
            for source in sorted(path for path in raw.rglob('*') if path.is_file()):
                info = zipfile.ZipInfo(source.relative_to(staging / 'rawfile').as_posix(), (2026, 1, 1, 0, 0, 0))
                info.external_attr = 0o100644 << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                bundle.writestr(info, source.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
        # Verify the distributed archive's own decompressed file bytes and exact set.
        with zipfile.ZipFile(archive) as bundle:
            expected = {'dsh-runtime/files/' + row['path']: row for row in payload}
            expected['dsh-runtime/manifest.json'] = {'size': len(json_bytes(manifest)), 'sha256': digest(json_bytes(manifest))}
            if set(bundle.namelist()) != set(expected) or len(bundle.namelist()) != len(expected):
                raise ValueError('Archive file set mismatch')
            for name, row in expected.items():
                data = bundle.read(name)
                if len(data) != row['size'] or digest(data) != row['sha256']:
                    raise ValueError(f'Archive content mismatch: {name}')
        report = {'scope': 'OHOS rawfile input archive, not a compiled/signed HAP',
                  'target': 'ohos', 'runtimeVersion': manifest['runtimeVersion'], 'payloadSha256': identity,
                  'compositionSha256': digest(config_path.read_bytes()), 'patchInputSha256': patch_identity,
                  'inputBytes': sum(row.get('size', 0) for row in composer.inputs if not row['source'].startswith('generated-')),
                  'payloadBytes': sum(row['size'] for row in payload), 'payloadFiles': len(payload),
                  'archiveBytes': archive.stat().st_size, 'archiveSha256': digest(archive.read_bytes()),
                  'archiveRoundTrip': True, 'nativeLibraries': config['nativeLibraries'],
                  'nativeLibrariesInRawfile': False, 'ohosTargetAbi': 'NOT_RUN', 'hapInstall': 'NOT_RUN',
                  'removed': composer.removed, 'buildCommand': command,
                  'compileCache': 'HostOptions.cacheDir/node-compile-cache; never part of immutable rawfile'}
        (staging / 'composition-report.json').write_bytes(json_bytes(report))
        os.rename(staging, output)
        return report
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', choices=['ohos'], required=True)
    for name in ('dsh-prefix', 'process-prefix', 'target-report', 'regex-artifact', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--node', type=Path, required=True)
    parser.add_argument('--runtime-core', type=Path, required=True,
                        help='Actual P2 v5 RuntimeCore.ets consumer; type syntax is erased for Linux validation')
    args = parser.parse_args()
    try:
        report = assemble(args)
    except (OSError, ValueError, KeyError) as error:
        print(f'OHOS composition refused: {error}', file=sys.stderr)
        raise SystemExit(2) from None
    print(json.dumps({key: report[key] for key in ('runtimeVersion', 'payloadBytes', 'payloadFiles', 'archiveBytes', 'archiveRoundTrip')}))


if __name__ == '__main__':
    main()
