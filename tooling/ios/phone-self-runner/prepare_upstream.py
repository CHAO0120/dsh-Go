#!/usr/bin/env python3
"""Prepare verified idevice source plus the local RSD-only XCTest entry point."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

HERE = Path(__file__).resolve().parent


def digest(data):
    return hashlib.sha256(data).hexdigest()


def inventory(root):
    paths = sorted(root.rglob('*'))
    if any(path.is_symlink() for path in paths):
        raise ValueError('Prepared upstream contains an unexpected symlink')
    return {path.relative_to(root).as_posix(): digest(path.read_bytes())
            for path in paths if path.is_file() and path != root / '.dsh-source.json'}


def prepare(archive=None):
    pins = json.loads((HERE / 'source-pins.json').read_text())
    patch = HERE / pins['patch']
    identity = {'commit': pins['commit'], 'archiveSha256': pins['archiveSha256'],
                'patchSha256': digest(patch.read_bytes())}
    output = HERE / '.upstream'
    if output.exists() or output.is_symlink():
        if output.is_symlink():
            raise ValueError('Refusing a symlinked upstream output')
        report = json.loads((output / '.dsh-source.json').read_text())
        if report['identity'] != identity or report['files'] != inventory(output):
            raise ValueError('Prepared upstream differs; preserve it and remove the generated .upstream directory explicitly before rebuilding')
        return output
    if archive:
        data = Path(archive).read_bytes()
    else:
        with urllib.request.urlopen(pins['archive'], timeout=120) as response:
            data = response.read(16 * 1024 * 1024 + 1)
    if digest(data) != pins['archiveSha256']:
        raise ValueError('idevice archive SHA256 differs from the fixed source pin')
    prefix = 'idevice-' + pins['commit']
    with tempfile.TemporaryDirectory(prefix='dsh-phone-upstream-') as temporary:
        temporary = Path(temporary)
        packed = temporary / 'source.tar.gz'
        packed.write_bytes(data)
        with tarfile.open(packed, 'r:gz') as source:
            members = source.getmembers()
            if len(members) > 10000 or sum(m.size for m in members) > 64 * 1024 * 1024:
                raise ValueError('Unexpected source archive size')
            for member in members:
                path = PurePosixPath(member.name)
                if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != prefix:
                    raise ValueError('Unsafe source archive path')
                readme_link = member.issym() and member.name == prefix + '/idevice/README.md' and member.linkname == '../README.md'
                if not (member.isdir() or member.isfile() or readme_link):
                    raise ValueError('Unexpected non-regular source archive entry')
            for member in members:
                target = temporary / member.name
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    # Materialize the one pinned README symlink as a regular file;
                    # no archive-controlled filesystem links are ever created.
                    original = source.getmember(prefix + '/README.md') if member.issym() else member
                    with source.extractfile(original) as stream:
                        target.write_bytes(stream.read())
        stage = temporary / prefix
        subprocess.run(['git', 'apply', '--no-index', '--check', str(patch)], cwd=stage, check=True)
        subprocess.run(['git', 'apply', '--no-index', str(patch)], cwd=stage, check=True)
        files = inventory(stage)
        (stage / '.dsh-source.json').write_text(json.dumps({'identity': identity, 'files': files}, indent=2) + '\n')
        shutil.copytree(stage, output)  # Existing output is never overwritten.
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', help='Use a previously downloaded, checksum-verified archive')
    args = parser.parse_args()
    print(prepare(args.archive))
