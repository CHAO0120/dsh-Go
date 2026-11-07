// Real GoalService, AgentFactory, Session and ProjectionRegistry.
// Public Session-event producer seam: no round driver/model is mounted.
// These events model already admitted rounds; they do not test driver admission.
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
const { createUserMessage } = await load('dsh-llm');
const ref = goal => ({ id: goal.id, revision: goal.revision });

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'dsh-goal-cap-checkpoint-'));
  const ctx = new Context(), forks = [];
  let owner;
  t.after(async () => {
    const errors = [];
    try { if (owner) await owner.dispose(); } catch (error) { errors.push(error); }
    for (const fork of forks.reverse()) {
      try { await fork.dispose(); } catch (error) { errors.push(error); }
    }
    try { await ctx.fiber.dispose(); } catch (error) { errors.push(error); }
    try { await rm(root, { recursive: true, force: true }); } catch (error) { errors.push(error); }
    if (errors.length) throw new AggregateError(errors, 'goal fixture cleanup failed');
  });
  async function mount(name, config) {
    const module = await load(name);
    const fork = ctx.plugin(module.default ?? module, config);
    forks.push(fork);
    await fork.await();
  }
  for (const name of ['dsh-session-projection', 'dsh-session', 'dsh-agent', 'dsh-llm', 'dsh-system-prompt', 'dsh-tools', 'dsh-fs-local']) await mount(name);
  await mount('dsh-working-directory', { defaultDirectory: root });
  await persistence(ctx, { root: join(root, 'sessions'), compression: 'none', listConcurrency: 1 });
  await mount('dsh-agent-loop', { agents: [] });
  await mount('dsh-goal');
  owner = await ctx.agents.create({ sessionId: 'goal-cap', cwd: root });
  const agent = owner.agent;
  const created = ctx.goals.create(agent, { objective: 'Synthetic checkpoint regression', maxGoalRounds: 3 });
  for (const round of [1, 2]) {
    agent.session.append('user/message', createUserMessage({
      content: [{ type: 'text', text: `Synthetic admitted goal round ${round}` }],
      source: { kind: 'goal', goalId: created.id, revision: created.revision, round },
    }), { surfaceOp: 'append' });
    assert.equal(ctx.goals.get(agent).roundsStarted, round, 'real goal fold must admit each public event');
  }
  assert.equal(ctx.goals.get(agent).maxGoalRounds, 3, 'both events were admitted before the cap edit');
  return { ctx, agent };
}

for (const cap of [1, 2]) {
  test(`editing two admitted rounds to cap ${cap} preserves checkpoint and exhaustion`, async t => {
    const { ctx, agent } = await fixture(t);
    const edited = ctx.goals.edit(agent, ref(ctx.goals.get(agent)), { maxGoalRounds: cap });
    assert.equal(edited.roundsStarted, 2);
    assert.equal(edited.maxGoalRounds, cap);
    const checkpoint = ctx.sessionProjections.checkpoint(agent.session);
    assert.equal(checkpoint.goal.val.current.roundsStarted, 2);
    assert.equal(checkpoint.goal.val.current.goal.maxGoalRounds, cap);
    const viewed = ctx.sessionProjections.viewCheckpoint(checkpoint, ['goal']);
    // Baseline semantic failure for cap 1: checkpoint exists, but its schema
    // rejects the legitimate edited state and viewCheckpoint omits this key.
    assert.equal(Object.hasOwn(viewed, 'goal'), true, 'legitimate goal checkpoint must remain viewable');
    assert.equal(viewed.goal.roundsStarted, 2);
    assert.equal(viewed.goal.goal.maxGoalRounds, cap);
    const restored = ctx.sessionProjections.restore(checkpoint, agent.session.snapshotEvents(), 0,
      agent.session.header, agent.session.inheritedEventCount);
    assert.equal(restored.snapshot.values.goal.roundsStarted, 2);
    assert.equal(restored.snapshot.values.goal.goal.maxGoalRounds, cap);
    assert.equal(restored.checkpoint.goal.val.current.roundsStarted, 2);

    ctx.goals.disarm(agent); // Reach the budget guard, not the already-armed guard.
    const before = ctx.goals.get(agent), seq = agent.session.seq;
    assert.throws(() => ctx.goals.resume(agent, ref(before)),
      error => error.code === 'GOAL_INVALID_TRANSITION' && error.message.includes('exhausted'));
    assert.equal(agent.session.seq, seq, 'rejected resume must not append an event');
    assert.deepEqual(ctx.goals.get(agent), before, 'rejected resume must preserve the current ref and state');
    const raised = ctx.goals.edit(agent, ref(before), { maxGoalRounds: 3 });
    const resumed = ctx.goals.resume(agent, ref(raised));
    assert.equal(resumed.activation, 'armed');
    assert.equal(resumed.maxGoalRounds, 3);
    assert.equal(resumed.roundsStarted, 2, 'raising the cap must not reset admitted history');
  });
}
