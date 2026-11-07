// Real services and filesystem. Invoked only by workspace-dispose-error.test.mjs.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { syncBuiltinESMExports } from 'node:module';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { join, resolve, basename, dirname } from 'node:path';
import { pathToFileURL } from 'node:url';
const root = resolve(process.env.WORKSPACE_DISPOSE_FIXTURE);
const load = name => import(pathToFileURL(join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai', name, 'lib/index.js')));
const originalRm = fs.rm, originalMkdtemp = fs.mkdtemp;
const scratchReady = Promise.withResolvers(), snapshotReady = Promise.withResolvers(), observed = Promise.withResolvers();
let ctx, detach, scratch, originalCleanupError, phase = 'setup';
const forks = [], setupWarnings = [];
const onUnhandled = error => observed.resolve({ kind: 'unhandled', error });
process.on('unhandledRejection', onUnhandled);
async function main() {
  const workspace = join(root, 'workspace'); await fs.mkdir(workspace, { recursive: true });
  await promisify(execFile)('git', ['init', '--quiet', workspace]);
  await fs.writeFile(join(workspace, 'own.txt'), 'Only fixture-owned contents.\n');
  fs.mkdtemp = async function (prefix, ...args) {
    const path = await originalMkdtemp.call(this, prefix, ...args);
    if (String(prefix).startsWith(join(root, 'tmp', 'dsh-workspace-changes-'))) {
      assert.equal(scratch, undefined, 'only this fixture session owns a scratch');
      scratch = path; scratchReady.resolve(path);
    }
    return path;
  };
  fs.rm = async function (path, ...args) {
    try {
      const result = await originalRm.call(this, path, ...args);
      if (scratch && dirname(String(path)) === scratch && basename(String(path)).startsWith('index-')) snapshotReady.resolve();
      return result;
    } catch (error) {
      if (phase === 'detach' && String(path) === scratch) originalCleanupError = error;
      throw error; // The actual FS result, not an injected failure.
    }
  };
  syncBuiltinESMExports();
  const { Context } = await load('cordis'); ctx = new Context();
  ctx.logger.exporter({ levels: { default: 3 }, export: ({ type, args }) => {
    const text = args.map(String).join(' ');
    if (type === 'warn' && /^session "workspace-dispose-fixture": session\/disposed listener rejected: /.test(text)) observed.resolve({ kind: 'contained', text });
    else if (type === 'warn' || type === 'error') setupWarnings.push(text);
  } });
  for (const name of ['dsh-session-projection', 'dsh-session', 'dsh-fs-local', 'dsh-subprocess-local']) {
    const fork = ctx.plugin((await load(name)).default, name === 'dsh-fs-local' ? { cwd: workspace } : undefined);
    forks.push(fork); await fork.await();
  }
  const changes = ctx.plugin(await load('dsh-workspace-changes'), {
    timeoutMs: 10000, outputMaxBytes: 1024 * 1024, maxFiles: 20, maxFileBytes: 4096, diffTimeoutMs: 100,
  });
  forks.push(changes); await changes.await();
  const session = ctx.sessions.prepare('workspace-dispose-fixture', { meta: { cwd: workspace } });
  detach = ctx.sessions.enter(session); ctx.sessions.announce(session);
  session.append('turn/start', { turn: 1 });
  await Promise.race([scratchReady.promise, observed.promise.then(result => { throw result.error ?? Error('unexpected observer result during setup'); })]);
  await Promise.race([snapshotReady.promise, observed.promise.then(result => { throw result.error ?? Error('unexpected observer result during setup'); })]);
  assert(scratch.startsWith(join(root, 'tmp') + '/'), 'scratch is plugin-created inside this fixture root');
  const probe = join(scratch, 'permission-probe'); await fs.writeFile(probe, 'owned probe\n');
  await fs.chmod(scratch, 0o500);
  let blocked;
  try { await fs.unlink(probe); } catch (error) { blocked = error; }
  if (!blocked) return { skip: 'this filesystem/user bypasses directory write denial' };
  assert.equal(blocked.code, 'EACCES', 'real permission negative control must be EACCES');
  changes.assertActive(); ctx.fiber.assertActive();
  phase = 'detach'; detach(); detach = undefined;
  assert.equal(ctx.sessions.get(session.id), undefined, 'actual SessionStore detach happened');
  const result = await observed.promise;
  assert.equal(originalCleanupError?.code, 'EACCES', 'the plugin final rm actually failed');
  if (result.kind === 'unhandled') assert.equal(result.error, originalCleanupError, 'the original cleanup rejection escaped');
  else assert(result.text.includes(String(originalCleanupError)), 'the existing observer warning carries that cleanup error');
  return { kind: result.kind, code: originalCleanupError.code, permissionDenied: true, scratchCreatedByPlugin: true, setupWarnings };
}
let report, failure;
try { report = await main(); } catch (error) { failure = error; }
finally {
  phase = 'cleanup';
  if (scratch) await fs.chmod(scratch, 0o700).catch(() => {});
  detach?.();
  fs.rm = originalRm; fs.mkdtemp = originalMkdtemp; syncBuiltinESMExports();
  for (const fork of forks.reverse()) await fork.dispose();
  await ctx?.fiber.dispose();
  if (scratch) await originalRm(scratch, { recursive: true, force: true });
  process.off('unhandledRejection', onUnhandled);
}
if (failure) { console.error(failure); process.exitCode = 1; }
else if (process.send) await new Promise((resolve, reject) => process.send(report, error => error ? reject(error) : resolve()));

if (process.connected) process.disconnect();
