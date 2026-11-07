// Drives real tool and lifecycle rounds on the iOS Simulator: the same
// five tools as runtime/ohos/sim/round.mjs, then Node Worker, git, rg, 2 MiB output,
// cancellation, stop during a Worker, persisted sessions and another round after restart.
//
//   node drive.mjs --simulator <udid> --smoke <binary> --frameworks <dir> --runtime <tree> \
//     --work <new dir> --ws <dir holding the ws package>
//
// The Simulator shares this Mac's filesystem and loopback, which is what makes this work.
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import http from 'node:http';
import { appendFileSync, cpSync, existsSync, mkdirSync, realpathSync, writeFileSync } from 'node:fs';
import { readFile, stat, rm } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { startGuestModel } from './guest-model.mjs';
import assert from 'node:assert/strict';
import {verifyApproval,verifyAudit} from './guest-assertions.mjs';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';

const { values } = parseArgs({ options: { ...Object.fromEntries(
  ['simulator', 'smoke', 'frameworks', 'runtime', 'work', 'ws', 'rootfs'].map((name) => [name, { type: 'string' }])),
  direct: { type: 'boolean', default: false },
} });
for (const name of [...(values.direct ? [] : ['simulator']), 'smoke', 'frameworks', 'runtime', 'work', 'ws', 'rootfs']) {
  if (!values[name]) throw new Error(`--${name} is required`);
}
const repo = fileURLToPath(new URL('../../..', import.meta.url));
const { WebSocket } = createRequire(join(resolve(values.ws), 'package.json'))('ws');

const work = resolve(values.work);
mkdirSync(work);
const guest = realpathSync(work) + '/guest';
const dshHome = `${guest}/root/.dsh`;
const workspace = `${guest}/root/workspace`;
const cache = realpathSync(work) + '/cache';
for (const directory of [dshHome, `${guest}/root/.agents`, workspace, cache]) mkdirSync(directory, { recursive: true });

const logFile = join(work, 'engine.log');
const report = { status: 'BLOCKED', stage: 'startup', approvals: 0, restart: 'not-run', eventTypes: [], scenarios: [] };
const fail = (message) => { throw new Error(message); };

const model = await startGuestModel(workspace);
// Trusted test host only: rootfs was published by the production Swift installer.
const rootfs = realpathSync(values.rootfs);
const marker = JSON.parse(await readFile(join(rootfs, 'installed.json'), 'utf8'));
assert.equal(marker.version, '3.24.4');
assert.equal(marker.archiveSHA256, '4b14c18f7e90a063b61462ea1462a5732c154bf6adad594974fe6487cd98a8de');
for (const name of ['data', 'meta.db']) assert.ok(existsSync(join(rootfs, name)));
const guestTemporary=join(work,'guest-tmp');mkdirSync(guestTemporary,{mode:0o700});
const snapshot = join(work, 'guest-config.json');
writeFileSync(snapshot, JSON.stringify({ installed: true, root: rootfs, temporaryRoot: guestTemporary,
  addon: join(realpathSync(values.frameworks), 'DshGuestBridge.framework/DshGuestBridge'),
  protectedPaths: [dshHome, `${guest}/root/.agents`, cache, rootfs, realpathSync(values.runtime)],
  metadata: {v:1,source:'ios-native-owner',state:'ready',installed:'present',available:true,enforcement:'partial',python:'unknown'}
}));

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

const smokeArgs = [resolve(values.frameworks), resolve(values.runtime), guest, cache, snapshot];
const engine = spawn(values.direct ? resolve(values.smoke) : 'xcrun', values.direct ? smokeArgs :
  ['simctl', 'spawn', values.simulator, resolve(values.smoke), ...smokeArgs], {
  env: {
    ...process.env,
    DSH_IOS_SMOKE_PATCH: overlay,
    SIMCTL_CHILD_DSH_IOS_SMOKE_PATCH: overlay,
  },
  stdio: ['ignore', 'pipe', 'pipe'],
});
let exited = null;
let engineEnded = null;
let restarting = false;
const readyWaiters = [];
const readies = [];
let tail = [];
let buffered = '';
const repeats = new Map();
const noteLine = (line) => {
  line = line.replace(/([?&]token=)[^\s]+/gu, '$1<redacted>');
  appendFileSync(logFile, line + '\n');
  // A warning repeated thousands of times would push the cause out of the tail.
  const key = line.replace(/\d+/g, '#');
  const seen = (repeats.get(key) ?? 0) + 1;
  repeats.set(key, seen);
  if (seen > 3) {
    if (seen % 1000 === 0) tail.push(`[seen ${seen} times] ${line}`);
    return;
  }
  tail.push(line);
  if (tail.length > 200) tail.shift();
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
        // The one exit a restart asks for isn't the engine ending by itself.
        if (row.kind === 'exit' && restarting) restarting = false;
        else if (row.kind === 'exit' || row.kind === 'error' || row.kind === 'fatal') {
          engineEnded = row;
          for (const waiter of readyWaiters.splice(0)) waiter();
        }
      }
    }
  }
});
engine.on('error', (error) => {
  exited = { error: error.message };
  for (const waiter of readyWaiters.splice(0)) waiter();
});
engine.on('exit', (code, signal) => {
  exited = { code, signal };
  noteLine(`[smoke exited] ${code ?? signal}`);
  for (const waiter of readyWaiters.splice(0)) waiter();
});

