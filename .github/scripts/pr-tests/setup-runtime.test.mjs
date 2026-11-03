import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const script = fileURLToPath(new URL('./setup-runtime.sh', import.meta.url));

test('a sparse checkout cannot silently replace tracked runtime locks with npm install', t => {
  const root = mkdtempSync(join(tmpdir(), 'dsh-runtime-bootstrap-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  execFileSync('git', ['init', '-q'], { cwd: root });
  mkdirSync(join(root, 'runtime'));
  mkdirSync(join(root, 'bin'));
  writeFileSync(join(root, 'runtime/build-runtime.sh'), 'DSH_VERSION="${DSH_VERSION:-0.2.1-rc.4}"\n');
  writeFileSync(join(root, 'bin/npm'), '#!/bin/sh\necho UNPINNED_NPM_WAS_CALLED\nexit 99\n', { mode: 0o755 });
  const child = spawnSync('bash', [script], {
    cwd: root,
    env: { ...process.env, PATH: `${join(root, 'bin')}:${process.env.PATH}`, RUNNER_TEMP: root },
    encoding: 'utf8',
  });
  assert.equal(child.status, 1);
  assert.match(child.stderr, /Tracked DSH lockfiles are missing/);
  assert.doesNotMatch(child.stdout, /UNPINNED_NPM_WAS_CALLED/);
});
