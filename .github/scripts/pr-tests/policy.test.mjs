import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { classifyChanges, evaluateGate, HEAVY_JOBS, parseRawDiff } from './policy.mjs';

const policy = fileURLToPath(new URL('./policy.mjs', import.meta.url));
const modified = path => ({ path, oldMode: '100644', newMode: '100644' });
const mode = paths => classifyChanges(paths.map(modified)).mode;

function results(result = 'success') {
  return { plan: { result: 'success' }, light: { result: 'success' },
    ...Object.fromEntries(HEAVY_JOBS.map(name => [name, { result }])) };
}

test('known documentation and guide page outputs qualify for lightweight checks', () => {
  for (const path of ['README.md', 'README.en.md', 'LICENSE', 'CONTRIBUTING.md',
    'SECURITY.en.md', '.github/PULL_REQUEST_TEMPLATE.md', 'docs/architecture.md',
    'docs/design/scrolling.md', 'docs/images/scroll.png', 'sdk/plugin-kit/README.en.md',
    'docs/guide/zh/chat.md', 'app/assets/skills/dsh-go-guide/zh-chat.md']) {
    assert.equal(mode([path]), 'docs', path);
  }
});

test('new and removed documentation still require ordinary non-executable file modes', () => {
  assert.equal(classifyChanges([{ path: 'docs/new.md', oldMode: '000000', newMode: '100644' },
    { path: 'docs/old.md', oldMode: '100644', newMode: '000000' }]).mode, 'docs');
});

test('CI toolchain pins match the build inputs and do not rely on an ignored wrapper', () => {
  const root = new URL('../../../', import.meta.url);
  const read = path => readFileSync(new URL(path, root), 'utf8');
  const workflow = read('.github/workflows/pr-tests.yml');
  const pin = key => workflow.match(new RegExp(`^  ${key}: '([^']+)'$`, 'm'))?.[1];
  assert.equal(pin('FLUTTER_VERSION'), read('tooling/setup-toolchain.sh').match(/FLUTTER_VERSION="\$\{FLUTTER_VERSION:-([^}]+)\}"/)[1]);
  assert.equal(pin('NODE_VERSION'), read('runtime/build-runtime.sh').match(/NODE_VERSION="\$\{NODE_VERSION:-([^}]+)\}"/)[1]);
  assert.equal(pin('GRADLE_VERSION'), read('app/android/gradle/wrapper/gradle-wrapper.properties').match(/gradle-([0-9.]+)-all\.zip/)[1]);
  assert.match(workflow, /uses: gradle\/actions\/setup-gradle@/);
  assert.match(workflow, /run: gradle --no-daemon/);
  assert.doesNotMatch(workflow, /run: \.\/gradlew/);
  assert.doesNotMatch(workflow, /--update-goldens|DSH_TEST_GOLDEN_OUT:|DSH_TEST_LANG:\s*en/);
});

test('mixed code, configuration, agent instructions and unknown paths require full tests', () => {
  for (const path of ['app/lib/chat.dart', 'app/android/Main.kt', 'package.json', 'app/pubspec.lock',
    '.github/workflows/pr-tests.yml', '.github/scripts/pr-tests/policy.mjs',
    '.github/APPROVED_CONTRIBUTORS', 'AGENTS.md', '.agents/skills/pr/SKILL.md',
    'runtime/patches/pins.json', 'docs/example.js', 'docs/example.html', 'docs/example.svg',
    'docs/guide/SKILL.md', 'sdk/plugin-kit/skill/SKILL.md',
    'app/assets/skills/dsh-go-guide/SKILL.md', 'app/assets/skills/dsh-go-guide/manifest.json',
    'app/assets/skills/dsh-go-plugin/SKILL.md', 'app/assets/licenses/notice.md',
    'test/fixtures/README.md', 'new-directory/README.md']) {
    assert.equal(mode(['README.md', path]), 'full', path);
  }
});

test('executable bits, symlinks and invalid paths cannot gain a documentation exemption', () => {
  for (const [oldMode, newMode] of [['100644', '100755'], ['100755', '100644'],
    ['100644', '120000'], ['120000', '100644'], ['000000', '000000']]) {
    assert.equal(classifyChanges([{ path: 'README.md', oldMode, newMode }]).mode, 'full');
  }
  for (const path of ['/README.md', '../README.md', 'docs/../README.md',
    'docs//README.md', 'docs\\README.md', 'docs/new\nname.md', 'README.MD', null]) {
    assert.equal(mode([path]), 'full', String(path));
  }
  assert.equal(classifyChanges([]).mode, 'full');
  assert.equal(classifyChanges(null).mode, 'full');
});

