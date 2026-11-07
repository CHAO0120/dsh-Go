import test from 'node:test';
import assert from 'node:assert/strict';
import { fork } from 'node:child_process';
import { mkdtemp, mkdir, readdir, chmod, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

test('workspace cleanup rejection reaches the existing Session observer warning', {
  skip: process.platform !== 'linux' || process.getuid?.() === 0, timeout: 30000,
}, async t => {
  assert(process.env.DSH_PREFIX, 'Set DSH_PREFIX to the actual locked runtime prefix');
  const root = await mkdtemp(join(tmpdir(), 'workspace-dispose-error-'));
  const temporary = join(root, 'tmp'); await mkdir(temporary);
  let child, exited;
  t.after(async () => {
    if (child && child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
    await exited?.catch(() => {});
    for (const name of await readdir(temporary)) if (name.startsWith('dsh-workspace-changes-')) await chmod(join(temporary, name), 0o700).catch(() => {});
    await rm(root, { recursive: true, force: true });
  });
  child = fork(fileURLToPath(new URL('./fixtures/workspace-dispose-error.mjs', import.meta.url)), [], {
    env: { ...process.env, TMPDIR: temporary, TMP: temporary, TEMP: temporary, WORKSPACE_DISPOSE_FIXTURE: root },
    stdio: ['ignore', 'pipe', 'pipe', 'ipc'], signal: t.signal,
  });
  let output = '', result;
  child.stdout.on('data', chunk => { output += chunk; });
  child.stderr.on('data', chunk => { output += chunk; });
  child.on('message', message => { result = message; });
  exited = new Promise(resolve => {
    let spawnError;
    child.once('error', error => { spawnError = error; if (!child.pid) resolve({ code: null, error }); });
    child.once('close', (code, signal) => resolve({ code, signal, error: spawnError }));
  });
  const exit = await exited;
  assert.equal(exit.code, 0, `fixture setup/cleanup failed: ${output}`);
  assert(result, `fixture did not report its actual outcome: ${output}`);
  if (result.skip) { t.skip(result.skip); return; }
  assert.equal(result.permissionDenied, true);
  assert.equal(result.scratchCreatedByPlugin, true);
  t.diagnostic(JSON.stringify(result));
  assert.equal(result.kind, 'contained', 'real cleanup rejection escaped the existing observer collection');
});