async function waitReady(index, ms) {
  const deadline = Date.now() + ms;
  while (readies.length <= index) {
    if (exited) fail(`engine exited before readiness: ${exited.error ?? exited.code ?? exited.signal}`);
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

async function round(ready, mode, reuse) {
  const {cookie,rpc}=await login(ready), frames=[], events=[], waiters=new Set();
  let clientId, sessionId, muxError, approval;
  const failMux=error=>{muxError=error;for(const w of [...waiters])w.reject(error);};
  function waitFrame(predicate) {
    if(muxError)return Promise.reject(muxError);
    const found=frames.find(predicate);if(found)return Promise.resolve(found);
    return new Promise((resolve,reject)=>{
      const w={predicate,accept(f){clearTimeout(w.timer);waiters.delete(w);resolve(f);},reject(e){clearTimeout(w.timer);waiters.delete(w);reject(e);}};
      w.timer=setTimeout(()=>w.reject(new Error('guest mux timeout '+mode)),120000);waiters.add(w);
    });
  }
  const socket=new WebSocket(ready.baseUrl.replace('http:','ws:')+'/api/remote.mux',{headers:{Cookie:cookie},handshakeTimeout:30000});
  socket.on('error',failMux);socket.on('close',()=>failMux(new Error('guest mux closed')));
  socket.on('message',bytes=>{
    try {
      const frame=JSON.parse(String(bytes));frames.push(frame);
      if(frame.type==='error')throw new Error('mux error '+frame.error?.code);
      if(frame.value?.type==='event')events.push(frame.value.event);
      for(const w of [...waiters])if(w.predicate(frame))w.accept(frame);
    }catch(e){failMux(e);}
  });
  try {
    await once(socket,'open',{signal:AbortSignal.timeout(30000)});
    socket.send(JSON.stringify({type:'open',streamId:'host',endpoint:'$events',payload:{args:{}}}));
    clientId=(await waitFrame(f=>f.streamId==='host'&&f.value?.type==='ready')).value.clientId;
    sessionId=reuse??(await rpc('session/create',{request:{cwd:workspace,agentPreset:'standard'}})).sessionId;
    socket.send(JSON.stringify({type:'open',streamId:'session',endpoint:'session/follow',payload:{args:{request:{address:{kind:'session',sessionId},assistantDeltas:true}}}}));
    await waitFrame(f=>f.streamId==='session'&&f.value?.type==='snapshot');
    report.stage=mode;
    const receipt=await rpc('session/prompt',{request:{requestId:randomUUID(),sessionId,mode:'queue',content:[{type:'text',text:`[DSH_IOS_SMOKE:${mode}] Run the one deterministic guest fixture tool.`}]}});
    assert.equal(receipt.accepted,true);
    approval=(await waitFrame(f=>f.value?.type==='waterfall'&&f.value.event==='approval/request')).value;
    verifyApproval(approval,sessionId,model.calls.get(mode));
    assert.equal(existsSync(join(workspace,'deny-marker')),false);
    if(mode==='identity')assert.equal(existsSync(join(workspace,'中文 标记.txt')),false);
    if(mode==='cancel')assert.equal(existsSync(join(workspace,'ready')),false);
    if(mode==='exit'||mode==='after')assert.equal(existsSync(join(workspace,mode+'-marker')),false);
    const decision=mode==='deny'?'rejected':'allowed-once';
    await rpc('$events/result',{clientId,eventId:approval.eventId,outcome:{kind:'result',value:decision}});
    report.approvals++;
    const decisions=[decision];
    if(mode==='rootdeny'||mode==='rootallow') {
      const root=(await waitFrame(f=>f.value?.type==='waterfall'&&f.value.event==='approval/request'&&f.value.eventId!==approval.eventId)).value;
      verifyApproval(root,sessionId,model.calls.get(mode));
      assert.match(root.request.reason,/Linux/);
      const rootDecision=mode==='rootdeny'?'rejected':'allowed-once';
      await rpc('$events/result',{clientId,eventId:root.eventId,outcome:{kind:'result',value:rootDecision}});
      decisions.push(rootDecision);report.approvals++;
    }
    if(mode==='cancel') {
      const until=Date.now()+60000;
      while(!existsSync(join(workspace,'ready'))) {
        if(muxError)throw muxError;if(Date.now()>until)throw new Error('guest never wrote cancel readiness');await delay(25);
      }
      await rpc('session/cancel',{request:{sessionId}});
    }
    const end=(await waitFrame(f=>f.streamId==='session'&&f.value?.event?.type==='turn/end')).value.event;
    assert.equal(end.data.reason?.kind,mode==='cancel'?'aborted':'completed');
    const results=events.filter(e=>e.type==='tool/result');
    if(mode!=='cancel')assert.equal(results.length,1);
    for(const event of results)assert.equal(event.data.message?.source?.callId,approval.request.callId);
    const text=results.flatMap(e=>e.data.message?.content??[]).map(part=>part.text??'').join('\n');
    if(mode==='deny'){assert.equal(existsSync(join(workspace,'deny-marker')),false);assert.ok(/reject|denied|拒绝|未批准/i.test(text),'deny result must report refusal');}
    if(mode==='identity'){
      assert.match(text,/Linux/);assert.match(text,/(?:^|\n)3\.24\.4(?:\r?\n|$)/);assert.equal(await readFile(join(workspace,'中文 标记.txt'),'utf8'),'guest-ok');
      assert.ok(text.includes('python3=absent')||text.includes('python3=present:2'),'optional Python observation missing');
      assert.equal(results[0].data.message.isError,false);
    }
    if(mode==='osrelease'||mode==='pipeline')assert.match(text,/(?:^|\n)ID=alpine(?:\r?\n|$)/);
    if(mode==='apkpath')assert.match(text,/\/sbin\/apk(?:\r?\n|$)/);
    if(mode==='full')assert.match(text,/apk-tools/);
    if(mode==='rootdeny')assert.ok(/reject|denied|拒绝|未批准/i.test(text),'root denial must report refusal');
    if(mode==='rootreadonly'||mode==='rootafter') {
      assert.match(text,/Read-only file system/i);
      assert.match(text,mode==='rootreadonly'?/root-readonly/:/root-readonly-again/);
      assert.equal(results[0].data.message.isError,false);
    }
    if(mode==='rootallow') {
      assert.match(text,/approved/);assert.equal(results[0].data.message.isError,false);
    }
    if(mode==='exit')assert.match(text,/\[exit code: 7\]/);
    if(mode==='after')assert.match(text,/guest-after-cancel/);
    if(mode==='cancel'){
      const heartbeat=join(workspace,'heartbeat');await delay(300);
      const before=(await stat(heartbeat)).size;await delay(500);assert.equal((await stat(heartbeat)).size,before,'guest writes continued after cancellation');
    }
    // Reopen the same real session to inspect persisted approval records.
    const auditId='audit-'+mode;
    socket.send(JSON.stringify({type:'open',streamId:auditId,endpoint:'session/follow',payload:{args:{request:{address:{kind:'session',sessionId},assistantDeltas:false}}}}));
    const rows=(await waitFrame(f=>f.streamId===auditId&&f.value?.type==='snapshot')).value.records;
    const audit=rows.map(r=>r.event).filter(Boolean);
    verifyAudit(audit,approval.request.callId,decisions);
    report.scenarios.push({name:mode,sessionId,callId:approval.request.callId,decision,decisions,asked:decisions.length,decided:decisions.length,persistedTurnEnclosed:true});
    return sessionId;
  } finally {socket.removeAllListeners('close');socket.terminate();for(const w of [...waiters])w.reject(new Error('round closed'));}
}
try {
  const ready=await waitReady(0,240000);
  let session;
  for(const mode of ['deny','identity','osrelease','apkpath','pipeline','full','rootreadonly','rootdeny','rootallow','rootafter','exit','cancel','after'])session=await round(ready,mode,session);
  // Every sensitive call requested a fresh approval. allowed-once did not become a standing grant.
  assert.equal(report.approvals,15);report.status='PASS';report.stage='complete';
}catch(error){report.error=String(error.message);}
if(!exited){writeFileSync(`${guest}/quit`,'');await Promise.race([once(engine,'exit'),delay(20000)]);if(!exited)engine.kill();}
report.modelRequests=model.requests.map(r=>({scenario:r.scenario,requestedTool:r.requestedTool}));
await model.close();report.nativeHost=tail;
writeFileSync(join(work,'guest-report.json'),JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify(report,null,2));process.exit(report.status==='PASS'?0:1);
