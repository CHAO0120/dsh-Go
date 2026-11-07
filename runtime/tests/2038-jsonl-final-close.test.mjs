// Adjacent-boundary probe, not run here: real backend and files; close rejects after real sync/close.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { syncBuiltinESMExports } from 'node:module';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';
if (!process.env.DSH_PREFIX) throw Error('Set DSH_PREFIX to the locked, baseline-patched 0.2.2-rc.1 prefix');
const base = join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai');
const load = name => import(pathToFileURL(join(base, name, 'lib/index.js')));
const [{ Context }, { Session }, { apply }] = await Promise.all([
  load('cordis'), load('dsh-session'), load('dsh-session-persistence-jsonl'),
]);
const ioError = label => Object.assign(Error(label), { code: 'EIO' });

for (const compression of ['none', 'zstd']) test(`${compression}: successful write/sync followed by close failure must not duplicate the batch`, async t => {
  const root = await fs.mkdtemp(join(tmpdir(), 'jsonl-final-close-'));
  const ctx = new Context();
  let writer;
  const originalOpen = fs.open;
  t.after(async () => {
    fs.open = originalOpen;
    syncBuiltinESMExports();
    await writer?.close().catch(() => {});
    await ctx.fiber.dispose();
    await fs.rm(root, { recursive: true, force: true });
  });
  await apply(ctx, { root, compression, listConcurrency: 1 });
  const session = Session.create(`final-close-${compression}`);
  writer = await ctx.sessionPersistence.create(session.header);
  session.append('turn/start', { turn: 1 });
  await writer.append(session.snapshotEvents());
  const directory = join(root, '_no-cwd', session.id);
  const names = (await fs.readdir(directory)).filter(name => /^session\.v\d+\.jsonl(?:\.zstd)?$/.test(name));
  assert.equal(names.length, 1, 'one real current log was materialized');
  const path = join(directory, names[0]);
  const before = await fs.readFile(path);
  session.append('turn/end', { turn: 1, reason: { kind: 'completed' } });
  const batch = session.snapshotEvents().slice(-1);
  const closeFailure = ioError('controlled final close failure after successful write and sync');
  let synced = false, closed = false;
  fs.open = async function (target, flags, ...args) {
    const handle = await originalOpen.call(this, target, flags, ...args);
    if (String(target) === path && flags === 'a') {
      const realSync = handle.sync.bind(handle), realClose = handle.close.bind(handle);
      handle.sync = async () => { await realSync(); synced = true; };
      handle.close = async () => {
        await realClose();
        closed = true;
        throw closeFailure;
      };
    }
    return handle;
  };
  syncBuiltinESMExports();
  await assert.rejects(writer.append(batch), error => error === closeFailure);
  assert(synced && closed, 'real fsync and descriptor close completed before the controlled error');
  const retained = await fs.readFile(path);
  assert(retained.length > before.length, 'real bytes remain after successful write/sync and the final close error');
  fs.open = originalOpen;
  syncBuiltinESMExports();
  const retried = await writer.append(batch).then(() => ({ accepted: true }), error => ({ accepted: false, error }));
  const after = await fs.readFile(path);
  const reread = await writer.read().then(value => `read accepted ${value.events.length} events`, error => `read rejected: ${error.message}`);
  t.diagnostic(`retry accepted=${retried.accepted}; before=${before.length}, retained=${retained.length}, after=${after.length}; ${reread}`);
  assert.deepEqual(after, retained, 'a final-close failure must not cause identical sequence numbers to be appended again');
});
