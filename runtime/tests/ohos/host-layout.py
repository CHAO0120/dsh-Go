#!/usr/bin/env python3
"""Build HostCore's profile driver and replay its exact layout in actual DSH.

The prefix and dependency cache are read-only inputs. Output owns a full private
runtime tree. Local HTTP/WS is used by the existing strict five-tool test peer.
This is Linux host evidence, not an Ark/SDK/HAP run or a startup benchmark.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def inventory(root):
    result = {}
    for path in sorted(root.rglob('*')):
        name = path.relative_to(root).as_posix()
        if path.is_symlink():
            result[name] = {'link': os.readlink(path)}
        elif path.is_file():
            result[name] = {'bytes': path.stat().st_size, 'sha256': sha(path)}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['prefix', 'process-dependencies', 'esbuild-prefix', 'node', 'native-library-dir', 'publication-fixture', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    for name in vars(args):
        setattr(args, name, getattr(args, name).resolve())
    out = args.out
    out.mkdir(parents=True, exist_ok=False)
    base_env = {key: os.environ[key] for key in ['PATH', 'LANG', 'LC_ALL'] if key in os.environ}
    base_env['LANG'] = 'C.UTF-8'
    commands = []

    def run(name, command, env=None, cwd=None, timeout=150):
        command = [str(value) for value in command]
        process = subprocess.run(command, env=env or base_env, cwd=cwd or ROOT,
                                 capture_output=True, text=True, timeout=timeout)
        (out / (name + '.stdout.log')).write_text(process.stdout)
        (out / (name + '.stderr.log')).write_text(process.stderr)
        commands.append({'name': name, 'command': command, 'cwd': str(cwd or ROOT),
                         'exitCode': process.returncode})
        write_json(out / 'commands.json', commands)
        print(name, process.returncode, flush=True)
        process.check_returncode()
        return process

    source_process = ROOT / 'runtime/ohos/process'
    assert sha(source_process / 'package-lock.json') == sha(args.process_dependencies.parent / 'package-lock.json')
    assert sha(source_process / 'package.json') == sha(args.process_dependencies.parent / 'package.json')
    write_json(out / 'prefix-input.json', inventory(args.prefix))
    write_json(out / 'process-dependencies-input.json', inventory(args.process_dependencies))
    runtime = out / 'runtime'
    shutil.copytree(args.prefix, runtime, symlinks=True)
    runtime_ohos = runtime / 'runtime/ohos'
    shutil.copytree(ROOT / 'runtime/ohos', runtime_ohos,
                    ignore=shutil.ignore_patterns('node', 'node_modules', 'build', '__pycache__'))
    process = runtime_ohos / 'process'
    shutil.copytree(args.process_dependencies, process / 'node_modules', symlinks=True)
    inherited = process / 'node_modules/@deepseek-ai'
    if inherited.is_symlink():
        inherited.unlink()
    elif inherited.exists():
        raise AssertionError('Dependency cache unexpectedly owns concrete DSH packages')
    run('link-dsh', [args.node, process / 'link-dsh.mjs', runtime])
    run('build-just-bash', [sys.executable, process / 'build-just-bash.py'])
    run('build-re2js', [args.node, process / 'build-rg-regex.mjs', args.esbuild_prefix])

    guest = out / '中文应用目录/runtime/rootfs'
    dsh = guest / 'root/.dsh'
    agents = guest / 'root/.agents'
    workspace = guest / 'root/workspace'
    cache = out / 'cache'
    for directory in [dsh, agents, workspace, cache]:
        directory.mkdir(parents=True)
    for directory, name in [(dsh, 'dsh-home-proof'), (agents, 'agents-home-proof')]:
        skill = directory / 'skills' / name / 'SKILL.md'
        skill.parent.mkdir(parents=True)
        skill.write_text('---\nname: ' + name + '\ndescription: Host layout fixture\n---\n中文技能\n')
    (dsh / 'AGENTS.md').write_text('DSH_GLOBAL_FIXTURE_中文\n')
    (agents / 'AGENTS.md').write_text('AGENTS_GLOBAL_FIXTURE_中文\n')
    core = ROOT / 'app/ohos/entry/src/main/cpp'
    driver = out / 'host-profile'
    run('compile-driver', [os.environ.get('CXX', 'c++'), '-std=c++17', '-Wall', '-Wextra', '-Werror',
        '-I', core, core / 'host_core.cpp', HERE / 'host-profile.cc', '-pthread', '-o', driver])
    argv_path = out / 'argv.json'
    run('generate-host', [driver, runtime, guest, dsh, workspace, cache, args.native_library_dir, argv_path])
    argv = json.loads(argv_path.read_text())
    captured = json.loads(Path(str(argv_path) + '.env.json').read_text())
    expected = {'HOME': str(guest / 'root'), 'DSH_HOME': str(dsh), 'DSH_AGENTS_HOME': str(agents),
        'TMPDIR': str(cache / 'ohos-process'), 'NODE_COMPILE_CACHE': str(cache / 'node-compile-cache'),
        'NARB_DISABLE_NATIVE_CACHE': '1', 'DSH_GO_OHOS_NATIVE_LIBRARY_DIR': str(args.native_library_dir),
        'DSH_PERMISSION_MODE': 'workspace-write'}
    assert captured == expected
    assert len(argv) == 13 and argv[1] == '--jitless' and argv.count('--import') == 1
    profile = Path(argv[7])
    before_profile = sha(profile)
    environment = {**base_env, **captured}
    run('actual-consumers', [args.node, '--jitless', HERE / 'host-layout-consumers.mjs', runtime, guest,
        str(argv_path) + '.env.json', out / 'consumers.json'], env=environment, cwd=workspace)
    # Dump is diagnostic-only: remove the web listening flags, add dump-config.
    run('actual-dump', [args.node, *argv[1:8], '--dump-config'], env=environment, cwd=workspace)
    dump = (out / 'actual-dump.stdout.log').read_text()
    assert str(workspace) in dump and 'ohos-subprocess' in dump and 'sandbox-policy' in dump

    # Reuse all real five-tool/approval assertions from the repository round.
    # Only its fixture layout, argv/env inputs and omitted session cwd change.
    source_round = ROOT / 'runtime/ohos/sim/round.mjs'
    round_text = source_round.read_text()
    replacements = [
        ("from './fake-model.mjs';", "from " + json.dumps((ROOT / 'runtime/ohos/sim/fake-model.mjs').as_uri()) + ';'),
        ("new URL('./preload.mjs', import.meta.url)", "new URL(" + json.dumps((ROOT / 'runtime/ohos/sim/preload.mjs').as_uri()) + ')'),
        ("new URL('./observe-loader.mjs', import.meta.url)", "new URL(" + json.dumps((ROOT / 'runtime/ohos/sim/observe-loader.mjs').as_uri()) + ')'),
        ("const workspace = join(out, 'workspace');\nawait mkdir(workspace);", 'const workspace = ' + json.dumps(str(workspace)) + ';'),
        ("await mkdir(join(out, 'home'), { mode: 0o700 });", '// Existing private guest directories are supplied by Host.'),
        ("if (values.mode !== 'jit') flags.push('--jitless');", '// --jitless is already in the captured production argv.'),
        ("const env = {", 'const hostEnvironment = ' + json.dumps(captured, ensure_ascii=False) + ';\nconst env = {'),
        ("DSH_HOME: join(out, 'home'),", '...hostEnvironment,'),
        ("const args = [...flags, join(prefix, 'node_modules/@deepseek-ai/dsh/lib/bin.js'), 'web'];", 'const hostArgv = ' + json.dumps(argv, ensure_ascii=False) + ';\nconst args = [...flags, ...hostArgv.slice(1)];'),
        ("for (const name of [...profilePatches, overlay]) args.push('--patch', resolve(name));\nargs.push('--host', '127.0.0.1', '--port', '0', '--no-open');", "args.splice(args.indexOf('--host'), 0, ...[...profilePatches, overlay].flatMap(name => ['--patch', resolve(name)]));"),
        ("report.profilePatches = profilePatches.map((name) => resolve(name));", "report.profilePatches = [hostArgv[7], ...profilePatches.map((name) => resolve(name))];\nreport.hostGenerated = {argv:hostArgv, environment:hostEnvironment, sessionCreateOmitsCwd:true};"),
        ("{ request: { cwd: workspace, agentPreset: 'standard' } }", "{ request: { agentPreset: 'standard' } }"),
    ]
    for before, after in replacements:
        assert round_text.count(before) == 1, before
        round_text = round_text.replace(before, after)
    round_driver = out / 'host-layout-round.mjs'
    round_driver.write_text(round_text)
    command = [args.node, round_driver, '--prefix', runtime, '--out', out / 'round', '--mode', 'sim', '--platform',
        '--native-library-dir', args.native_library_dir, '--linked-publication-fixture', args.publication_fixture]
    for name in ['libdsh_flock.so', 'libdsh_require_builtin.so']:
        command += ['--allow-addon', args.native_library_dir / name]
    run('actual-round', command)
    report = json.loads((out / 'round/report.json').read_text())
    assert report['status'] == 'PASS' and report['approvals'] == 2 and report['loader']['observedRoute'] == 'native-addon'
    assert sha(profile) == before_profile
    write_json(out / 'report.json', {'scope': 'Linux actual pinned DSH, strict simulation; no SDK/Ark/HAP/device claim',
        'assertionsPassed': True, 'tools': 5, 'approvals': report['approvals'], 'profileUnchanged': True,
        'profileSha256': before_profile, 'roundSourceSha256': sha(source_round), 'roundDriverSha256': sha(round_driver),
        'prefixInputManifestSha256': sha(out / 'prefix-input.json'),
        'processDependencyManifestSha256': sha(out / 'process-dependencies-input.json'),
        'inputs': {str(path): sha(path) for path in [core / 'host_core.cpp', core / 'host_core.h', HERE / 'host-profile.cc',
            HERE / 'host-layout-consumers.mjs', Path(__file__), args.publication_fixture,
            args.native_library_dir / 'libdsh_flock.so', args.native_library_dir / 'libdsh_require_builtin.so']}})
    print('Host layout actual consumers, configuration and strict five-tool/two-approval round completed.', flush=True)


if __name__ == '__main__':
    main()
