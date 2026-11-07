// Refs #705: actual SessionStore fork, JSONL persistence and deletion seam.
// DSH_PREFIX=<isolated patched prefix> node --test runtime/tests/session-deletion-inherited-catalog.test.mjs
import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
if (!process.env.DSH_PREFIX) throw Error('Set DSH_PREFIX to an isolated patched runtime');
const load = name => import(pathToFileURL(join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai', name, 'lib/index.js')));
const { Context } = await load('cordis');
const { SessionStore } = await load('dsh-session');
const { SessionProjectionRegistry } = await load('dsh-session-projection');
const { apply } = await load('dsh-session-persistence-jsonl');

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'dsh-fork-delete-'));
  const live = new Context(), disk = new Context();
  t.after(async () => {
    try { await live.fiber.dispose(); } finally {
      try { await disk.fiber.dispose(); } finally { await rm(root, { recursive: true, force: true }); }
    }
  });
  for (const plugin of [SessionProjectionRegistry, SessionStore]) await live.plugin(plugin).await();
  await apply(disk, { root, compression: 'none', listConcurrency: 1 });
  return { live, disk, storage: disk.sessionPersistence };
}
function catalog(parent, child) {
  parent.append('subagent/catalog', {
    version: 0, childId: child.id, childCreatedAt: child.header.createdAt,
    mode: 'one-shot', label: 'synthetic completed child',
  });
}
async function persist(f, session) {
  const writer = await f.storage.create(session.header, { inheritedEventCount: session.inheritedEventCount });
  try { await writer.append(session.snapshotEvents()); await writer.flush(); } finally { await writer.close(); }
}
async function read(f, id) {
  const reader = await f.storage.open(id, 'read');
  try { return { inheritedEventCount: reader.inheritedEventCount, events: (await reader.read()).events, header: reader.header }; }
  finally { await reader.close(); }
}
const hooks = () => ({ prepare: async () => {}, inspectTasks: async () => false, cleanup: async () => {} });
const remove = (f, id) => f.storage.dshGoDeletion.delete(id, hooks());
async function sourceWithChild(f) {
  const source = f.live.sessions.create('source');
  const child = f.live.sessions.create('actual-child', { meta: { origin: 'subagent', parentSession: source.id, delegationDepth: 1 } });
  catalog(source, child);
  return { source, child };
}

test('fork inherited catalog is not its own child relation; original parent and child remain', async t => {
  const f = await fixture(t), { source, child } = await sourceWithChild(f);
  const fork = f.live.sessions.fork(source, undefined, 'fork');
  assert.equal(fork.inheritedEventCount, source.seq);
  assert.equal(fork.header.isSeeded, true);
  for (const s of [source, child, fork]) await persist(f, s);
  await f.live.fiber.dispose();
  const beforeSource = await read(f, source.id), beforeChild = await read(f, child.id);
  const restored = await read(f, fork.id);
  assert.equal(restored.inheritedEventCount, fork.inheritedEventCount);
  assert.ok(restored.events.some(e => e.type === 'subagent/catalog' && e.seq < restored.inheritedEventCount));
  await remove(f, fork.id);
  assert.equal(f.storage.dshGoDeletion.deleted(fork.id), true);
  await assert.rejects(f.storage.open(fork.id, 'read'), { name: 'SessionPersistenceNotFoundError' });
  assert.deepEqual(await read(f, source.id), beforeSource);
  assert.deepEqual(await read(f, child.id), beforeChild);
  await assert.rejects(remove(f, source.id), { code: 'session-related' });
  await assert.rejects(remove(f, child.id), { code: 'session-related' });
});

test('a new catalog after the inherited boundary still blocks deletion', async t => {
  const f = await fixture(t), { source } = await sourceWithChild(f);
  const fork = f.live.sessions.fork(source, undefined, 'own-catalog');
  // External executions legitimately have a catalog without a local child Session.
  fork.append('subagent/catalog', { version: 2, childId: 'external-execution', childCreatedAt: 1, mode: 'external', label: 'own' });
  await persist(f, fork);
  await f.live.fiber.dispose();
  const restored = await read(f, fork.id);
  assert.ok(restored.events.some(e => e.type === 'subagent/catalog' && e.seq >= restored.inheritedEventCount));
  await assert.rejects(remove(f, fork.id), { code: 'session-related' });
  assert.equal(f.storage.dshGoDeletion.deleted(fork.id), false);
  assert.deepEqual(await read(f, fork.id), restored);
});

test('fork of a fork uses its own new inherited boundary', async t => {
  const f = await fixture(t), { source } = await sourceWithChild(f);
  const first = f.live.sessions.fork(source, undefined, 'first-fork');
  first.append('subagent/catalog', { version: 2, childId: 'external-second', childCreatedAt: 2, mode: 'external', label: 'first-own' });
  const second = f.live.sessions.fork(first, undefined, 'second-fork');
  assert.ok(second.inheritedEventCount > first.inheritedEventCount);
  await persist(f, first); await persist(f, second);
  await f.live.fiber.dispose();
  assert.equal((await read(f, second.id)).inheritedEventCount, second.inheritedEventCount);
  await assert.rejects(remove(f, first.id), { code: 'session-related' });
  await remove(f, second.id);
  assert.equal(f.storage.dshGoDeletion.deleted(second.id), true);
  assert.ok((await read(f, first.id)).events.some(e => e.type === 'subagent/catalog' && e.seq >= first.inheritedEventCount));
});
