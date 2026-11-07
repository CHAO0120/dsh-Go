// DRAFT: executes only real withFileLock from the eventual candidate prefix.
import test from 'node:test';
import assert from 'node:assert/strict';
import { fork } from 'node:child_process';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL, fileURLToPath } from 'node:url';
const worker = fileURLToPath(new URL('./fixtures/atomic-slot-worker.mjs', import.meta.url));
async function fixture(t) {
  const source = process.env.DSH_ATOMIC_SOURCE ?? (process.env.DSH_PREFIX && join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai/dsh-atomic-write/lib/index.js'));
  assert.ok(source, 'real candidate DSH_PREFIX or DSH_ATOMIC_SOURCE required');
  const { withFileLock } = await import(pathToFileURL(source));
  const root = await mkdtemp(join(tmpdir(), 'atomic-slot-recovery-'));
  const children = [];
  t.after(async () => {
    for (const c of children) c.kill();
    await Promise.all(children.map(c => c.exit));
    for (const c of children) t.signal.removeEventListener('abort', c.kill);
    await rm(root, { recursive: true, force: true });
  });
  function launch(mode) {
    const p = fork(worker, [mode, join(root, 'data.json')], { env: { ...process.env, DSH_ATOMIC_SOURCE: source }, stdio: ['ignore', 'ignore', 'pipe', 'ipc'] });
    let stderr = ''; p.stderr.on('data', b => { stderr += b; });
    const messages = [], waiters = [];
    p.on('message', message => { if (waiters.length) waiters.shift()(message); else messages.push(message); });
    const exit = new Promise(resolveExit => { p.once('error', error => resolveExit({ error })); p.once('exit', (code, signal) => resolveExit({ code, signal })); });
    const kill = () => { if (p.exitCode === null && p.signalCode === null) p.kill('SIGKILL'); };
    t.signal.addEventListener('abort', kill, { once: true });
    const c = { p, exit, kill, next: async () => {
      if (messages.length) return messages.shift();
      return Promise.race([new Promise(r => waiters.push(r)), exit.then(result => { throw new Error('worker exited before gate: ' + JSON.stringify(result) + stderr); })]);
    } };
    children.push(c); return c;
  }
  async function deadMain() {
    const a = launch('hold-main'); assert.equal((await a.next()).type, 'main-held');
    a.kill(); assert.deepEqual(await a.exit, { code: null, signal: 'SIGKILL' });
    assert.throws(() => process.kill(a.p.pid, 0), { code: 'ESRCH' });
    return readFile(join(root, 'data.json.lock'), 'utf8');
  }
  return { filename: join(root, 'data.json'), withFileLock, launch, deadMain };
}
const options = { timeout: 10000, skip: process.platform !== 'linux' ? 'real process termination gates validated on Linux' : false };
test('successor recovers after actual slot publication owner dies before main unlink', options, async t => {
  const f = await fixture(t), old = await f.deadMain();
  const b = f.launch('hold-slot'); const gate = await b.next();
  assert.equal(gate.type, 'slot-held');
  assert.equal(await readFile(gate.slot, 'utf8'), `${b.p.pid}\n`);
  assert.equal(await readFile(f.filename + '.lock', 'utf8'), old);
  b.kill(); assert.deepEqual(await b.exit, { code: null, signal: 'SIGKILL' });
  assert.throws(() => process.kill(b.p.pid, 0), { code: 'ESRCH' });
  let operations = 0;
  assert.equal(await f.withFileLock(f.filename, () => { operations++; return 42; }, { waitMs: 0 }), 42);
  assert.equal(operations, 1);
  assert.equal(await readFile(gate.slot, 'utf8'), `${b.p.pid}\n`, 'dead slot never removed or reused');
  await assert.rejects(readFile(f.filename + '.lock'), { code: 'ENOENT' });
});
test('a live published slot prevents another real writer entering the takeover', options, async t => {
  const f = await fixture(t), old = await f.deadMain();
  const b = f.launch('hold-slot'); const gate = await b.next(); assert.equal(gate.type, 'slot-held');
  let operations = 0;
  await assert.rejects(f.withFileLock(f.filename, () => { operations++; }, { waitMs: 0 }), /timed out waiting for the writer lock/);
  assert.equal(operations, 0);
  assert.equal(await readFile(f.filename + '.lock', 'utf8'), old);
  assert.equal(await readFile(gate.slot, 'utf8'), `${b.p.pid}\n`);
  b.p.send({ release: true });
  assert.equal((await b.next()).type, 'main-held');
  assert.equal((await b.next()).type, 'finished');
  assert.deepEqual(await b.exit, { code: 0, signal: null });
  assert.equal(await readFile(gate.slot, 'utf8'), `${b.p.pid}\n`);
});
