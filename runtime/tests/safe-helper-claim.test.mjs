import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile, writeFile, mkdtemp, mkdir, rm} from 'node:fs/promises';
import {spawn, fork} from 'node:child_process';
import {once} from 'node:events';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createInterface} from 'node:readline';
const peer = fileURLToPath(new URL('./fixtures/atomic-peer.mjs',import.meta.url));
const gates = fileURLToPath(new URL('./fixtures/helper-gates.cjs',import.meta.url));
const source = process.env.SAFE_MODE_SOURCE ?? fileURLToPath(new URL('../../app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/runtime/SafeMode.kt', import.meta.url));
const atomic = process.env.DSH_ATOMIC_SOURCE ?? (process.env.DSH_PREFIX && join(resolve(process.env.DSH_PREFIX),'node_modules/@deepseek-ai/dsh-atomic-write/lib/index.js'));

function managed(t, p, children) {
 const exit = new Promise(resolve => { p.once('error',error=>resolve([-1,error])); p.once('exit',(code,signal)=>resolve([code,signal])); });
 const abort=()=>{if(p.exitCode===null&&p.signalCode===null)p.kill('SIGKILL');};
 t.signal.addEventListener('abort',abort,{once:true});
 children.push({p,exit,abort});
 return exit;
}
async function child(t, children, bin, args, options) {
 const p=spawn(bin,args,options); const exit=managed(t,p,children);
 let stderr=''; p.stderr?.on('data',b=>{stderr+=b});
 return {p,exit,stderr:()=>stderr};
}
async function holder(t, children, filename) {
 const p=fork(peer,[filename],{env:{...process.env,DSH_ATOMIC_SOURCE:atomic},stdio:['ignore','ignore','pipe','ipc']});
 const exit=managed(t,p,children); let stderr='';p.stderr.on('data',b=>{stderr+=b});
 const [msg]=await Promise.race([once(p,'message'),exit.then(()=>{throw Error('peer exited: '+stderr)})]);
 assert.equal(msg.kind,'held');return {p,exit};
}
test('real helper must not remove a successor atomic writer after observing the dead holder', {timeout:10000, skip:process.platform !== 'linux' ? 'real SIGKILL and synchronous fd3 pipe gate validated on Linux only' : false}, async t=>{
 assert.ok(atomic, 'set DSH_PREFIX or DSH_ATOMIC_SOURCE');
 const children=[];
 const dir=await mkdtemp(join(tmpdir(),'safe-helper-claim-'));
 t.after(async()=>{
  for(const c of children)c.abort();
  await Promise.all(children.map(c=>c.exit));
  for(const c of children)t.signal.removeEventListener('abort',c.abort);
  await rm(dir,{recursive:true,force:true});
 });
 const home=join(dir,'home'),profile=join(home,'profiles/web');await mkdir(profile,{recursive:true});
 const manifest=join(profile,'package.json');const original=JSON.stringify({dsh:{profile:{bundles:['example-plugin']}}});await writeFile(manifest,original);
 const script=(await readFile(source,'utf8')).match(/const val PLUGINS_SCRIPT = """([\s\S]*?)"""/)?.[1];assert.ok(script,'actual complete embedded helper');
 const helper=join(dir,'helper.cjs');await writeFile(helper,script);
 const a=await holder(t,children,manifest);const oldRecord=await readFile(manifest+'.lock','utf8');a.p.kill('SIGKILL');await a.exit;
 assert.throws(()=>process.kill(a.p.pid,0),{code:'ESRCH'});assert.equal(oldRecord,`${a.p.pid}\n`);
 const b=await child(t,children,process.execPath,['--require',gates,helper,'disable','example-plugin'],{env:{...process.env,DSH_APP_ORIGINAL_HOME:home,DEAD_HOLDER_PID:String(a.p.pid),TEST_MANIFEST:manifest},stdio:['pipe','ignore','pipe','pipe']});
 const lines=createInterface({input:b.p.stdio[3]})[Symbol.asyncIterator]();
 const next=async()=>{const result=await Promise.race([lines.next(),b.exit.then(()=>{throw Error('helper exited: '+b.stderr())})]);assert.equal(result.done,false);return JSON.parse(result.value).kind;};
 assert.equal(await next(),'dead-observed');
 const c=await holder(t,children,manifest);assert.equal(await readFile(manifest+'.lock','utf8'),`${c.p.pid}\n`);
 b.p.stdin.write('x');
 assert.equal(await next(),'contended','old helper reaches publishing while C still holds lock: actual ABA');
 assert.equal(await readFile(manifest+'.lock','utf8'),`${c.p.pid}\n`);assert.equal(await readFile(manifest,'utf8'),original);
 c.p.send({release:true});assert.deepEqual(await c.exit,[0,null]);
 b.p.stdin.write('x');assert.equal(await next(),'publishing');b.p.stdin.write('x');assert.deepEqual(await b.exit,[0,null]);
 assert.deepEqual(JSON.parse(await readFile(manifest,'utf8')).dsh.profile.bundles,[]);
 await assert.rejects(readFile(manifest+'.lock'),{code:'ENOENT'});
});

