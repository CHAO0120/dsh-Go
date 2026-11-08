import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createServer } from 'node:http';
import { once } from 'node:events';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { endpoint, cloneUrl, decodeStatus, retirementConfirmed } from '../linux-device-measure.mjs';

const execute = promisify(execFile);
const script = fileURLToPath(new URL('../linux-device-measure.mjs', import.meta.url));
const TOKEN = 'fixture-launch-token-930';
const COOKIE = 'dsh-auth-fixture=fixture.session';
const GH_TOKEN = 'fixture-only-gh-secret';
const inheritedSecret = 'unrelated-parent-gh-token';
const stream = (bytes = Buffer.alloc(0), total = bytes.length) => ({ encoding: 'base64', data: bytes.toString('base64'),
  totalBytes: total, retainedBytes: bytes.length, truncated: total > bytes.length });
const snapshot = extra => ({ v: 1, instanceId: 'fixture-instance', attemptId: null, state: 'disabled', enabled: false,
  admission: false, guestOpened: false, ownerRetained: false, workspaceLease: false, restartRequired: false,
  shutdownComplete: false, nextRequestId: 1, ownerState: null, backendState: null, progress: null, lastErrorCode: null,
  job: null, retirement: null, ...extra });
const retired = extra => ({ resourcesRetired: true, filesRemoved: false, dataRetained: true, ownerQuarantined: true,
  native: { joined: true, retirementError: false, apiResult: -4 }, releaseErrorCode: null, ...extra });
const reply = (res, code, body) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };

