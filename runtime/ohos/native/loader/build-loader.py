#!/usr/bin/env python3
"""Cross-build pinned upstream require-builtin sources; target execution is separate."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


HERE = Path(__file__).resolve().parent


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify_files(root, files):
    for name, expected in files.items():
        path = root / name
        if not path.is_file() or path.is_symlink() or digest(path) != expected:
            raise ValueError(f'Pinned input mismatch: {path}')


def exported_symbols(text):
    result = set()
    for line in text.splitlines():
        fields = line.split()
        if len(fields) < 8 or not fields[0].rstrip(':').isdigit():
            continue
        if fields[4] in ('GLOBAL', 'WEAK') and fields[5] in ('DEFAULT', 'PROTECTED') and fields[6] != 'UND':
            result.add(fields[7].split('@', 1)[0])
    return result


def imported_symbols(text):
    result = set()
    for line in text.splitlines():
        fields = line.split()
        if len(fields) >= 8 and fields[0].rstrip(':').isdigit() and fields[6] == 'UND':
            result.add(fields[7].split('@', 1)[0])
    return result


def require_symbols(exports, names):
    missing = sorted(set(names) - exports)
    if missing:
        raise ValueError('libnode does not export required symbols: ' + ', '.join(missing))


def inspect_elf(readelf, path):
    structure = subprocess.check_output([str(readelf), '-h', '-l', '-d', str(path)], text=True)
    symbols = subprocess.check_output([str(readelf), '--dyn-syms', '--wide', str(path)], text=True)
    if 'AArch64' not in structure or 'DYN (Shared object file)' not in structure or 'INTERP' in structure:
        raise ValueError(f'Expected AArch64 ET_DYN without PT_INTERP: {path}')
    return structure, symbols


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk-native', required=True, type=Path)
    parser.add_argument('--source', required=True, type=Path,
                        help='Extracted upstream release commit listed in source-pins.json')
    parser.add_argument('--node-headers', required=True, type=Path,
                        help='Official Node 24.22.1 include/node; never Ark NAPI headers')
    parser.add_argument('--node-addon-api', required=True, type=Path,
                        help='Pinned existing O4 dependency node-addon-api 8.9.2')
    parser.add_argument('--libnode', required=True, type=Path,
                        help='O7b arm64 OHOS libnode.so; its exports are checked before compiling')
    parser.add_argument('--libnode-build-json', required=True, type=Path,
                        help='Matching O7b build.json, including source and artifact SHA256')
    parser.add_argument('--output', required=True, type=Path, help='Fresh artifact directory')
    args = parser.parse_args()
    sdk, source, headers, api, libnode, node_report_path, output = (path.resolve() for path in
        (args.sdk_native, args.source, args.node_headers, args.node_addon_api, args.libnode,
         args.libnode_build_json, args.output))
    pins = json.loads((HERE / 'source-pins.json').read_text())
    compiler, readelf = sdk / 'llvm/bin/clang++', sdk / 'llvm/bin/llvm-readelf'
    required = [compiler, readelf, sdk / 'sysroot/usr/include/dlfcn.h',
                sdk / 'sysroot/usr/include/sys/mman.h', sdk / 'oh-uni-package.json',
                headers / 'node_api.h', headers / 'node_version.h', libnode, node_report_path]
    for path in required:
        if not path.is_file():
            parser.error(f'Missing input: {path}; no target build was performed')
    if output.exists():
        parser.error('--output must be fresh; retain incomplete outputs for diagnosis')
    try:
        verify_files(source, pins['upstream']['files'])
        verify_files(api, pins['nodeAddonApi']['files'])
    except ValueError as error:
        parser.error(str(error))
    version = (headers / 'node_version.h').read_text()
    for name, value in [('MAJOR', 24), ('MINOR', 22), ('PATCH', 1)]:
        if f'#define NODE_{name}_VERSION {value}\n' not in version:
            parser.error('Node headers must be official 24.22.1')
    metadata = json.loads((api / 'package.json').read_text())
    if (metadata.get('name'), metadata.get('version')) != ('node-addon-api', '8.9.2'):
        parser.error('node-addon-api must match pinned 8.9.2 build headers')
    node_report = json.loads(node_report_path.read_text())
    if (node_report.get('nodeSourceSha256') != '4f5379796280cdaeb0c2f358fd04b6a16cc4fb7dfa83b5a8c91a9d963b435231'
            or node_report.get('artifacts', {}).get('libnode.so', {}).get('sha256') != digest(libnode)):
        parser.error('libnode/build.json must bind the pinned Node 24.22.1 source and exact library bytes')
    for option in ['--dest-os=openharmony', '--dest-cpu=arm64', '--shared']:
        if option not in node_report.get('configure', []):
            parser.error(f'libnode build report lacks {option}')

    target = [str(compiler), '--target=aarch64-linux-ohos', f'--sysroot={sdk / "sysroot"}']
    macros = subprocess.check_output(target + ['-dM', '-E', '-x', 'c++', '-'], input='', text=True)
    for macro in ['__aarch64__', '__linux__']:
        if not re.search(r'^#define ' + re.escape(macro) + r'\b', macros, re.M):
            parser.error(f'SDK does not select upstream arm64 POSIX branch: {macro} missing')
    try:
        node_elf, node_symbols = inspect_elf(readelf, libnode)
        if re.search(r'SONAME.*\[libnode\.so\]', node_elf) is None:
            raise ValueError('Requires O7b SONAME libnode.so')
        node_exports = exported_symbols(node_symbols)
        require_symbols(node_exports, pins['requiredNode24Symbols'] + ['dsh_napi_get_node_version', 'dsh_napi_typeof'])
    except ValueError as error:
        parser.error(str(error))

    native = source / 'packages/native'
    binding = json.loads((native / 'binding.gyp').read_text())['targets'][0]
    source_names = list(binding['sources'])
    # The original default branch is napi; nodeabi is not used or relabelled.
    source_names += binding['conditions'][0][2]['sources']
    sources = [native / name for name in source_names]
    for path in sources:
        if str(path.relative_to(source)) not in pins['upstream']['files']:
            parser.error(f'Unpinned native compilation unit: {path}')

    output.mkdir(parents=True)
    report = {
        'status': 'BUILD_STARTED', 'base': 'c0949d6', 'target': 'aarch64-linux-ohos',
        'upstream': {key: value for key, value in pins['upstream'].items() if key != 'files'},
        'nodeVersion': '24.22.1', 'nodeApiVersion': 9, 'nodeAddonApi': pins['nodeAddonApi'],
        'nodeLibrarySHA256': digest(libnode), 'nodeLibraryELF': node_elf,
        'nodeBuildReportSHA256': digest(node_report_path),
        'requiredDynamicSymbols': pins['requiredNode24Symbols'],
        'nativeSourceSHA256': {name: digest(source / name) for name in pins['upstream']['files']},
        'nodeHeaderSHA256': {name: digest(headers / name) for name in
                            ['node_api.h', 'node_api_types.h', 'js_native_api.h', 'js_native_api_types.h', 'node_version.h']},
        'sdkManifest': json.loads((sdk / 'oh-uni-package.json').read_text()),
        'sdkManifestSHA256': digest(sdk / 'oh-uni-package.json'),
        'compilerSHA256': digest(compiler),
        'compilerVersion': subprocess.check_output([str(compiler), '--version'], text=True),
        'scope': 'ELF build only; HAP symbol ownership, ARM64 probe and device execution NOT_RUN',
    }
    (output / 'libnode-dynamic-symbols.txt').write_text(node_symbols)
    with tempfile.TemporaryDirectory(prefix='.loader-build-', dir=output) as temporary:
        binary = Path(temporary) / 'require_builtin.node'
        command = target + ['-std=c++17', '-O2', '-g0', '-fPIC', '-shared', '-pthread',
            '-include', str(HERE.parents[1] / 'node/napi-rename.h'),
            '-stdlib=libc++', '-fvisibility=hidden', '-fno-exceptions',
            '-DNAPI_VERSION=9', '-DNARB_BACKEND=1', '-DNARB_PRODUCT=1',
            '-DNODE_ADDON_API_DISABLE_CPP_EXCEPTIONS', '-DNODE_GYP_MODULE_NAME=require_builtin',
            f'-ffile-prefix-map={source}=node-addon-require-builtin-0.1.9',
            '-I', str(headers), '-I', str(api), *map(str, sources),
            '-L', str(libnode.parent), '-Wl,-rpath-link,' + str(libnode.parent), '-lnode', '-ldl',
            '-Wl,-z,defs', '-Wl,-soname,require_builtin.node', '-o', str(binary)]
        report['command'] = command
        (output / 'build.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        with (output / 'compile.log').open('w') as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True,
                           env={**os.environ, 'LC_ALL': 'C', 'TZ': 'UTC', 'SOURCE_DATE_EPOCH': '0'})
        addon_elf, addon_symbols = inspect_elf(readelf, binary)
        if re.search(r'NEEDED.*\[libnode\.so\]', addon_elf) is None:
            raise RuntimeError('Addon must explicitly depend on libnode.so')
        require_symbols(exported_symbols(addon_symbols), ['napi_register_module_v1'])
        addon_imports = imported_symbols(addon_symbols)
        plain = sorted(name for name in addon_imports if name.startswith(('napi_', 'node_api_')))
        if plain:
            raise RuntimeError(f'Addon imports plain N-API names, which would bind to Ark: {plain}')
        require_symbols(node_exports, sorted(name for name in addon_imports if name.startswith('dsh_')))
        (output / 'addon-dynamic-symbols.txt').write_text(addon_symbols)
        package = output / 'node_modules/node-addon-require-builtin-openharmony-arm64'
        (package / 'prebuilt').mkdir(parents=True)
        binary_name = 'prebuilt/openharmony-arm64-napi-v9.node'
        shutil.copyfile(binary, package / binary_name)
        (package / 'package.json').write_text(json.dumps({
            'name': 'node-addon-require-builtin-openharmony-arm64', 'version': '0.1.9',
            'main': 'index.js', 'license': 'MIT', 'os': ['openharmony'], 'cpu': ['arm64'],
            'dependencies': {'node-addon-native-custom-loader': '0.1.9'},
        }, indent=2) + '\n')
        (package / 'index.js').write_text("'use strict';\n\nconst { loadPrebuild } = require('node-addon-native-custom-loader');\n\nmodule.exports = loadPrebuild(__dirname);\n")
        (package / 'prebuilds.json').write_text(json.dumps({
            'platform': 'openharmony-arm64', 'binaries': [{'backend': 'napi', 'abi': 'napi-v9',
                'binaryTag': 'napi-v9', 'node': '24.22.1', 'path': binary_name}],
        }, indent=2) + '\n')
        shutil.copyfile(source / 'LICENSE', package / 'LICENSE')
        shutil.copyfile(api / 'LICENSE.md', package / 'NODE-ADDON-API-LICENSE.md')
        report.update({'status': 'BUILT_DEVICE_NOT_RUN', 'addonELF': addon_elf,
            'nodeApiImports': napi_imports,
            'artifacts': {str(path.relative_to(output)): {'bytes': path.stat().st_size, 'sha256': digest(path)}
                          for path in sorted(package.rglob('*')) if path.is_file()}})
        (output / 'build.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'output': str(output), 'status': report['status']}, ensure_ascii=False))


if __name__ == '__main__':
    main()
