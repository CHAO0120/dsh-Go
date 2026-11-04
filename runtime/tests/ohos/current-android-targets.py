#!/usr/bin/env python3
"""Compare current Android outputs; each target starts from an independent prefix.

This calls the real patcher and compares every installed path, mode and byte.
The old target-patches-live helpers supply only filesystem comparison, not its
historical afb baseline or Android-to-OH transition assumptions.
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--baseline', type=Path, required=True)
    ap.add_argument('--candidate', type=Path, required=True)
    ap.add_argument('--pristine-prefix', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()
    base, candidate, pristine, out = [x.resolve() for x in
                                    (a.baseline, a.candidate, a.pristine_prefix, a.out)]
    out.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location('target_tree_helpers',
        candidate / 'runtime/tests/ohos/target-patches-live.py')
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    report = {'schema': 1, 'startedUTC': utc(), 'status': 'RUNNING', 'commands': [],
              'scope': 'Installed Linux prefix Android bytes/modes/links and target selection; no APK or device.',
              'baseline': str(base), 'candidate': str(candidate), 'pristine': str(pristine)}

    def save(name, value):
        (out / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')

    def run(label, root, prefix, target, expected=0):
        argv = [sys.executable, '-I', '-B', str(root / 'runtime/lib/rtbuild.py'),
                'patch-dsh', '--prefix', str(prefix), '--patches', str(root / 'runtime/patches'),
                '--dsh-version', '0.2.1-rc.4', '--target', target,
                '--out', str(out / (label + '-patches.json')),
                '--target-report', str(out / (label + '-target.json'))]
        row = {'label': label, 'argv': argv, 'cwd': str(root), 'startedUTC': utc(), 'expected': expected}
        with (out / (label + '.stdout')).open('xb') as stdout, (out / (label + '.stderr')).open('xb') as stderr:
            result = subprocess.run(argv, cwd=root, stdout=stdout, stderr=stderr, timeout=180)
        row.update(exitCode=result.returncode, endedUTC=utc())
        report['commands'].append(row)
        save('report.json', report)
        assert (result.returncode == 0 if expected == 0 else result.returncode != 0), row

    try:
        for name in ('package.json', 'package-lock.json'):
            assert (pristine / name).read_bytes() == (candidate / 'runtime/locks/dsh-0.2.1-rc.4' / name).read_bytes()
            assert (pristine / name).read_bytes() == (base / 'runtime/locks/dsh-0.2.1-rc.4' / name).read_bytes()
        pins = [json.loads((root / 'runtime/patches/pins.json').read_text()) for root in (base, candidate)]
        selected = pins[0]['targetSets']['android']
        assert pins[1]['targetSets']['android'] == selected
        assert {n: pins[0]['patches'][n] for n in selected} == {n: pins[1]['patches'][n] for n in selected}
        report['selectedAndroid'] = selected
        # Actual recipe output includes shared companion inputs, not only pin labels.
        for label, root in [('base', base), ('candidate', candidate)]:
            argv = [sys.executable, '-I', '-B', str(root / 'runtime/lib/android_recipe.py'),
                    '--dsh-version', '0.2.1-rc.4']
            proc = subprocess.run(argv, capture_output=True, cwd=root, timeout=60)
            (out / (label + '-recipe.stdout')).write_bytes(proc.stdout)
            (out / (label + '-recipe.stderr')).write_bytes(proc.stderr)
            report['commands'].append({'label': label + '-recipe', 'argv': argv, 'exitCode': proc.returncode})
            proc.check_returncode()
        assert (out / 'base-recipe.stdout').read_bytes() == (out / 'candidate-recipe.stdout').read_bytes()
        report['recipeSha256'] = sha(out / 'base-recipe.stdout')
        initial = helper.tree_manifest(pristine)
        save('pristine-before.json', initial)
        trees = {}
        for label, root, target in [('base', base, 'android'), ('candidate', candidate, 'android'),
                                    ('ohos', candidate, 'ohos')]:
            prefix = out / (label + '-prefix')
            shutil.copytree(pristine, prefix, symlinks=True, copy_function=shutil.copy2)
            assert helper.tree_manifest(prefix) == initial
            run(label, root, prefix, target)
            trees[label] = helper.tree_manifest(prefix)
            save(label + '-tree.json', trees[label])
            run(label + '-again', root, prefix, target)
            assert helper.tree_manifest(prefix) == trees[label], 'idempotence changed bytes'
        changes = helper.compare_trees(out / 'base-prefix', out / 'candidate-prefix', trees['base'], trees['candidate'])
        report['androidDifferences'] = changes
        assert not changes, changes
        for label, wrong in [('candidate', 'ohos'), ('ohos', 'android')]:
            run(label + '-wrong-target', candidate, out / (label + '-prefix'), wrong, expected=1)
            assert helper.tree_manifest(out / (label + '-prefix')) == trees[label]
            assert not (out / (label + '-wrong-target-target.json')).exists()
        assert helper.tree_manifest(pristine) == initial
        report.update(status='PASS', endedUTC=utc(), actualAndroidEntries=len(trees['base']),
                      actualOhosEntries=len(trees['ohos']), pristineUnchanged=True,
                      wrongTargetRejectedWithoutWrites=True, idempotent=True)
        save('report.json', report)
        print(json.dumps({k: report[k] for k in ('status', 'actualAndroidEntries', 'actualOhosEntries', 'recipeSha256')}))
    except BaseException as error:
        report.update(status='FAIL', endedUTC=utc(), error=repr(error))
        save('report.json', report)
        raise


if __name__ == '__main__':
    main()