// This is deliberately a control/guest test double over real local HTTP.
// It does not invoke git, gh, a VM, SDK, external service or an account.
async function fixture(options = {}) {
  let state = snapshot(options.initial), installationPolls = 0, jobPolls = 0, shutdownPolls = 0;
  let current, lastBody, dropping = !!options.dropFirstRun, replace = false, raced = false;
  const posts = [], requests = [], effects = new Map();
  const server = createServer(async (req, res) => {
    if (req.url === '/?token=' + TOKEN) {
      requests.push({ method: req.method, kind: 'login' });
      res.writeHead(303, { 'set-cookie': COOKIE + '; Path=/; HttpOnly', location: options.redirect ?? '/' }); res.end(); return;
    }
    requests.push({ method: req.method, kind: 'control' });
    assert.equal(req.url, '/dsh-go/v1/linux'); assert.equal(req.headers.cookie, COOKIE);
    if (req.method === 'GET') {
      if (replace) { state.instanceId = 'replacement-instance'; state.attemptId = 'replacement-attempt'; }
      if (options.overlong) { res.end('X'.repeat(65537)); return; }
      if (state.state === 'installing' && ++installationPolls >= 2) {
        state.state = 'enabled'; state.admission = true; state.guestOpened = true;
        state.ownerState = 'active'; state.backendState = 'opened'; state.progress = { stage: 'opened', done: 1, total: 1, step: null };
      } else if (options.contradictoryAdmission && state.state === 'enabled' && state.job === null) {
        state.state = 'unknown'; // A contradictory peer must not authorize a run.
      }
      if (options.raceBeforeCancel && current === 'cancel') {
        // The accepted job ended, and another client used the next ID before
        // the measurement client could send its owner-wide disable request.
        current = 'foreign';
        state.job = { id: state.nextRequestId++, state: 'running', started: true, cancelRequested: false,
          outcome: null, errorCode: null, stdout: stream(), stderr: stream() };
      }
      if (state.job?.state === 'running' && current !== 'cancel' && current !== 'foreign' && ++jobPolls >= 2) {
        state.job.state = 'settled'; state.job.outcome = { exitCode: 0, signal: null, cancelled: false };
      }
      if (state.state === 'disabling') {
        state.state = 'disabled'; state.job.state = 'settled';
        state.job.outcome = { exitCode: null, signal: 'SIGKILL', cancelled: true, requestedSignal: 'SIGTERM' };
      }
      if (state.state === 'stopping' && ++shutdownPolls >= 2) {
        state.state = state.job?.state === 'unknown' ? 'unknown' : 'stopped';
        state.shutdownComplete = !options.noJoin;
        state.retirement = options.noJoin ? retired({ resourcesRetired: false,
          native: { joined: false, retirementError: null, apiResult: null } }) : retired();
      }
      reply(res, 200, state); return;
    }
    const chunks = []; for await (const bytes of req) chunks.push(bytes);
    const body = JSON.parse(Buffer.concat(chunks).toString('utf8')); posts.push(body);
    if (body.instanceId !== state.instanceId || body.attemptId !== state.attemptId) {
      reply(res, 409, { v: 1, error: { code: 'ERR_OHOS_LINUX_STALE' }, status: state }); return;
    }
    if (body.action === 'setEnabled') {
      state.enabled = body.enabled; state.admission = false;
      if (body.enabled) {
        state.attemptId ??= 'fixture-attempt'; state.state = 'installing'; state.ownerRetained = true;
        state.progress = { stage: 'download', done: 0, total: 100, step: null };
      } else { state.state = 'disabling'; if (state.job) state.job.cancelRequested = true; }
    } else if (body.action === 'runPrivateGuest') {
      if (options.raceOnFirstRun && !raced) {
        raced = true; current = 'foreign'; state.nextRequestId++;
        state.job = { id: body.requestId, state: 'running', started: true, cancelRequested: false, outcome: null,
          errorCode: null, stdout: stream(), stderr: stream() };
        reply(res, 409, { v: 1, error: { code: 'ERR_OHOS_LINUX_REQUEST_REUSED' }, status: state }); return;
      }
      if (body.requestId === state.job?.id) {
        assert.equal(JSON.stringify(body), lastBody, 'the client must retry exactly the same request');
        reply(res, 202, state); return;
      }
      assert.equal(body.requestId, state.nextRequestId); assert.equal(body.cwd, '/workspace');
      assert.equal(body.env.GH_TOKEN, body.argv[0] === 'gh' && body.argv[1] === 'pr' ? GH_TOKEN : undefined);
      lastBody = JSON.stringify(body); effects.set(body.requestId, (effects.get(body.requestId) ?? 0) + 1);
      state.nextRequestId++; jobPolls = 0; current = 'normal'; let stdout = '';
      if (body.argv[0] === 'gh' && body.argv[1] === '--version') stdout = 'gh version 2.97.0 (2026-10-14)\n';
      else if (body.argv[0] === 'python3' && body.argv[1] === '--version') stdout = 'Python 3.14.10\n';
      else if (body.argv[0] === 'python3' && body.argv.includes('print(1)')) stdout = '1\n';
      else if (body.argv[0] === 'rg' && body.argv[1] === '--version') stdout = 'ripgrep 15.1.0\n';
      else if (body.argv[0] === 'rg') { assert.equal(body.stdin, 'alpha\nbeta needle\n'); stdout = '2:beta needle\n'; }
      else if (body.argv[0] === 'git' && body.argv[1] === '--version') stdout = 'git version 2.54.0\n';
      else if (body.argv[0] === 'sh') {
        assert.doesNotMatch(body.argv[2], /\b(?:commit|commit-tree|push)\b/);
        assert.match(body.argv[2], /git init --bare/); stdout = 'DSH_EMPTY_CLONE_OK\n';
      } else if (body.argv[0] === 'git' && body.argv[1] === 'clone') {
        assert.equal(body.argv[body.argv.indexOf('--') + 1], 'https://example.invalid/small.git');
        stdout = '';
      } else if (body.argv[0] === 'git' && body.argv.includes('rev-parse')) stdout = 'a'.repeat(40) + '\n';
      else if (body.argv[0] === 'gh' && body.argv[1] === 'pr') {
        assert.equal(body.argv[body.argv.indexOf('--repo') + 1], 'fixture-owner/fixture-repo'); stdout = '[]\n';
      } else if (body.argv[0] === 'python3' && body.argv[1] === '-u') { current = 'cancel'; stdout = 'DSH_CANCEL_READY\n'; }
      else throw new Error('unrecognized fixture request');
      state.job = { id: body.requestId, state: 'running', started: true, cancelRequested: false, outcome: null,
        errorCode: null, stdout: stream(Buffer.from(stdout)), stderr: stream() };
      if (options.unknownOnPython && body.argv.includes('print(1)')) {
        state.state = 'unknown'; state.admission = false; state.backendState = 'quarantined';
        state.job.state = 'unknown'; state.job.errorCode = 'ERR_OHOS_LINUX_UNKNOWN';
      }
      if (dropping) { dropping = false; replace = !!options.replaceAfterDrop; res.destroy(); return; }
    } else if (body.action === 'shutdown') {
      state.state = 'stopping'; state.enabled = false; state.admission = false;
    } else throw new Error('unexpected action');
    reply(res, 202, state);
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  return { url: `http://127.0.0.1:${server.address().port}`, posts, requests, effects,
    close: async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); } };
}

