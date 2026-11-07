const fs = require('node:fs');
const dead = Number(process.env.DEAD_HOLDER_PID);
let stopped = false;
function gate(kind) {
  fs.writeSync(3, JSON.stringify({kind}) + '\n');
  const byte = Buffer.alloc(1);
  if (fs.readSync(0, byte, 0, 1, null) !== 1) process.exit(90);
}
const kill = process.kill.bind(process);
process.kill = function(pid, signal) {
  try { return kill(pid, signal); }
  catch (error) {
    if (!stopped && pid === dead && signal === 0 && error.code === 'ESRCH') {
      stopped = true;
      gate('dead-observed');
    }
    throw error;
  }
};
// Scheduler gates only: lock reads/writes, process probes and operation remain real.
Atomics.wait = function() { gate('contended'); return 'timed-out'; };
const rename = fs.renameSync;
fs.renameSync = function(from, to) {
  if (to === process.env.TEST_MANIFEST) gate('publishing');
  return rename.apply(this, arguments);
};
