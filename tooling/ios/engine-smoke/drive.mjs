// Drives one real round against the engine running on the iOS Simulator: the same
// script as runtime/ohos/sim/round.mjs (write, edit, read, grep, bash, with approvals)
// against a local fake model, then stops and restarts the engine in the same process.
//
//   node drive.mjs --simulator <udid> --smoke <binary> --frameworks <dir> --runtime <tree> \
//     --work <new dir> --ws <dir holding the ws package>
//
// The Simulator shares this Mac's filesystem and loopback, which is what makes this work.
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import http from 'node:http';
import { appendFileSync, existsSync, mkdirSync, realpathSync, writeFileSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';

const { values } = parseArgs({ options: Object.fromEntries(
  ['simulator', 'smoke', 'frameworks', 'runtime', 'work', 'ws'].map((name) => [name, { type: 'string' }])) });
for (const name of ['simulator', 'smoke', 'frameworks', 'runtime', 'work', 'ws']) {
  if (!values[name]) throw new Error(`--${name} is required`);
}
const here = new URL('.', import.meta.url);
const repo = resolve(new URL('../../..', here).pathname);
const { startFakeModel } = await import(pathToFileURL(join(repo, 'runtime/ohos/sim/fake-model.mjs')));
const { WebSocket } = createRequire(join(resolve(values.ws), 'package.json'))('ws');

const work = resolve(values.work);
mkdirSync(work);
const guest = realpathSync(work) + '/guest';
const dshHome = `${guest}/root/.dsh`;
const workspace = `${guest}/root/workspace`;
const cache = realpathSync(work) + '/cache';
for (const directory of [dshHome, `${guest}/root/.agents`, workspace, cache]) mkdirSync(directory, { recursive: true });

const logFile = join(work, 'engine.log');
const report = { status: 'BLOCKED', stage: 'startup', approvals: 0, restart: 'not-run' };
const fail = (message) => { throw new Error(message); };

const model = await startFakeModel(workspace);
const overlay = join(work, 'model.patch.yml');
writeFileSync(overlay, JSON.stringify([
  { id: 'llm-pi-ai', config: { providers: { 'ohos-fake': {
    api: 'openai-completions', baseURL: model.baseURL, apiKeyEnv: 'DSH_OHOS_TEST_KEY',
    retryPolicy: { mode: 'normal', maxRetries: 0 },
    models: [{ id: 'ohos-script', contextWindow: 32768, maxTokens: 4096, reasoningEfforts: false }],
  } } } },
  { id: 'agent-default-model', config: { provider: 'ohos-fake', model: 'ohos-script' } },
  { id: 'session-title-llm', disabled: true },
]));

const engine = spawn('xcrun', ['simctl', 'spawn', values.simulator, resolve(values.smoke), resolve(values.frameworks),
  resolve(values.runtime), guest, cache], {
  env: { ...process.env, SIMCTL_CHILD_DSH_IOS_SMOKE_PATCH: overlay }, stdio: ['ignore', 'pipe', 'pipe'],
});
let exited = null;
let engineEnded = null;
const readyWaiters = [];
const readies = [];
let tail = [];
let buffered = '';
const noteLine = (line) => {
  appendFileSync(logFile, line + '\n');
  tail.push(line);
  if (tail.length > 120) tail.shift();
};
engine.stderr.on('data', (data) => String(data).split('\n').forEach((line) => line && noteLine('[smoke stderr] ' + line)));
engine.stdout.on('data', (data) => {
  buffered += data;
  const lines = buffered.split('\n');
  buffered = lines.pop();
  for (const line of lines) {
    if (line === '[]' || line === '') continue;
    let rows;
    try { rows = JSON.parse(line); } catch { noteLine('[raw] ' + line); continue; }
    for (const row of Array.isArray(rows) ? rows : [rows]) {
      if (row.kind === 'log') noteLine(`[${row.stream}] ${row.line}`);
      else if (row.kind === 'ready') {
        noteLine('[ready] ' + row.baseUrl);
        readies.push(row);
        for (const waiter of readyWaiters.splice(0)) waiter();
      } else {
        noteLine(JSON.stringify(row));
        if (row.kind === 'exit' || row.kind === 'error' || row.kind === 'fatal') {
          engineEnded = row;
          for (const waiter of readyWaiters.splice(0)) waiter();
        }
      }
    }
  }
});
engine.on('exit', (code, signal) => {
  exited = { code, signal };
  noteLine(`[smoke exited] ${code ?? signal}`);
  for (const waiter of readyWaiters.splice(0)) waiter();
});

async function waitReady(index, ms) {
  const deadline = Date.now() + ms;
  while (readies.length <= index) {
    if (exited) fail(`engine exited before readiness: ${exited.code ?? exited.signal}`);
    if (engineEnded) fail(`engine ended before readiness: ${JSON.stringify(engineEnded)}`);
    if (Date.now() > deadline) fail('engine readiness deadline');
    await Promise.race([new Promise((done) => readyWaiters.push(done)), new Promise((done) => setTimeout(done, 1000))]);
  }
  return readies[index];
}

function exchange(url, { body, cookie } = {}) {
  return new Promise((accept, reject) => {
    const bytes = body === undefined ? undefined : Buffer.from(JSON.stringify(body));
    const req = http.request(url, {
      method: bytes ? 'POST' : 'GET', headers: {
        ...(cookie ? { Cookie: cookie } : {}),
        ...(bytes ? { 'content-type': 'application/json', 'content-length': bytes.length } : {}),
      },
    }, (res) => {
      const chunks = [];
      res.on('data', (data) => chunks.push(data));
      res.on('end', () => accept({ status: res.statusCode, headers: res.headers, text: Buffer.concat(chunks).toString('utf8') }));
      res.on('error', reject);
    });
    req.on('error', reject);
    req.setTimeout(60000, () => req.destroy(new Error('test HTTP timeout')));
    req.end(bytes);
  });
}

async function login(ready) {
  const response = await exchange(`${ready.baseUrl}/?token=${encodeURIComponent(ready.token)}`);
  if (response.status !== 303) fail(`launch token exchange returned ${response.status}`);
  const cookie = response.headers['set-cookie']?.find((item) => item.startsWith('dsh-auth-'))?.split(';')[0];
  if (!cookie) fail('launch exchange did not return a dsh-auth cookie');
  const rpc = async (endpoint, args = {}) => {
    const rpcId = randomUUID();
    const reply = await exchange(new URL(`/api/${endpoint}`, ready.baseUrl), {
      cookie, body: { type: 'client-request', rpcId, method: endpoint, payload: { args } },
    });
    if (reply.status !== 200) fail(`RPC ${endpoint}: HTTP ${reply.status}`);
    const wire = JSON.parse(reply.text);
    if (wire.rpcId !== rpcId || wire.type !== 'server-response') fail(`RPC ${endpoint}: invalid envelope`);
    if (wire.result?.ok !== true) fail(`RPC ${endpoint}: ${wire.result?.error?.code}: ${wire.result?.error?.message}`);
    return wire.result.value;
  };
  return { cookie, rpc };
}

async function round(ready) {
  const { cookie, rpc } = await login(ready);
  const frames = [];
  const waiters = new Set();
  const events = [];
  let clientId;
  let muxError;
  const failMux = (error) => { muxError = error; for (const waiter of [...waiters]) waiter.reject(error); };
  function waitFrame(predicate) {
    if (muxError) return Promise.reject(muxError);
    const found = frames.find(predicate);
    if (found) return Promise.resolve(found);
    return new Promise((accept, reject) => {
      const entry = { predicate, accept: (frame) => { clearTimeout(entry.timer); waiters.delete(entry); accept(frame); } };
      entry.timer = setTimeout(() => { waiters.delete(entry); reject(new Error(`mux deadline at ${report.stage}`)); }, 180000);
      entry.reject = (error) => { clearTimeout(entry.timer); waiters.delete(entry); reject(error); };
      waiters.add(entry);
    });
  }
  const socket = new WebSocket(ready.baseUrl.replace('http:', 'ws:') + '/api/remote.mux', { headers: { Cookie: cookie }, handshakeTimeout: 30000 });
  socket.on('error', failMux);
  socket.on('close', () => failMux(new Error('mux closed')));
  socket.on('message', (bytes) => {
    try {
      const frame = JSON.parse(bytes.toString());
      frames.push(frame);
      if (frame.type === 'error') { failMux(new Error(`mux ${frame.streamId}: ${frame.error?.code}`)); return; }
      const value = frame.value;
      if (value?.type === 'ready') clientId = value.clientId;
      if (value?.type === 'waterfall' && value.event === 'approval/request') {
        report.approvals++;
        rpc('$events/result', { clientId, eventId: value.eventId, outcome: { kind: 'result', value: 'allowed-once' } }).catch(failMux);
      }
      if (value?.type === 'event') events.push(value.event);
      for (const waiter of [...waiters]) if (waiter.predicate(frame)) waiter.accept(frame);
    } catch (error) { failMux(error); }
  });
  await once(socket, 'open', { signal: AbortSignal.timeout(30000) });
  socket.send(JSON.stringify({ type: 'open', streamId: 'host', endpoint: '$events', payload: { args: {} } }));
  await waitFrame((frame) => frame.streamId === 'host' && frame.value?.type === 'ready');
  report.stage = 'session/create';
  const { sessionId } = await rpc('session/create', { request: { cwd: workspace, agentPreset: 'standard' } });
  report.stage = 'session/follow';
  socket.send(JSON.stringify({ type: 'open', streamId: 'session', endpoint: 'session/follow', payload: { args: { request: { address: { kind: 'session', sessionId }, assistantDeltas: true } } } }));
  await waitFrame((frame) => frame.streamId === 'session' && frame.value?.type === 'snapshot');
  report.stage = 'round';
  const before = events.length;
  await rpc('session/prompt', { request: { requestId: randomUUID(), sessionId, mode: 'queue', content: [{ type: 'text', text: 'iOS scripted file, search, shell and approval round.' }] } });
  const end = await waitFrame((frame) => frame.streamId === 'session' && frame.value?.event?.type === 'turn/end');
  const reason = end.value.event.data.reason;
  if (reason?.kind !== 'completed') fail(`turn ended ${reason?.kind}: ${reason?.error?.code ?? ''} ${reason?.error?.message ?? ''}`);
  const results = events.slice(before).filter((event) => event.type === 'tool/result');
  if (results.length !== 5) fail(`expected five tool results, got ${results.length}`);
  const failed = results.findIndex((event) => event.data.message?.isError !== false);
  if (failed >= 0) fail(`tool ${failed} failed: ${JSON.stringify(results[failed].data.message?.content)?.slice(0, 400)}`);
  if (!results[4].data.message.content.some((part) => part.text?.includes('shell-ok'))) fail('bash result missing marker');
  if (await readFile(model.file, 'utf8') !== '修改后内容\n') fail('file side effect did not match the script');
  if (report.approvals < 1) fail('round did not exercise an approval');
  socket.removeAllListeners('close');
  socket.terminate();
}

try {
  const startedAt = Date.now();
  const first = await waitReady(0, 240000);
  engineEnded = null;
  report.readyMs = Date.now() - startedAt;
  await round(first);
  report.status = 'ROUND_PASSED';
  report.stage = 'restart';
  engineEnded = null;
  writeFileSync(`${guest}/restart`, '');
  const restartedAt = Date.now();
  const second = await waitReady(1, 240000);
  report.restartReadyMs = Date.now() - restartedAt;
  const { rpc } = await login(second);
  await rpc('session/create', { request: { cwd: workspace, agentPreset: 'standard' } });
  report.restart = 'passed';
  report.status = 'PASS';
  report.stage = 'complete';
} catch (error) {
  report.error = error.message;
}
if (!exited) {
  writeFileSync(`${guest}/quit`, '');
  await Promise.race([once(engine, 'exit'), new Promise((done) => setTimeout(done, 20000))]);
  if (!exited) engine.kill();
}
await model.close();
report.nativeHost = existsSync(logFile) ? tail : [];
writeFileSync(join(work, 'report.json'), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
process.exit(report.status === 'PASS' ? 0 : 1);