async function run(fixture, extra = [], environment = {}) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'linux-device-measure-'));
  const token = path.join(root, 'token'); await fs.writeFile(token, TOKEN + '\n', { mode: 0o600 });
  const env = path.join(root, 'guest-env.json'); await fs.writeFile(env, JSON.stringify({ GH_TOKEN }), { mode: 0o600 });
  const out = path.join(root, 'result');
  const args = [script, '--base-url', fixture.url, '--token-file', token, '--out', out, '--poll-ms', '10',
    '--request-timeout-ms', '250', '--install-timeout-ms', '500', '--job-timeout-ms', '500', '--shutdown-timeout-ms', '120',
    ...extra.map(value => value === '@ENV@' ? env : value)];
  let result;
  try { result = { code: 0, ...await execute(process.execPath, args, { env: { ...process.env, GH_TOKEN: inheritedSecret, ...environment }, timeout: 10000 }) }; }
  catch (error) { result = { code: error.code, stdout: error.stdout, stderr: error.stderr }; }
  let summary = null;
  try { summary = JSON.parse(await fs.readFile(path.join(out, 'SUMMARY.json'), 'utf8')); } catch { /* rejected arguments create no result directory */ }
  return { ...result, root, out, summary, cleanup: () => fs.rm(root, { recursive: true, force: true }) };
}

async function files(directory) {
  const result = [];
  for (const entry of await fs.readdir(directory, { withFileTypes: true })) {
    const name = path.join(directory, entry.name);
    if (entry.isDirectory()) result.push(...await files(name)); else result.push(name);
  }
  return result;
}

test('only exact loopback control URLs and credential-free HTTPS clone URLs are accepted', () => {
  assert.equal(endpoint('http://127.0.0.1:12345/').port, 12345);
  for (const value of ['https://127.0.0.1:80', 'http://localhost:80', 'http://127.0.0.1:0', 'http://127.0.0.1:65536',
    'http://127.0.0.1:80/path', 'http://127.0.0.1:80?token=x', 'http://u@127.0.0.1:80', 'http://2130706433:80']) {
    assert.throws(() => endpoint(value), { code: 'ERR_MEASURE_ENDPOINT' });
  }
  assert.equal(cloneUrl('https://example.invalid/repo.git'), 'https://example.invalid/repo.git');
  for (const value of ['http://example.invalid/repo', 'file:///repo', 'https://u:p@example.invalid/repo',
    'https://@example.invalid/repo', 'https://example.invalid/repo?x=y', 'https://example.invalid/repo?', 'https://example.invalid/repo#',
    'https://example.invalid/a\n']) assert.throws(() => cloneUrl(value), { code: 'ERR_MEASURE_CLONE_URL' });
});

test('real CLI/HTTP retries the same job identity and keeps credentials out of evidence', async () => {
  const server = await fixture({ dropFirstRun: true }); let result;
  try {
    result = await run(server, ['--gh-pr-list', '--gh-repo', 'fixture-owner/fixture-repo', '--env-file', '@ENV@',
      '--clone-url', 'https://example.invalid/small.git']);
    assert.equal(result.code, 0, result.stderr + result.stdout); assert.equal(result.summary.status, 'PASS_SCOPED');
    assert.equal(result.summary.shutdownConfirmed, true); assert.ok(result.summary.cases.every(row => row.status === 'PASS'));
    const runs = server.posts.filter(row => row.action === 'runPrivateGuest');
    assert.equal(runs[0].requestId, runs[1].requestId); assert.deepEqual(runs[0], runs[1]);
    assert.ok([...server.effects.values()].every(count => count === 1));
    assert.equal(server.posts.filter(row => row.action === 'shutdown').length, 1);
    assert.equal(result.summary.finalStatus.retirement.filesRemoved, false);
    assert.equal(result.summary.finalStatus.retirement.dataRetained, true);
    assert.equal(result.summary.cancellation.cancelRequested, true);
    const eventLines = (await fs.readFile(path.join(result.out, 'events.jsonl'), 'utf8')).trim().split('\n').map(JSON.parse);
    assert.ok(eventLines.some(row => row.kind === 'run-unconfirmed'));
    assert.ok(eventLines.some(row => row.kind === 'status' && row.status.progress?.stage === 'download'));
    for (const file of await files(result.out)) {
      const text = (await fs.readFile(file)).toString('utf8');
      for (const secret of [TOKEN, COOKIE, GH_TOKEN, inheritedSecret]) assert.ok(!text.includes(secret), path.basename(file));
      assert.equal((await fs.stat(file)).mode & 0o777, 0o600);
    }
    for (const secret of [TOKEN, COOKIE, GH_TOKEN, inheritedSecret]) assert.ok(!(result.stdout + result.stderr).includes(secret));
  } finally { await server.close(); await result?.cleanup(); }
});

