#!/usr/bin/env python3
"""Build the iOS runtime from verified shared composition, without editing its inputs."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile

HELPER = 'runtime/ohos/process/build/just-bash/chunks/chunk-GN6CQ3J4.js'
PROVENANCE = 'runtime/ohos/process/build/just-bash/PROVENANCE.json'
PIN = 'b87766dab2a645753e635c4e0d728443c601b737fb7feb034244d2fa242185ec'
BEFORE = 'let e=y.encode(t),o="";for(let r=0;r<e.length;r++)o+=String.fromCharCode(e[r]);return o'
# Keep TextEncoder (including surrogate replacement), x/f validation and the
# output bytes unchanged; only bound per-byte cons-string amplification.
AFTER = 'let e=y.encode(t),o=[];for(let r=0;r<e.length;r+=8192)o.push(String.fromCharCode(...e.subarray(r,r+8192)));return o.join("")'


def specialize(expanded, out, composer):
    expanded = expanded.resolve(strict=True)
    output = out.resolve()
    if output.is_relative_to(expanded) or expanded.is_relative_to(output):
        raise ValueError('iOS output must be separate from the shared expanded input')
    if out.exists() or out.is_symlink():
        raise ValueError('iOS output already exists; preserved')
    original = (expanded / 'files' / HELPER).read_bytes()
    if hashlib.sha256(original).hexdigest() != PIN or original.decode().count(BEFORE) != 1:
        raise ValueError('iOS byte encoder differs from pinned just-bash 3.6.0 input')
    manifest = json.loads((expanded / 'manifest.json').read_bytes())
    entries = {row['path']: row for row in manifest['files']}
    for name in (HELPER, PROVENANCE):
        data = (expanded / 'files' / name).read_bytes()
        if entries[name]['sha256'] != composer.digest(data) or entries[name]['size'] != len(data):
            raise ValueError('iOS specialization input differs from shared manifest: ' + name)
    provenance = json.loads((expanded / 'files' / PROVENANCE).read_bytes())
    module = 'chunks/chunk-GN6CQ3J4.js'
    if provenance['upstream']['version'] != '3.6.0' or provenance['modules'][module] != PIN:
        raise ValueError('Unexpected just-bash provenance')
    changed = original.decode().replace(BEFORE, AFTER).encode()
    provenance['modules'][module] = composer.digest(changed)
    provenance['iosSpecialization'] = {
        'reason': 'Bound UTF-8 byte-string concatenation overhead with 8192-byte chunks',
        'beforeSha256': PIN, 'afterSha256': composer.digest(changed),
        'generatorSha256': composer.digest(Path(__file__).read_bytes()),
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    # Atomic publication of a separate generated tree/archive. Shared composition
    # and npm prefixes remain byte-for-byte unchanged, including failure paths.
    with tempfile.TemporaryDirectory(prefix='.ios-runtime-', dir=out.parent) as temp:
        stage = Path(temp) / 'result'
        tree = stage / 'expanded/dsh-runtime'
        shutil.copytree(expanded, tree)
        for name, data in ((HELPER, changed), (PROVENANCE, composer.json_bytes(provenance))):
            (tree / 'files' / name).write_bytes(data)
            entries[name]['sha256'] = composer.digest(data)
            entries[name]['size'] = len(data)
        identity = composer.digest(composer.json_bytes({
            'target': 'ios', 'dsh': manifest['dshVersion'],
            'node': manifest['nodeVersion'], 'files': manifest['files'],
        }))
        manifest['runtimeVersion'] = 'ios-' + identity[:24]
        (tree / 'manifest.json').write_bytes(composer.json_bytes(manifest))
        # Reuse the existing ZIP32 constraints and full member/hash round trip.
        archive = composer.write_runtime_archive(tree, stage / 'runtime.zip')
        (stage / 'ios-report.json').write_bytes(composer.json_bytes({
            'schema': 1, 'runtimeVersion': manifest['runtimeVersion'],
            'inputManifestSha256': composer.digest((expanded / 'manifest.json').read_bytes()),
            'specialization': provenance['iosSpecialization'], 'archive': archive,
        }))
        stage.rename(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--expanded', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    spec = importlib.util.spec_from_file_location('shared_composition', root / 'runtime/ohos/package/compose-runtime.py')
    composer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(composer)
    specialize(args.expanded, args.out, composer)


if __name__ == '__main__':
    main()
