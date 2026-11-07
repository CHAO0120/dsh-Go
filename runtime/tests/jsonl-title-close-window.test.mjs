// DRAFT: real public AgentFactory + title service + JSONL; Linux backend only.
// No model/network. Actual lease close is gated; timer progression is controlled.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { syncBuiltinESMExports } from 'node:module';
import { join, resolve, basename } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';

test('accepted title during final lease release cannot write after owner close', {
  skip: process.platform !== 'linux', timeout: 20000,
}, async t => {
  assert(process.env.DSH_PREFIX, 'Set DSH_PREFIX to the actual patched runtime prefix');
  const load = name => import(pathToFileURL(join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai', name, 'lib/index.js')));
  const [{ Context }, { apply: persistence }, { createUserMessage }, { SessionTitleService }] = await Promise.all([
    load('cordis'), load('dsh-session-persistence-jsonl'), load('dsh-llm'), load('dsh-session-title'),
  ]);
  const root = await fs.mkdtemp(join(tmpdir(), 'jsonl-title-close-'));
  const ctx = new Context(), forks = [];
  const atLeaseClose = Promise.withResolvers(), releaseLeaseClose = Promise.withResolvers();
  const atGenerate = Promise.withResolvers(), releaseGenerate = Promise.withResolvers();
  const lateWriteClosed = Promise.withResolvers();
  const lateHandles = new Set();
  let owner, successor, titleRun, closing, removeProvider;
  let armClose = false, gated = false, leaseActuallyClosed = false;
  let phase = 'setup', observedTitle, lateOpens = 0, closeWindowTimers = 0;
  const originalOpen = fs.open;
  let originalTimer;
  async function wait(promise) {
    t.signal.throwIfAborted();
    const aborted = Promise.withResolvers();
    const onAbort = () => aborted.reject(t.signal.reason);
    t.signal.addEventListener('abort', onAbort, { once: true });
    try { return await Promise.race([promise, aborted.promise]); }
    finally { t.signal.removeEventListener('abort', onAbort); }
  }
  t.after(async () => {
    releaseGenerate.resolve(); releaseLeaseClose.resolve();
    if (originalTimer) globalThis.setTimeout = originalTimer;
    t.mock.timers.reset();
    fs.open = originalOpen; syncBuiltinESMExports();
    await titleRun?.catch(() => {});
    await closing?.catch(() => {});
    // Close actual handles directly on failure; never await an observation
    // promise whose matching backend path may have failed before reaching it.
    await Promise.allSettled([...lateHandles].map(close => close()));
    await successor?.close().catch(() => {});
    await owner?.dispose().catch(() => {});
    await removeProvider?.();
    for (const fork of forks.reverse()) await fork.dispose();
    await ctx.fiber.dispose();
    await fs.rm(root, { recursive: true, force: true });
  });
  fs.open = async function (path, flags, ...args) {
    const handle = await originalOpen.call(this, path, flags, ...args);
    if (String(path).startsWith(root + '/') && basename(String(path)) === 'session.lock' && flags === 'w') {
      const realClose = handle.close.bind(handle);
      handle.close = async () => {
        if (!armClose || gated) return realClose();
        gated = true; phase = 'lease-close'; atLeaseClose.resolve();
        await releaseLeaseClose.promise;
        await realClose(); leaseActuallyClosed = true;
      };
    } else if (phase === 'successor-owned' && String(path).startsWith(root + '/') && flags === 'a') {
      lateOpens++;
      const realClose = handle.close.bind(handle);
      lateHandles.add(realClose);
      handle.close = async () => { try { return await realClose(); } finally { lateHandles.delete(realClose); lateWriteClosed.resolve(); } };
    }
    return handle;
  };
  syncBuiltinESMExports();
  for (const name of ['dsh-session-projection', 'dsh-session', 'dsh-agent', 'dsh-llm', 'dsh-tools', 'dsh-system-prompt', 'dsh-commands']) {
    const fork = ctx.plugin((await load(name)).default); forks.push(fork); await fork.await();
  }
  await persistence(ctx, { root, compression: 'none', listConcurrency: 1 });
  const loop = ctx.plugin((await load('dsh-agent-loop')).AgentLoop, { agents: [] });
  forks.push(loop); await loop.await();
  const titles = ctx.plugin(SessionTitleService, { fallbackMaxWords: 8, fallbackMaxBytes: 96, maxTitleBytes: 120 });
  forks.push(titles); await titles.await();
  owner = await ctx.agents.create({ sessionId: 'title-close-window' });
  const session = owner.agent.session;
  await ctx.sessions.flush(session); // Materialize and hold the real lease before the controlled window.
  t.mock.timers.enable({ apis: ['setTimeout'] });
  originalTimer = globalThis.setTimeout;
  globalThis.setTimeout = function (callback, delay, ...args) {
    if (phase === 'lease-close' && delay === 200) closeWindowTimers++;
    return originalTimer(callback, delay, ...args);
  };
  session.append('user/message', createUserMessage({ content: [{ type: 'text', text: 'Summarize this local fixture' }], source: { kind: 'user', rpcId: 'title-close-window' } }), { surfaceOp: 'append' });
  await ctx.sessionTitle.refresh(session); // Settle the real fallback before registering the provider.
  removeProvider = ctx.sessionTitle.register({
    id: 'close-window-fixture', automatic: 'first-prompt',
    async generate(request) {
      atGenerate.resolve(); await releaseGenerate.promise; request.signal.throwIfAborted();
      return { title: 'Late accepted title', messageSeqs: request.messages.map(message => message.seq) };
    },
  });
  ctx.on('session/event', (published, event) => {
    if (published === session && event.type === 'session/title' && event.data.source.kind === 'provider') observedTitle = event;
  });
  titleRun = ctx.sessionTitle.refresh(session);
  titleRun.catch(() => {}); // Cleanup owns settlement, including test timeout.
  await wait(Promise.race([
    atGenerate.promise,
    titleRun.then(() => { throw Error('title refresh settled before entering the provider'); }, error => { throw error; }),
  ]));
  armClose = true;
  closing = owner.dispose(); closing.catch(() => {});
  await wait(Promise.race([
    atLeaseClose.promise,
    closing.then(() => { throw Error('owner disposed without reaching the real lease close gate'); }, error => { throw error; }),
  ]));
  titles.assertActive(); ctx.fiber.assertActive();
  assert(ctx.get('sessionPersistence'), 'global persistence remains installed during the single-agent teardown');
  assert.equal(ctx.sessions.get(session.id), session, 'actual session is still live at lease release');
  assert.equal(ctx.agents.get(session.id), owner.agent, 'the agent registry has not retired early');
  releaseGenerate.resolve();
  const titleOutcome = await wait(titleRun.then(value => ({ value }), error => ({ error })));
  if (observedTitle) assert.equal(titleOutcome.value?.title, 'Late accepted title');
  else {
    assert(titleOutcome.error instanceof Error, 'an unaccepted title must have a concrete closing/cancellation outcome');
    assert.match(titleOutcome.error.message, /^(?:session "title-close-window" is closing|session disposed during title generation)$/);
  }
  releaseLeaseClose.resolve(); await wait(closing);
  assert(leaseActuallyClosed, 'the real lock descriptor was closed');
  successor = await ctx.sessionPersistence.open(session.id, 'write');
  const beforeTimer = await successor.read();
  assert(beforeTimer.events.some(event => event.type === 'user/message' && event.data.source.rpcId === 'title-close-window'), 'close drained the accepted user input');
  assert(beforeTimer.events.some(event => event.type === 'session/title' && event.data.source.kind === 'fallback'), 'close drained the already accepted fallback title');
  assert.equal(ctx.sessions.get(session.id), undefined);
  assert.equal(ctx.agents.get(session.id), undefined);
  const acceptedMissing = observedTitle !== undefined && !beforeTimer.events.some(event => event.seq === observedTitle.seq && event.type === 'session/title');
  phase = 'successor-owned';
  t.mock.timers.tick(200);
  // A pending real JSONL timer is the baseline path under investigation. Await
  // its actual file close, never a sleep or fabricated storage implementation.
  if (closeWindowTimers) await wait(lateWriteClosed.promise);
  // The successor write handle has a primed view. Open a NEW public read
  // handle after the actual append closes, instead of rereading that snapshot.
  const physicalReader = await ctx.sessionPersistence.open(session.id, 'read');
  let afterTimer;
  try { afterTimer = await physicalReader.read(); }
  finally { await physicalReader.close(); }
  const appearedLate = observedTitle !== undefined && afterTimer.events.some(event => event.seq === observedTitle.seq && event.type === 'session/title');
  t.diagnostic(JSON.stringify({ accepted: !!observedTitle, acceptedMissingAtClose: acceptedMissing, closeWindowTimers, lateOpens, appearedLate }));
  assert.equal(acceptedMissing, false, 'close completed without draining an actually accepted, routed title');
  assert.equal(lateOpens, 0, 'old timer wrote after close while a successor held the real write lease');
  phase = 'reopen';
  await successor.close(); successor = undefined;
  owner = await ctx.agentLoop.resume(ctx, { resumeSessionId: session.id });
  assert.notEqual(owner.agent.session, session, 'resume creates a fresh Session instance');
  ctx.sessionTitle.rename(owner.agent.session, 'After reopen');
  await ctx.sessions.flush(owner.agent.session);
  await owner.dispose();
  const reopenedReader = await ctx.sessionPersistence.open(session.id, 'read');
  try {
    const restored = await reopenedReader.read();
    assert(restored.events.some(event => event.type === 'session/title' && event.data.title === 'After reopen'), 'the old cutoff does not stop a new Session');
  } finally { await reopenedReader.close(); }
});