test('default suite does no account or remote clone request and declares its local scope', async () => {
  const server = await fixture(); let result;
  try {
    result = await run(server, ['--env-file', '@ENV@']);
    assert.equal(result.code, 0, result.stdout + result.stderr); assert.equal(result.summary.status, 'PASS_LOCAL_ONLY');
    assert.equal(result.summary.cases.find(row => row.label === 'gh-pr-list').status, 'NOT_RUN');
    assert.equal(result.summary.cases.find(row => row.label === 'git-remote-clone').status, 'NOT_RUN');
    assert.ok(!server.posts.some(row => row.argv?.[0] === 'gh' && row.argv[1] === 'pr'));
    assert.ok(!server.posts.some(row => row.argv?.[0] === 'git' && row.argv[1] === 'clone'));
  } finally { await server.close(); await result?.cleanup(); }
});

test('observation stores exact non-UTF8 binary tails and never follows redirects or inherited proxies', async () => {
  const binary = Buffer.from([0, 255, 254, 65]); let trapCalls = 0;
  const trap = createServer((_req, res) => { trapCalls++; res.end(); }); trap.listen(0, '127.0.0.1'); await once(trap, 'listening');
  const foreign = `http://127.0.0.1:${trap.address().port}`;
  const server = await fixture({ redirect: foreign + '/unexpected', initial: { state: 'enabled', enabled: true, guestOpened: true,
    admission: true, attemptId: 'fixture-attempt', ownerRetained: true, ownerState: 'active', backendState: 'opened', nextRequestId: 2,
    job: { id: 1, state: 'settled', started: true, cancelRequested: false, outcome: { exitCode: 0, signal: null, cancelled: false },
      errorCode: null, stdout: stream(binary, 1000), stderr: stream() } } }); let result;
  try {
    result = await run(server, ['--observe-only'], { HTTP_PROXY: foreign, HTTPS_PROXY: foreign, ALL_PROXY: foreign, NODE_USE_ENV_PROXY: '1' });
    assert.equal(result.code, 0, result.stdout + result.stderr); assert.equal(result.summary.status, 'OBSERVED_ONLY');
    assert.equal(server.posts.length, 0); assert.equal(trapCalls, 0);
    const tail = result.summary.finalStatus.job.stdout;
    assert.deepEqual(await fs.readFile(path.join(result.out, tail.file)), binary);
    assert.equal(tail.startOffset, 996); assert.equal(tail.truncated, true); assert.equal(tail.totalBytes, 1000);
  } finally { await server.close(); trap.closeAllConnections(); await new Promise(resolve => trap.close(resolve)); await result?.cleanup(); }
});

test('UNKNOWN and unconfirmed native retirement remain unresolved, never exit-code-zero success', async () => {
  const server = await fixture({ unknownOnPython: true, noJoin: true }); let result;
  try {
    result = await run(server);
    assert.equal(result.code, 2); assert.equal(result.summary.status, 'UNKNOWN');
    assert.equal(result.summary.shutdownConfirmed, false); assert.equal(result.summary.finalStatus.job.outcome, null);
    assert.equal(result.summary.finalStatus.retirement.native.joined, false);
    assert.ok(!server.posts.some(row => row.argv?.[0] === 'rg'));
  } finally { await server.close(); await result?.cleanup(); }
});

test('a changed runtime identity never receives a retried run or shutdown for the previous instance', async () => {
  const server = await fixture({ dropFirstRun: true, replaceAfterDrop: true }); let result;
  try {
    result = await run(server);
    assert.equal(result.code, 2); assert.equal(result.summary.shutdownConfirmed, false);
    assert.equal(server.posts.filter(row => row.action === 'runPrivateGuest').length, 1);
    assert.equal(server.posts.filter(row => row.action === 'shutdown').length, 0);
    assert.ok(result.summary.errors.some(row => row.code === 'ERR_MEASURE_STALE'));
  } finally { await server.close(); await result?.cleanup(); }
});

