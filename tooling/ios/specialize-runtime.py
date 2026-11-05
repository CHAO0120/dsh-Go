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

# The shared composition refuses every image, for want of a decoder on HarmonyOS. iOS has one,
# so the attachment store loads runtime/ios/image/ios-sharp.cjs in place of sharp. ImageIO can't
# write WebP, so alpha stays in PNG. Each has to match exactly once, or the build stops.
ATTACHMENTS = 'node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js'
IMAGE_CODEC = 'node_modules/@deepseek-ai/dsh-attachment-local/lib/ios-sharp.cjs'
RG = 'runtime/ohos/process/rg.mjs'
RG_PREFIX = 'rg: 鸿蒙本机尚不支持'.encode()
ATTACHMENT_EDITS = (
    ('const loadSharp = createLazyRequire("sharp", import.meta.url);',
     'const loadSharp = createLazyRequire("./ios-sharp.cjs", import.meta.url);'),
    ('\tif (process.platform === "openharmony") throw new AttachmentError("鸿蒙本机尚无可用的图像解码/重编码库；请连接电脑处理图像。普通文件仍可上传或保存。", "OHOS_IMAGE_CODEC_UNAVAILABLE");\n',
     ''),
    ('const mediaType = hasAlpha ? "image/webp" : "image/jpeg";',
     'const mediaType = hasAlpha ? "image/png" : "image/jpeg";'),
    ('(mediaType === "image/webp" ? pipeline.webp({\n\t\tquality,\n\t\teffort: 0\n\t}) : pipeline.jpeg({ quality }))',
     '(mediaType === "image/png" ? pipeline.png() : pipeline.jpeg({ quality }))'),
    # PNG has no quality ladder: repeat encodes would produce the same pixels and bytes.
    ('return IMAGE_ENCODING_QUALITIES.map((quality) => (() => encode(prepared.clone(), mediaType, quality)));',
     'return (hasAlpha ? IMAGE_ENCODING_QUALITIES.slice(0, 1) : IMAGE_ENCODING_QUALITIES).map((quality) => (() => encode(prepared.clone(), mediaType, quality)));'),
)


def attachments_for_ios(original):
    text = original.decode()
    for before, after in ATTACHMENT_EDITS:
        if text.count(before) != 1:
            raise ValueError('iOS attachment edit differs from the composed store: ' + before[:60])
        text = text.replace(before, after)
    return text.encode()


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
    attachments = attachments_for_ios((expanded / 'files' / ATTACHMENTS).read_bytes())
    rg = (expanded / 'files' / RG).read_bytes()
    if rg.count(RG_PREFIX) != 1:
        raise ValueError('iOS rg diagnostic prefix differs from the composed input')
    codec = (Path(__file__).resolve().parents[2] / 'runtime/ios/image/ios-sharp.cjs').read_bytes()
    for name in (HELPER, PROVENANCE, ATTACHMENTS, RG):
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
        if IMAGE_CODEC in entries:
            raise ValueError('The shared composition already has an iOS image codec')
        row = {'path': IMAGE_CODEC, 'size': len(codec), 'sha256': composer.digest(codec)}
        entries[IMAGE_CODEC] = row
        manifest['files'] = sorted([*manifest['files'], row], key=lambda item: item['path'])
        (tree / 'files' / IMAGE_CODEC).write_bytes(codec)
        for name, data in ((HELPER, changed), (PROVENANCE, composer.json_bytes(provenance)), (ATTACHMENTS, attachments),
                           (RG, rg.replace(RG_PREFIX, 'rg: iOS 本机尚不支持'.encode()))):
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
