import assert from 'node:assert/strict';
export function verifyApproval(value, sessionId, callId) {
  assert.ok(callId);assert.equal(value.agentId,sessionId);
  assert.equal(value.request.toolName,'bash');assert.equal(value.request.callId,callId);
}
export function verifyAudit(audit, callId, decision) {
  const asked=audit.filter(e=>e.type==='approval/asked'&&e.data.callId===callId);
  const decided=audit.filter(e=>e.type==='approval/decided'&&e.data.id===asked[0]?.data.id);
  assert.equal(asked.length,1);assert.equal(decided.length,1);
  assert.equal(asked[0].data.id,decided[0].data.id);assert.equal(decided[0].data.outcome,decision);
  const begin=audit.findLastIndex((e,i)=>e.type==='turn/start'&&i<audit.indexOf(asked[0]));
  const finish=audit.findIndex((e,i)=>e.type==='turn/end'&&i>audit.indexOf(decided[0]));
  assert.ok(begin>=0&&begin<audit.indexOf(asked[0])&&audit.indexOf(asked[0])<audit.indexOf(decided[0])&&audit.indexOf(decided[0])<finish);
  assert.equal(audit.slice(begin+1,finish).filter(e=>e.type==='turn/start'||e.type==='turn/end').length,0);
}