test('an existing active job is observed and preserved without taking over or shutting it down', async () => {
  const server = await fixture({ initial: { state: 'enabled', enabled: true, admission: true, guestOpened: true,
    attemptId: 'fixture-attempt', nextRequestId: 2, job: { id: 1, state: 'unknown', started: true, cancelRequested: false,
      outcome: null, errorCode: 'ERR_OHOS_LINUX_UNKNOWN', stdout: stream(), stderr: stream() } } }); let result;
  try {
    result = await run(server);
    assert.equal(result.code, 2); assert.equal(server.posts.length, 0);
    assert.ok(result.summary.errors.some(row => row.code === 'ERR_MEASURE_EXISTING_JOB'));
  } finally { await server.close(); await result?.cleanup(); }
});

test('a second client winning the ID after initial GET is not stopped by this client cleanup', async () => {
  const server = await fixture({ raceOnFirstRun: true }); let result;
  try {
    result = await run(server);
    assert.equal(result.code, 2);
    assert.equal(server.posts.filter(row => row.action === 'runPrivateGuest').length, 1);
    assert.equal(server.posts.filter(row => row.action === 'shutdown').length, 0);
    assert.ok(!server.posts.some(row => row.action === 'setEnabled' && row.enabled === false));
    assert.equal(result.summary.shutdownStatus, 'UNCONFIRMED_FOREIGN_JOB');
    assert.equal(result.summary.shutdownConfirmed, false);
    assert.equal(result.summary.finalStatus.job.state, 'running');
  } finally { await server.close(); await result?.cleanup(); }
});

test('a different observed job before cancellation receives neither off nor shutdown', async () => {
  const server = await fixture({ raceBeforeCancel: true }); let result;
  try {
    result = await run(server);
    assert.equal(result.code, 2);
    assert.equal(server.posts.filter(row => row.action === 'shutdown').length, 0);
    assert.ok(!server.posts.some(row => row.action === 'setEnabled' && row.enabled === false));
    assert.equal(result.summary.shutdownStatus, 'UNCONFIRMED_FOREIGN_JOB');
    assert.equal(result.summary.cases.at(-1).cancellationRequestedByClient, false);
    assert.equal(result.summary.finalStatus.job.state, 'running');
  } finally { await server.close(); await result?.cleanup(); }
});

test('an unknown state with contradictory admission true does not authorize any run', async () => {
  const server = await fixture({ contradictoryAdmission: true }); let result;
  try {
    result = await run(server);
    assert.equal(result.code, 2);
    assert.equal(server.posts.filter(row => row.action === 'runPrivateGuest').length, 0);
    assert.ok(result.summary.errors.some(row => row.code === 'ERR_MEASURE_ADMISSION'));
  } finally { await server.close(); await result?.cleanup(); }
});

test('retirement projection requires actual joined true and error false; raw output decoding is strict', () => {
  const valid = snapshot({ shutdownComplete: true, retirement: retired() }); assert.equal(retirementConfirmed(decodeStatus(valid)), true);
  for (const native of [{ joined: false, retirementError: false, apiResult: 0 }, { joined: true, retirementError: null, apiResult: null },
    { joined: true, retirementError: true, apiResult: -8 }]) assert.equal(retirementConfirmed(decodeStatus(snapshot({ shutdownComplete: true, retirement: retired({ native }) }))), false);
  const invalid = snapshot({ job: { id: 1, state: 'settled', started: true, cancelRequested: false,
    outcome: { exitCode: 0, signal: null, cancelled: false }, errorCode: null,
    stdout: { encoding: 'base64', data: '/w=', totalBytes: 1, retainedBytes: 1, truncated: false }, stderr: stream() } });
  assert.throws(() => decodeStatus(invalid), { code: 'ERR_MEASURE_OUTPUT_PROTOCOL' });
});

test('PR opt-in without an explicit repo/env and overlong responses fail without further operations', async () => {
  const server = await fixture({ overlong: true }); let missing, oversized;
  try {
    missing = await run(server, ['--gh-pr-list']);
    assert.equal(missing.code, 2); assert.equal(server.requests.length, 0);
    oversized = await run(server, ['--observe-only']);
    assert.equal(oversized.code, 2); assert.equal(server.posts.length, 0);
    assert.ok(oversized.summary.errors.some(row => row.code === 'ERR_MEASURE_RESPONSE_LIMIT'));
  } finally { await server.close(); await missing?.cleanup(); await oversized?.cleanup(); }
});
