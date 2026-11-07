// Real default spawn provider, AgentFactory, inbox/maintenance lifecycle and JSONL.
// No model provider, fake Agent, internal-set mutation, timer or network call.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
if (!process.env.DSH_PREFIX) throw Error('Set DSH_PREFIX to an isolated patched runtime');
const load = name => import(pathToFileURL(join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai', name, 'lib/index.js')));
const { Context } = await load('cordis');
const { apply: persistence } = await load('dsh-session-persistence-jsonl');

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'dsh-subagent-owner-'));
  const ctx = new Context(), forks = [], gates = new Map(), errors = [];
  let owner;
  t.after(async () => {
    try {
      if (owner) {
        try { await ctx.subagents?.drainChildren(owner.agent, ['child-a', 'child-b']); }
        finally { await owner.dispose(); }
      }
    } finally {
      try { for (const fork of forks.reverse()) await fork.dispose(); }
      finally { try { await ctx.fiber.dispose(); } finally { await rm(root, { recursive: true, force: true }); } }
    }
  });
  async function mount(name, config) {
    const module = await load(name);
    const fork = ctx.plugin(module.default ?? module, config);
    forks.push(fork); await fork.await();
  }
  for (const name of ['dsh-session-projection', 'dsh-session', 'dsh-agent', 'dsh-llm', 'dsh-system-prompt', 'dsh-tools', 'dsh-fs-local']) await mount(name);
  await mount('dsh-working-directory', { defaultDirectory: root });
  await persistence(ctx, { root: join(root, 'sessions'), compression: 'none', listConcurrency: 1 });
  await mount('dsh-agent-loop', { agents: [] });
  await mount('dsh-subagent', { maxDepth: 4, maxActiveSubagents: 8 });
  await mount('dsh-subagent-spawn-in-process', { providerName: 'spawn' });
  await mount('dsh-tool-subagent-control');
  // This real synchronous observer runs between inbox.splice and wakeDriver.
  // Capture throws/rejections explicitly: the production observer emitter contains them.
  ctx.on('agent/inbox/inserted', ({ agent }) => {
    if (!['child-a', 'child-b', 'child-c'].includes(agent.id) || gates.has(agent.id)) return;
    try {
      assert.equal(agent.phase.kind, 'idle', 'first input must arrive after factory maintenance');
      const gate = { agent, signal: undefined, work: undefined };
      gates.set(agent.id, gate);
      gate.work = agent.runMaintenance(signal => {
        gate.signal = signal;
        return new Promise(resolve => {
          if (signal.aborted) resolve();
          else signal.addEventListener('abort', resolve, { once: true });
        });
      });
      gate.work.catch(error => errors.push(error));
    } catch (error) { errors.push(error); }
  });
  owner = await ctx.agents.create({ sessionId: 'parent', cwd: root });
  async function start(parent, id) {
    const receipt = await ctx.subagents.startActivation({
      provider: 'spawn', childId: id, label: id,
      request: { parent, cwd: root, prompt: [{ type: 'text', text: 'synthetic pending input' }], maxDepth: 4 },
      signal: new AbortController().signal,
      // Keep settlement output on the public receipt, so teardown cannot wake P.
      delivery: 'caller',
    });
    assert.deepEqual(errors, [], 'setup observer must not fail');
    const gate = gates.get(id);
    assert.ok(gate?.signal, 'real first-input maintenance gate must be entered');
    assert.equal(gate.signal.aborted, false);
    assert.equal(gate.agent.phase.kind, 'maintenance');
    assert.equal(ctx.agents.get(id), gate.agent);
    assert.equal(gate.agent.session.header.parentSession, parent.id);
    return { receipt, ...gate };
  }
  return { ctx, parent: owner.agent, start, errors };
}
const content = [{ type: 'text', text: 'synthetic followup' }];

test('rejected sibling delivery cannot make that sibling owned by the sender', async t => {
  const f = await fixture(t);
  const a = await f.start(f.parent, 'child-a'), b = await f.start(f.parent, 'child-b');
  const beforeB = b.agent.inbox.nextTurn.map(message => message.id);
  await assert.rejects(f.ctx.subagents.sendMessage(a.agent, b.agent.id, content, { signal: new AbortController().signal }),
    error => error.code === 'UNAUTHORIZED' && error.message.includes('belongs to another parent session'));
  assert.deepEqual(b.agent.inbox.nextTurn.map(message => message.id), beforeB, 'rejected input was not delivered');
  await f.ctx.subagents.drainChildren(f.parent, [a.agent.id]);
  assert.equal(a.signal.aborted, true, 'selected A was actually retired');
  assert.equal(f.ctx.agents.get(a.agent.id), undefined);
  assert.equal(b.signal.aborted, false, 'rejected send must not authorize later cancellation of B');
  assert.equal(f.ctx.agents.get(b.agent.id), b.agent);
  assert.deepEqual(b.agent.inbox.nextTurn.map(message => message.id), beforeB);
  assert.deepEqual(f.errors, []);
});

test('accepted direct-child delivery retains real ownership through parent disposal', async t => {
  const f = await fixture(t);
  const a = await f.start(f.parent, 'child-a'), b = await f.start(f.parent, 'child-b');
  const c = await f.start(a.agent, 'child-c');
  const id = await f.ctx.subagents.sendMessage(a.agent, c.agent.id, content, { signal: new AbortController().signal });
  assert.ok(c.agent.inbox.nextStep.some(message => message.id === id));
  await f.ctx.subagents.drainChildren(f.parent, [a.agent.id]);
  assert.equal(a.signal.aborted, true);
  assert.equal(c.signal.aborted, true, 'the actual direct child must still be retired with A');
  assert.equal(f.ctx.agents.get(c.agent.id), undefined);
  assert.equal(b.signal.aborted, false);
  assert.equal(f.ctx.agents.get(b.agent.id), b.agent);
  assert.deepEqual(f.errors, []);
});