test('NUL-separated raw diffs include deletions and reject truncated or renamed records', () => {
  const raw = Buffer.from(':100644 000000 abcdef0 0000000 D\0app/lib/old.dart\0' +
    ':000000 100644 0000000 abcdef0 A\0docs/new.md\0');
  const changes = parseRawDiff(raw);
  assert.equal(changes.length, 2);
  assert.equal(classifyChanges(changes).mode, 'full');
  assert.deepEqual(parseRawDiff(Buffer.alloc(0)), []);
  for (const invalid of ['broken', ':100644 100644 a b M\0', ':100644 100644 a b R100\0old\0new\0']) {
    assert.throws(() => parseRawDiff(Buffer.from(invalid)));
  }
  assert.throws(() => parseRawDiff(Buffer.from([0xff])));
});

test('full gate requires every expected suite to succeed, without silent skips', () => {
  assert.equal(evaluateGate('full', results()).pass, true);
  for (const name of ['plan', 'light', ...HEAVY_JOBS]) {
    for (const result of ['failure', 'cancelled', 'skipped', undefined]) {
      const jobs = results();
      jobs[name] = { result };
      assert.equal(evaluateGate('full', jobs).pass, false, `${name}: ${result}`);
    }
  }
  assert.equal(evaluateGate('full', { plan: { result: 'success' }, light: { result: 'success' } }).pass, false);
});

test('documentation exemptions still require classification and all lightweight checks', () => {
  assert.equal(evaluateGate('docs', results('skipped')).pass, true);
  assert.match(evaluateGate('docs', results('skipped')).reason, /not a full-test result/);
  for (const mode of ['', 'skip', 'true', undefined]) assert.equal(evaluateGate(mode, results()).pass, false);
  for (const name of ['plan', 'light', ...HEAVY_JOBS]) {
    const jobs = results('skipped');
    jobs[name] = { result: 'failure' };
    assert.equal(evaluateGate('docs', jobs).pass, false, name);
  }
  assert.equal(evaluateGate('docs', null).pass, false);
});

function fixture(t) {
  const root = resolve(mkdtempSync(join(tmpdir(), 'dsh-pr-policy-')));
  assert.equal(dirname(root), resolve(tmpdir()));
  assert.ok(basename(root).startsWith('dsh-pr-policy-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const git = (...args) => execFileSync('git', args, { cwd: root, encoding: 'utf8' }).trim();
  git('init', '--quiet');
  git('config', 'user.name', 'Policy fixture');
  git('config', 'user.email', 'policy@example.invalid');
  mkdirSync(join(root, 'app'));
  writeFileSync(join(root, 'README.md'), 'Documentation\n');
  writeFileSync(join(root, 'app/code.dart'), 'old code\n');
  git('add', 'README.md', 'app/code.dart');
  git('commit', '--quiet', '-m', 'fixture base');
  return { root, git };
}

function runPlan(root, base, head, event = 'pull_request') {
  const output = join(root, 'output.txt');
  const child = spawnSync(process.execPath, [policy, 'plan'], {
    cwd: root, encoding: 'utf8', env: { ...process.env, GITHUB_EVENT_NAME: event,
      BASE_SHA: base, HEAD_SHA: head, GITHUB_OUTPUT: output, GITHUB_STEP_SUMMARY: join(root, 'summary.md') },
  });
  return { child, output };
}

test('actual code-to-documentation rename cannot bypass the gate', t => {
  const { root, git } = fixture(t);
  const base = git('rev-parse', 'HEAD');
  mkdirSync(join(root, 'docs'));
  git('mv', 'app/code.dart', 'docs/code.md');
  git('commit', '--quiet', '-m', 'rename fixture');
  const { child, output } = runPlan(root, base, git('rev-parse', 'HEAD'));
  assert.equal(child.status, 0, child.stderr);
  assert.equal(readFileSync(output, 'utf8'), 'mode=full\n');
});

test('classification uses the PR merge base rather than unrelated updates on main', t => {
  const { root, git } = fixture(t);
  const ancestor = git('rev-parse', 'HEAD');
  writeFileSync(join(root, 'README.md'), 'Changed documentation\n');
  git('add', 'README.md');
  git('commit', '--quiet', '-m', 'documentation fixture');
  const head = git('rev-parse', 'HEAD');
  git('checkout', '--quiet', '-b', 'advanced-main', ancestor);
  writeFileSync(join(root, 'app/code.dart'), 'unrelated main update\n');
  git('add', 'app/code.dart');
  git('commit', '--quiet', '-m', 'advance main fixture');
  const { child, output } = runPlan(root, git('rev-parse', 'HEAD'), head);
  assert.equal(child.status, 0, child.stderr);
  assert.equal(readFileSync(output, 'utf8'), 'mode=docs\n');
});

test('manual and merge-queue runs never infer a documentation exemption', t => {
  const { root } = fixture(t);
  for (const event of ['workflow_dispatch', 'merge_group', 'push']) {
    const { child } = runPlan(root, undefined, undefined, event);
    assert.equal(child.status, 0, child.stderr);
    assert.match(child.stdout, /Test plan: full/);
  }
  const { child } = runPlan(root, 'not-a-sha', 'not-a-sha');
  assert.notEqual(child.status, 0);
});
