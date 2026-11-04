import test, {after} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {timers,osTask} from './transient-task-fixture.mjs';
const directory=await fs.mkdtemp(path.join(os.tmpdir(),'transient-owner-'));
const source=new URL('../../../app/ohos/entry/src/main/ets/runtime/TransientTaskOwner.ets',import.meta.url);
const text=(await fs.readFile(source,'utf8')).replace(/^import .+;\n/gm,'');
await fs.writeFile(path.join(directory,'owner.mts'),`import {backgroundTaskManager,setTimeout,clearTimeout} from '${new URL('./transient-task-fixture.mjs',import.meta.url)}';\n`+text);
const {TransientTaskOwner}=await import(pathToFileURL(path.join(directory,'owner.mts')));after(()=>fs.rm(directory,{recursive:true,force:true}));
function setup(t){
 timers.clear();Object.assign(osTask,{requests:[],cancels:[],failCancel:false,callbackNow:false,duration:30000});
 const s={version:1,engineGeneration:1,ownerGeneration:0,revision:1,grantGeneration:0,nowMs:10000,deadlineMs:0,drainAtMs:0,phase:0,available:1,foreground:0,clockFailed:0};let t0=0,wakes=0;
 const writes=[];const host={lifecycleSnapshot:()=>({...s}),lifecycleUpdate(op,owner,grant,value){writes.push(op);
 if(op==='owner'){s.ownerGeneration++;s.foreground=value;s.revision++;return s.ownerGeneration;}
 if(owner!==s.ownerGeneration)return 0;
 if(op==='foreground'){s.foreground=value;s.phase=4;s.revision++;return 1;}
 if(op==='begin'){t0=s.nowMs;s.phase=1;s.grantGeneration++;s.revision++;return s.grantGeneration;}
 if(op==='activate'){if(s.phase!==1)return 0;s.deadlineMs=t0+value;s.drainAtMs=s.deadlineMs-6000;s.phase=2;s.revision++;return 1;}
 if(op==='drain'){s.phase=3;s.revision++;return 1;}
 if(op==='release'){s.phase=4;s.deadlineMs=s.drainAtMs=0;s.revision++;return 1;}
 if(op==='retire'){s.available=0;s.phase=4;s.revision++;return 1;}throw Error(op);
 }};
 const owner=new TransientTaskOwner(host,true,()=>{wakes++;});
 const ack=(busy=true,manualPaused=false)=>({nativeHost:{...s},busy,manualPaused,confirmedPause:s.phase!==2});
 const background=()=>{owner.acknowledge(ack());owner.observe(false);owner.acknowledge(ack());};
 t.after(()=>{osTask.failCancel=false;owner.retire();timers.clear();});
 return {s,host,owner,ack,background,writes,get wakes(){return wakes;}};
}
test('idle, unknown and manual pause consume no transient quota',t=>{for(const mode of ['unknown','idle','paused']){const f=setup(t);if(mode!=='unknown')f.owner.acknowledge(f.ack(mode==='paused',mode==='paused'));f.owner.observe(false);f.owner.acknowledge(f.ack());assert.equal(osTask.requests.length,0);}});
test('fresh actual work requires second current background ACK before requesting once',t=>{const f=setup(t);f.owner.acknowledge(f.ack());f.owner.observe(false);assert.equal(osTask.requests.length,0);f.owner.acknowledge(f.ack());assert.equal(osTask.requests.length,1);assert.equal(f.s.phase,2);const deadline=f.s.deadlineMs;f.owner.observe(false);f.owner.acknowledge(f.ack());assert.equal(osTask.requests.length,1);assert.equal(f.s.deadlineMs,deadline);});
test('busy to idle between observations does not spend quota',t=>{const f=setup(t);f.owner.acknowledge(f.ack());f.owner.observe(false);f.owner.acknowledge(f.ack(false));assert.equal(osTask.requests.length,0);});
test('stale foreground evidence and delayed background ACK fail closed',t=>{const f=setup(t);f.owner.acknowledge(f.ack());f.s.nowMs+=1001;f.owner.observe(false);f.owner.acknowledge(f.ack());assert.equal(osTask.requests.length,0);const g=setup(t);g.owner.acknowledge(g.ack());g.owner.observe(false);g.s.nowMs+=1001;g.owner.acknowledge(g.ack());assert.equal(osTask.requests.length,0);});
test('old owner/revision ACK cannot activate a new background transition',t=>{const f=setup(t);const old=f.ack();f.owner.acknowledge(old);f.owner.observe(false);f.owner.acknowledge(old);assert.equal(osTask.requests.length,0);});
test('round completion closes native admission before OS cancellation',t=>{const f=setup(t);f.background();f.owner.acknowledge(f.ack(false));assert.equal(f.s.phase,4);assert.equal(osTask.cancels.length,1);assert.equal(f.writes.at(-1),'release');});
test('retirement never requests and late ACK does not reactivate',t=>{const f=setup(t);f.owner.acknowledge(f.ack());f.owner.retire();f.owner.observe(false);f.owner.acknowledge(f.ack());assert.equal(osTask.requests.length,0);assert.equal(f.s.available,0);});
test('synchronous OS callback before request returns cannot activate',t=>{const f=setup(t);osTask.callbackNow=true;f.background();assert.equal(f.s.phase,4);assert.equal(osTask.cancels.length,1);assert.equal(f.writes.includes('activate'),false);});
test('retired permanent cancel failure retains diagnosis but bounds retries and stops timers',t=>{const f=setup(t);f.background();osTask.failCancel=true;f.owner.retire();const wakes=f.wakes;for(let i=0;i<5;i++){const row=timers.entries().next().value;if(!row)break;timers.delete(row[0]);row[1].fn();}assert.equal(osTask.cancels.length,3);assert.equal(timers.size,0);assert.equal(f.wakes,wakes);assert.equal(f.owner.status().get('cleanupPending'),true);assert.equal(f.owner.status().get('error'),'ohos_transient_cancel_failed');assert.equal(f.s.available,0);});

test('native getter failure while handling ACK is consumed and retires the owner',t=>{const f=setup(t);f.background();f.host.lifecycleSnapshot=()=>{throw Error('native unavailable');};assert.doesNotThrow(()=>f.owner.acknowledge(f.ack()));assert.equal(f.s.available,0);assert.equal(osTask.cancels.length,1);});
test('retired cleanup status never borrows a replacement owner deadline',t=>{const f=setup(t);f.background();osTask.failCancel=true;f.owner.retire();f.s.ownerGeneration++;f.s.phase=2;f.s.deadlineMs=999999;const status=f.owner.status();assert.equal(status.get('retired'),true);assert.equal(status.get('deadlineMs'),null);assert.notEqual(status.get('ownerGeneration'),f.s.ownerGeneration);});
test('asynchronous OS callback native failure is consumed and retires before cleanup',t=>{
 const f=setup(t);f.background();const update=f.host.lifecycleUpdate;
 f.host.lifecycleUpdate=(operation,...args)=>{if(operation==='drain')throw Error('native drain failed');return update(operation,...args);};
 assert.doesNotThrow(()=>osTask.requests[0].callback());
 assert.equal(f.s.available,0);assert.equal(osTask.cancels.length,1);
 assert.equal(f.owner.status().get('error'),'ohos_transient_native_failed');
});