test('atomic peer recovers a slot published by the actual helper killed before main unlink', {timeout:10000, skip:process.platform !== 'linux' ? 'real SIGKILL and fd3 gates require Linux' : false}, async t=>{
 assert.ok(atomic, 'set DSH_PREFIX or DSH_ATOMIC_SOURCE');
 const children=[]; const dir=await mkdtemp(join(tmpdir(),'safe-helper-slot-death-'));
 t.after(async()=>{for(const c of children)c.abort();await Promise.all(children.map(c=>c.exit));for(const c of children)t.signal.removeEventListener('abort',c.abort);await rm(dir,{recursive:true,force:true});});
 const home=join(dir,'home'),profile=join(home,'profiles/web');await mkdir(profile,{recursive:true});
 const manifest=join(profile,'package.json');const original=JSON.stringify({dsh:{profile:{bundles:['example-plugin']}}});await writeFile(manifest,original);
 const script=(await readFile(source,'utf8')).match(/const val PLUGINS_SCRIPT = """([\s\S]*?)"""/)?.[1];assert.ok(script);
 const helper=join(dir,'helper.cjs');await writeFile(helper,script);
 const a=await holder(t,children,manifest);const oldRecord=await readFile(manifest+'.lock','utf8');a.p.kill('SIGKILL');await a.exit;
 assert.throws(()=>process.kill(a.p.pid,0),{code:'ESRCH'});
 const b=await child(t,children,process.execPath,['--require',gates,helper,'disable','example-plugin'],{env:{...process.env,DSH_APP_ORIGINAL_HOME:home,HOLD_PUBLIC_SLOT:'1'},stdio:['pipe','ignore','pipe','pipe']});
 const lines=createInterface({input:b.p.stdio[3]})[Symbol.asyncIterator]();
 const observed=await Promise.race([lines.next(),b.exit.then(()=>{throw Error('helper exited before slot: '+b.stderr())})]);
 assert.equal(observed.done,false);assert.equal(JSON.parse(observed.value).kind,'slot-held');
 const {createHash}=await import('node:crypto');const slot=manifest+'.lock.takeover-'+createHash('sha256').update(oldRecord).digest('hex').slice(0,16)+'.slots/0';
 assert.equal(await readFile(slot,'utf8'),`${b.p.pid}\n`);assert.equal(await readFile(manifest+'.lock','utf8'),oldRecord);
 b.p.kill('SIGKILL');assert.deepEqual(await b.exit,[null,'SIGKILL']);assert.throws(()=>process.kill(b.p.pid,0),{code:'ESRCH'});
 const c=await holder(t,children,manifest);assert.equal(await readFile(manifest+'.lock','utf8'),`${c.p.pid}\n`);
 assert.equal(await readFile(slot,'utf8'),`${b.p.pid}\n`);assert.equal(await readFile(manifest,'utf8'),original);
 c.p.send({release:true});assert.deepEqual(await c.exit,[0,null]);
 const d=await child(t,children,process.execPath,[helper,'disable','example-plugin'],{env:{...process.env,DSH_APP_ORIGINAL_HOME:home},stdio:['ignore','ignore','pipe']});
 assert.deepEqual(await d.exit,[0,null],d.stderr());assert.deepEqual(JSON.parse(await readFile(manifest,'utf8')).dsh.profile.bundles,[]);
});
