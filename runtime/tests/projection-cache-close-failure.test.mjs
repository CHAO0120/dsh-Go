// Real Factory/JSONL/cache permission boundary; no fake backend or model calls.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readdir, readFile, chmod, stat, open, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
const load = name => import(pathToFileURL(join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai', name, 'lib/index.js')));
function errors(error) {
  if (!error || typeof error !== 'object') return [];
  return [error, ...errors(error.cause), ...(Array.isArray(error.errors) ? error.errors.flatMap(errors) : [])];
}
async function files(dir) {
  const result = [];
  for (const e of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, e.name);
    if (e.isDirectory()) result.push(...await files(path));
    else if (e.isFile()) result.push(path);
  }
  return result;
}
test('failed factory close cannot publish an undurable title checkpoint; resumed instance heals', {
  skip: process.platform !== 'linux' ? 'real Linux DAC permission fixture' : false,
  timeout: 20000,
}, async t => {
  assert.ok(process.env.DSH_PREFIX, 'DSH_PREFIX required');
  const { Context } = await load('cordis');
  const { SessionProjectionCache } = await load('dsh-session-projection-cache');
  const originalWrite = SessionProjectionCache.prototype.write;
  const writes = [];
  // Observe actual public method completion, preserving its exact promise/value.
  SessionProjectionCache.prototype.write = function (...args) {
    const promise = Reflect.apply(originalWrite, this, args);
    writes.push(Promise.resolve(promise).then(value => ({ status: 'fulfilled', value }), reason => ({ status: 'rejected', reason })));
    return promise;
  };
  async function settleWrites() {
    let n;
    do { n = writes.length; await Promise.all(writes.slice(0, n)); } while (n !== writes.length);
  }
  const root = await mkdtemp(join(tmpdir(), 'dsh-cache-close-'));
  const logs = join(root, 'logs');
  const ctx = new Context();
  const forks = [];
  let owner, replacement, logPath, oldMode, disposeAttempted = false;
  try {
    async function plugin(name, config, exportName = 'default') {
      const mod = await load(name);
      const fork = ctx.plugin(exportName === null ? mod : mod[exportName], config);
      forks.push(fork); await fork.await();
    }
    for (const name of ['dsh-session-projection', 'dsh-session', 'dsh-agent', 'dsh-llm', 'dsh-tools', 'dsh-system-prompt', 'dsh-commands']) await plugin(name);
    await plugin('dsh-storage');
    await plugin('dsh-storage-json', { root: join(root, 'cache') }, null);
    await plugin('dsh-storage-domain', { backend: 'json' }, null);
    await (await load('dsh-session-persistence-jsonl')).apply(ctx, { root: logs, compression: 'none', listConcurrency: 1 });
    await plugin('dsh-session-projection-cache', { writeEveryEvents: 1000, writeIntervalMs: 5000 });
    await plugin('dsh-session-title', { fallbackMaxWords: 8, fallbackMaxBytes: 96, maxTitleBytes: 120 });
    await plugin('dsh-agent-loop', { agents: [] }, 'AgentLoop');
    t.mock.timers.enable({ apis: ['setTimeout'] });
    const id = 'cache-close-permission-fixture';
    owner = await ctx.agents.create({ sessionId: id });
    await settleWrites();
    const session = owner.agent.session;
    ctx.sessionTitle.rename(session, 'durable title');
    await ctx.sessionProjectionCache.write(session);
    await settleWrites();
    assert.equal(ctx.sessionProjectionCache.cachedSnapshot(session.header, ['title'])?.values.title, 'durable title');
    const paths = (await files(logs)).filter(path => /\/session\.v\d+\.jsonl$/.test(path));
    assert.equal(paths.length, 1, 'one actual session log');
    logPath = paths[0]; oldMode = (await stat(logPath)).mode & 0o777;
    const baseline = await readFile(logPath);
    await chmod(logPath, 0o400);
    let probe;
    try { probe = await open(logPath, 'a'); }
    catch (error) { assert.equal(error.code, 'EACCES', 'real permission precondition'); }
    if (probe) {
      await probe.close();
      t.skip('DAC append restriction ineffective (root/capabilities/filesystem); no semantic result');
      return;
    }
    ctx.sessionTitle.rename(session, 'volatile title');
    assert.ok(session.snapshotEvents().some(e => e.type === 'session/title' && e.data.title === 'volatile title'));
    assert.deepEqual(await readFile(logPath), baseline);
    disposeAttempted = true;
    await assert.rejects(owner.dispose(), error => errors(error).some(e => e.code === 'EACCES' && e.path === logPath));
    assert.equal(ctx.sessions.get(id), undefined);
    assert.equal(ctx.agents.get(id), undefined);
    await settleWrites();
    const hint = ctx.sessionProjectionCache.cachedSnapshot(session.header, ['title']);
    // Capture before any coldSnapshot can repair the erroneous checkpoint.
    const reader = await ctx.sessionPersistence.open(id, 'read');
    try {
      const physical = await reader.read();
      assert.ok(physical.events.some(e => e.type === 'session/title' && e.data.title === 'durable title'));
      assert.ok(!physical.events.some(e => e.type === 'session/title' && e.data.title === 'volatile title'));
    } finally { await reader.close(); }
    assert.equal(hint?.values.title, 'durable title');
    await chmod(logPath, oldMode);
    replacement = await ctx.agentLoop.resume(ctx, { resumeSessionId: id });
    await settleWrites();
    assert.notEqual(replacement.agent.session, session);
    ctx.sessionTitle.rename(replacement.agent.session, 'recovered title');
    await ctx.sessionProjectionCache.write(replacement.agent.session);
    assert.equal(ctx.sessionProjectionCache.cachedSnapshot(replacement.agent.session.header, ['title'])?.values.title, 'recovered title');
    ctx.sessionTitle.rename(replacement.agent.session, 'final close title');
    await replacement.dispose(); replacement = undefined;
    await settleWrites();
    assert.equal(ctx.sessionProjectionCache.cachedSnapshot(session.header, ['title'])?.values.title, 'final close title');
    const finalReader = await ctx.sessionPersistence.open(id, 'read');
    try {
      const physical = await finalReader.read();
      assert.equal(physical.events.filter(e => e.type === 'session/title').at(-1)?.data.title, 'final close title');
    } finally { await finalReader.close(); }
  } finally {
    if (logPath && oldMode !== undefined) await chmod(logPath, oldMode);
    try {
      if (replacement) await replacement.dispose();
      if (owner && !disposeAttempted) await owner.dispose();
      await settleWrites();
    } finally {
      try { for (const fork of forks.reverse()) await fork.dispose(); await ctx.fiber.dispose(); }
      finally { SessionProjectionCache.prototype.write = originalWrite; t.mock.timers.reset(); await rm(root, { recursive: true, force: true }); }
    }
  }
});
