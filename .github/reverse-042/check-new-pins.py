#!/usr/bin/env python3
"""Read-only request042 pin check: exact 3a91 plus only 2359 entry.

Usage: python3 check-new-pins.py BASE_PINS CANDIDATE_PINS
Reads expected-new-pins.json beside this script; never writes either input.
"""
import copy
import hashlib
import json
import sys
from pathlib import Path


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f'duplicate JSON key: {key!r}')
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError(f'non-JSON numeric constant: {value}')


def load(path):
    return json.loads(Path(path).read_text(encoding='utf-8'),
                      object_pairs_hook=unique_object,
                      parse_constant=reject_constant)


def canonical(value):
    # JSON text comparison, not Python equality (True == 1 must not pass).
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(',', ':'), allow_nan=False).encode('utf-8')


def main():
    if len(sys.argv) != 3:
        raise ValueError('usage: python3 check-new-pins.py BASE_PINS CANDIDATE_PINS')
    spec = load(Path(__file__).with_name('expected-new-pins.json'))
    before, after = load(sys.argv[1]), load(sys.argv[2])
    if not isinstance(before, dict) or not isinstance(before.get('patches'), dict):
        raise ValueError('base pins must contain an object named patches')
    additions = spec['new_patches']
    for name in additions:
        if name in before['patches']:
            raise ValueError(f'base already contains new entry: {name}')
    if hashlib.sha256(canonical(before)).hexdigest() != spec['base_pins_canonical_sha256']:
        raise ValueError('base pins are not the exact 3a91 JSON content')
    expected = copy.deepcopy(before)
    expected['patches'].update(additions)
    if canonical(after) != canonical(expected):
        raise ValueError('candidate differs: old JSON fields changed, extra entries, '
                         'or new version/target/before/after mismatch')
    print('PASS: exact 3a91 base; all old JSON fields unchanged; '
          'only the exact 2359 pin entry added')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise SystemExit(f'FAIL: {error}')
