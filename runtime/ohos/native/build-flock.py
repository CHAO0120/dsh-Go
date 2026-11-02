#!/usr/bin/env python3
"""Cross-build the locked upstream flock Node-API addon; no device claim."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


SOURCE_SHA256 = 'c1aa773c7a62b03ce3973156b928f41773fef9407afd79d71b2f625b5616421f'
NAPI_RENAME = Path(__file__).resolve().parents[1] / 'node/napi-rename.h'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk-native', required=True, type=Path,
                        help='Extracted public SDK native directory (llvm/ and sysroot/)')
    parser.add_argument('--package', required=True, type=Path,
                        help='Locked @deepseek-ai/node-addon-system 0.1.2 directory')
    parser.add_argument('--node-headers', required=True, type=Path,
                        help='Node 24.22.1 include/node directory')
    parser.add_argument('--output', required=True, type=Path,
                        help='Output directory; system.node and build.json must not exist')
    args = parser.parse_args()
    sdk, package, headers, output = (p.resolve() for p in
        (args.sdk_native, args.package, args.node_headers, args.output))
    source = package / 'src/flock.c'
    metadata = json.loads((package / 'package.json').read_text())
    if (metadata.get('name'), metadata.get('version')) != ('@deepseek-ai/node-addon-system', '0.1.2'):
        parser.error('Requires the locked @deepseek-ai/node-addon-system 0.1.2')
    if digest(source) != SOURCE_SHA256:
        parser.error('src/flock.c SHA256 differs from the locked package')
    version = (headers / 'node_version.h').read_text()
    for name, value in [('MAJOR', 24), ('MINOR', 22), ('PATCH', 1)]:
        if f'#define NODE_{name}_VERSION {value}\n' not in version:
            parser.error('Requires official Node 24.22.1 headers')
    compiler, readelf = sdk / 'llvm/bin/clang', sdk / 'llvm/bin/llvm-readelf'
    sdk_manifest = sdk / 'oh-uni-package.json'
    for path in [compiler, readelf, sdk / 'sysroot/usr/include/sys/file.h', sdk_manifest,
                 headers / 'node_api.h']:
        if not path.is_file():
            parser.error(f'Missing required SDK/header input: {path}')
    output.mkdir(parents=True, exist_ok=True)
    if any((output / name).exists() for name in ['system.node', 'build.json']):
        parser.error('Output already exists; choose a fresh directory')

    with tempfile.TemporaryDirectory(prefix='flock-', dir=output) as temporary:
        binary = Path(temporary) / 'system.node'
        command = [str(compiler), '--target=aarch64-linux-ohos',
                   f'--sysroot={sdk / "sysroot"}', '-std=c11', '-O2', '-g0',
                   '-fPIC', '-fvisibility=hidden', '-shared', '-DNAPI_VERSION=8',
                   f'-ffile-prefix-map={package}=node-addon-system-0.1.2',
                   '-include', str(NAPI_RENAME), '-I', str(headers), str(source), '-Wl,-soname,system.node',
                   '-o', str(binary)]
        subprocess.run(command, check=True)
        elf = subprocess.check_output([str(readelf), '-h', '-l', '-d', str(binary)], text=True)
        if 'AArch64' not in elf or 'DYN (Shared object file)' not in elf or 'INTERP' in elf:
            raise RuntimeError('Output is not an AArch64 shared object without PT_INTERP')
        imports = subprocess.check_output([str(sdk / 'llvm/bin/llvm-nm'), '-D', '--undefined-only', str(binary)], text=True)
        if re.search(r'\b(napi|node_api)_', imports):
            raise RuntimeError('Addon imports a plain N-API name, which would bind to Ark instead of libnode')
        manifest = {
            'target': 'aarch64-linux-ohos', 'scope': 'cross-compiled; device load NOT_RUN',
            'package': metadata['name'], 'version': metadata['version'],
            'license': metadata['license'], 'sourceSha256': digest(source),
            'nodeVersion': '24.22.1', 'nodeApiVersion': 8,
            'sdkManifest': json.loads(sdk_manifest.read_text()),
            'sdkManifestSha256': digest(sdk_manifest), 'compilerSha256': digest(compiler),
            'compilerVersion': subprocess.check_output([str(compiler), '--version'], text=True),
            'command': command, 'elf': elf, 'bytes': binary.stat().st_size,
            'sha256': digest(binary),
        }
        report = Path(temporary) / 'build.json'
        report.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
        os.replace(binary, output / 'system.node')
        os.replace(report, output / 'build.json')
    print(json.dumps({'output': str(output / 'system.node'), 'sha256': manifest['sha256'],
                      'bytes': manifest['bytes']}, ensure_ascii=False))


if __name__ == '__main__':
    main()
