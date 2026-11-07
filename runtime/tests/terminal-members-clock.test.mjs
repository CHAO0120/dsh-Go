// Actual terminal leaf methods plus the locked runner's real Linux inspector.
// No PTY construction, process creation, TERM/KILL, Host, or real timer waits.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';

for (const jump of [10_000, -10_000]) {
  test(`terminal member grace uses elapsed time after wall-clock jump ${jump}`, {
    skip: process.platform !== 'linux' ? 'requires the real Linux /proc inspector' : false,
  }, async () => {
    const modulePath = process.env.SUBPROCESS_LOCAL_MODULE
      ?? (process.env.DSH_PREFIX && join(process.env.DSH_PREFIX, 'node_modules/@deepseek-ai/dsh-subprocess-local/lib/index.js'));
    assert(modulePath, 'set DSH_PREFIX or SUBPROCESS_LOCAL_MODULE to the actual locked module');
    const source = readFileSync(modulePath, 'utf8');
    const runnerImport = source.match(/from "(\.\/runner-launch-[^"/]+\.js)";/);
    assert(runnerImport, 'actual module must identify its runner chunk');
    const { D: createProcessInspector } = await import(pathToFileURL(join(dirname(modulePath), runnerImport[1])).href);
    assert.equal(typeof createProcessInspector, 'function');
    const inspector = createProcessInspector();
    const snapshot = inspector.snapshot();
    const self = snapshot.tree(process.pid).find(identity => identity.pid === process.pid);
    assert(self, 'setup: real /proc snapshot must contain this process');
    assert(snapshot.alive(self), 'setup: real start identity must be alive');
    assert(inspector.isAlive(self));

    const start = source.indexOf('//#region lib/types/terminal.js');
    const end = source.indexOf('//#endregion', start);
    assert(start >= 0 && end > start);
    let elapsed = 0;
    let polls = 0;
    let wallReads = 0;
    const waits = [];
    const context = vm.createContext({
      Promise,
      Date: { now: () => wallReads++ === 0 ? 0 : elapsed + jump },
      performance: { now: () => elapsed },
      setTimeout(callback, milliseconds) {
        polls++;
        waits.push(milliseconds);
        // Queue only a microtask, allowing the actual delay's timer binding to initialize.
        queueMicrotask(() => { elapsed += milliseconds; callback(); });
        return polls;
      },
      clearTimeout() {},
    });
    const LocalTerminalHandle = new vm.Script(source.slice(start, end) + '\nLocalTerminalHandle').runInContext(context);
    // Do not instantiate a terminal or invent an inspector. Only these real leaves are used.
    const handle = Object.create(LocalTerminalHandle.prototype);
    handle.inspector = inspector;
    // 3000 is the shipped model-terminal configuration, not a default of this method.
    handle.graceMs = 3000;
    const survivors = await handle.waitForMembers([self]);
    assert.equal(elapsed, 3000);
    assert.equal(polls, 120, 'remaining-time calculation must use the same clock as the deadline');
    assert(waits.every(milliseconds => milliseconds === 25), 'keep the actual 25 ms cadence');
    assert.equal(survivors.length, 1);
    assert.equal(survivors[0], self, 'return the same real start identity, not a synthetic replacement');
    assert(inspector.isAlive(self), 'waiting did not terminate the observed process');
  });
}
