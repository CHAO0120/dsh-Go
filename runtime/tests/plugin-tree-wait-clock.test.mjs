// Execute the actual run-tree helper; this is not a Host or process-termination test.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import vm from 'node:vm';

const modulePath = process.env.PLUGIN_MANAGER_MODULE
  ?? (process.env.DSH_PREFIX && join(process.env.DSH_PREFIX, 'node_modules/@deepseek-ai/dsh-plugin-manager/lib/index.js'));
if (!modulePath) throw Error('Set DSH_PREFIX or PLUGIN_MANAGER_MODULE to the actual service module');
const source = readFileSync(modulePath, 'utf8');
const start = source.indexOf('//#region lib/types/run-tree.js');
const end = source.indexOf('//#endregion', start);
assert(start >= 0 && end > start);
const segment = source.slice(start, end);

for (const jump of [10_000, -10_000]) {
  test(`tree wait keeps its elapsed budget across wall-clock jump ${jump}`, async () => {
    // A real live process, queried with signal zero only: no child, signals or sleeps.
    assert.doesNotThrow(() => process.kill(process.pid, 0));
    let elapsed = 0;
    let polls = 0;
    let wallReads = 0;
    const context = vm.createContext({
      process,
      Promise,
      Date: { now: () => wallReads++ === 0 ? 0 : elapsed + jump },
      performance: { now: () => elapsed },
      setTimeout(callback, milliseconds) {
        assert.equal(milliseconds, 15, 'keep the existing poll cadence');
        polls++;
        elapsed += milliseconds;
        callback();
      },
    });
    const { awaitTreeGone } = new vm.Script(segment + '\n({ awaitTreeGone })').runInContext(context);
    // No waitMs override: exercise the actual default 5000 ms budget.
    await awaitTreeGone({ pid: process.pid, grouped: false });
    assert.equal(elapsed, 5010, 'the first 15 ms polling boundary after the default budget');
    assert.equal(polls, 334);
    assert.doesNotThrow(() => process.kill(process.pid, 0), 'waiting must not signal or kill the observed process');
  });
}
