#!/usr/bin/env python3
"""Export locked Cargo package identities without build-machine paths."""
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent


def inventory(metadata):
    pin = json.loads((HERE / 'source-pins.json').read_text())
    result = []
    for package in metadata['packages']:
        source = package.get('source')
        if source is None:
            if package['name'] == 'idevice':
                source = pin['repository'] + '@' + pin['commit'] + ' + local RSD XCTest patch'
            elif package['name'] == 'dsh-phone-self-runner':
                source = 'dsh-Go repository: tooling/ios/phone-self-runner'
            else:
                raise ValueError('Unexpected local path dependency')
        if not (source.startswith('registry+') or source.startswith('git+') or source.startswith('https://github.com/jkcoxson/idevice@') or source.startswith('dsh-Go repository:')):
            raise ValueError('Unexpected dependency source')
        result.append({'name': package['name'], 'version': package['version'],
                       'license': package.get('license'), 'source': source})
    result.sort(key=lambda value: (value['name'], value['version']))
    return {'schema': 1, 'scope': 'Locked Cargo package inventory; license texts and distribution obligations still require release review.',
            'packages': result}


if __name__ == '__main__':
    metadata = json.loads(Path(sys.argv[1]).read_text())
    Path(sys.argv[2]).write_text(json.dumps(inventory(metadata), indent=2, ensure_ascii=True) + '\n')
