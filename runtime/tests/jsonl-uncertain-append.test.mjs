// Candidate acceptance: real public writer/files, only filesystem errors injected.
// Requires the candidate locked runtime prefix; no replacement of historical baseline evidence.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { syncBuiltinESMExports } from 'node:module';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';
if (!process.env.DSH_PREFIX) throw Error('Set DSH_PREFIX to a locked candidate prefix');
const base = join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai');
const load = name => import(pathToFileURL(join(base, name, 'lib/index.js')));
const [{ Context }, { Session, SessionStore }, { apply }] = await Promise.all([
  load('cordis'), load('dsh-session'), load('dsh-session-persistence-jsonl'),
]);
const cases = [
  { name: 'sync-fails-rollback-succeeds', uncertain: false },
  { name: 'sync-fails-rollback-open-fails', uncertain: true },
  { name: 'write-sync-succeed-final-close-fails', uncertain: true },
  { name: 'rollback-restored-only-close-fails', uncertain: false },
  { name: 'sync-fails-rollback-open-fails', uncertain: true, live: true },
];
for (const compression of ['none', 'zstd']) for (const boundary of cases) {
  test(`${compression}: ${boundary.name}${boundary.live ? ": live drain" : ""}`, async t => {
    const root = await fs.mkdtemp(join(tmpdir(), 'jsonl-boundaries-'));
    const ctx = new Context();
    let writer, reopened, detach;
    const originalOpen = fs.open;
    const restore = () => { fs.open = originalOpen; syncBuiltinESMExports(); };
    t.after(async () => {
      restore();
      await reopened?.close().catch(() => {});
      await writer?.close().catch(() => {});
      detach?.();
      await ctx.fiber.dispose();
      await fs.rm(root, { recursive: true, force: true });
    });
    await apply(ctx, { root, compression, listConcurrency: 1 });
    const store = boundary.live ? new SessionStore(ctx) : undefined;
    const id = `boundary-${compression}-${boundary.name}`;
    const session = store ? store.prepare(id) : Session.create(id);
    writer = await ctx.sessionPersistence.create(session.header);
    if (store) { detach = store.enter(session); store.announce(session); }
    session.append('turn/start', { turn: 1 });
    if (store) await store.flush(session);
    else await writer.append(session.snapshotEvents());
    const directory = join(root, '_no-cwd', session.id);
    const names = (await fs.readdir(directory)).filter(name => /^session\.v\d+\.jsonl(?:\.zstd)?$/.test(name));
    assert.equal(names.length, 1);
    const path = join(directory, names[0]);
    const before = await fs.readFile(path);
    session.append('turn/end', { turn: 1, reason: { kind: 'completed' } });
    const batch = session.snapshotEvents().slice(-1);
    const primary = Object.assign(Error(boundary.name), { code: 'EIO' });
    const rollbackFailure = Object.assign(Error('controlled rollback error'), { code: 'EIO' });
    const atSync = Promise.withResolvers(), releaseSync = Promise.withResolvers();
    let injected = false, retained, rollbackSeen = false;
    fs.open = async function (target, flags, ...args) {
      const targetLog = String(target) === path;
      if (targetLog && flags === 'r+' && boundary.name === 'sync-fails-rollback-open-fails') {
        rollbackSeen = true;
        throw rollbackFailure;
      }
      const handle = await originalOpen.call(this, target, flags, ...args);
      if (targetLog && flags === 'a' && !injected) {
        injected = true;
        const realSync = handle.sync.bind(handle), realClose = handle.close.bind(handle);
        handle.sync = async () => {
          retained = await fs.readFile(path); // actual completed writeFile bytes, before any retry
          atSync.resolve();
          await releaseSync.promise;
          if (boundary.name === 'write-sync-succeed-final-close-fails') return realSync();
          throw primary;
        };
        if (boundary.name === 'write-sync-succeed-final-close-fails') handle.close = async () => {
          await realClose();
          throw primary;
        };
      }
      if (targetLog && flags === 'r+' && boundary.name === 'rollback-restored-only-close-fails') {
        rollbackSeen = true;
        const realClose = handle.close.bind(handle);
        handle.close = async () => { await realClose(); throw rollbackFailure; };
      }
      return handle;
    };
    syncBuiltinESMExports();
    const first = store ? store.flush(session) : writer.append(batch);
    // Attach rejection handlers immediately; no sleep and no unhandled queued rejection.
    const firstResult = Promise.allSettled([first]);
    await Promise.race([
      atSync.promise,
      first.then(() => { throw Error('write unexpectedly finished before the sync boundary'); }, error => { throw error; }),
    ]);
    const queuedResult = boundary.uncertain ? Promise.allSettled([writer.append(batch)]) : undefined;
    releaseSync.resolve();
    const [initial] = await firstResult;
    assert.equal(initial.status, 'rejected');
    if (boundary.name.includes('rollback-open-fails') || boundary.name.includes('only-close-fails')) {
      assert(rollbackSeen);
      assert(initial.reason instanceof AggregateError);
      assert(initial.reason.errors.includes(primary) && initial.reason.errors.includes(rollbackFailure));
    } else assert.equal(initial.reason, primary);
    assert(retained.length > before.length);
    if (boundary.uncertain) {
      const [queued] = await queuedResult;
      assert.equal(queued.status, 'rejected', 'append already queued behind the failing write must reject');
      const uncertain = queued.reason;
      assert(uncertain instanceof Error);
      assert.match(uncertain.message, /close and reopen/);
      assert.equal(uncertain.cause, initial.reason, 'refusals retain the original append failure');
      restore();
      const sameUncertainty = error => error === uncertain;
      await assert.rejects(writer.append(batch), sameUncertainty);
      await assert.rejects(writer.append([]), sameUncertainty);
      session.append('turn/start', { turn: 2 });
      const nextBatch = session.snapshotEvents().slice(-1);
      await assert.rejects(writer.append(nextBatch), sameUncertainty);
      if (store) await assert.rejects(store.flush(session), sameUncertainty);
      await assert.rejects(writer.flush(), sameUncertainty, 'materialized empty-buffer flush must not silently succeed');
      assert.deepEqual(await fs.readFile(path), retained);
      const independent = Session.create(`independent-${compression}-${boundary.name}`);
      const other = await ctx.sessionPersistence.create(independent.header);
      try {
        independent.append('turn/start', { turn: 1 });
        await other.append(independent.snapshotEvents());
        await other.flush();
      } finally { await other.close(); }
      await assert.rejects(writer.close(), sameUncertainty, 'uncertainty must be reported even with no live buffer');
      // Public open must acquire tracker claim/lease anew and scan actual retained sequence numbers.
      reopened = await ctx.sessionPersistence.open(session.id, 'write');
      assert.equal((await reopened.read()).events.length, session.snapshotEvents().length - nextBatch.length);
      await reopened.append(nextBatch);
      assert.deepEqual((await reopened.read()).events, session.snapshotEvents());
      await reopened.close();
    } else {
      restore();
      assert.deepEqual(await fs.readFile(path), before, 'truncate and sync restored the original prefix');
      await writer.append(batch);
      await writer.flush();
      assert.deepEqual((await writer.read()).events, session.snapshotEvents());
      await writer.close();
    }
  });
}
