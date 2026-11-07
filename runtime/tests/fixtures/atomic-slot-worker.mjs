// DRAFT: actual public withFileLock; pause only after real slot hardlink succeeds.
import fs from 'node:fs/promises';
import { syncBuiltinESMExports } from 'node:module';
import { pathToFileURL } from 'node:url';
import { join, resolve } from 'node:path';
const [mode, filename] = process.argv.slice(2);
const source = process.env.DSH_ATOMIC_SOURCE ?? join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai/dsh-atomic-write/lib/index.js');
let release;
const resume = new Promise(r => { release = r; });
process.on('message', message => { if (message?.release) release(); });
if (mode === 'hold-slot') {
  const original = fs.link;
  fs.link = async (from, to) => {
    const result = await original(from, to);
    // Contract spelling provisional until protocol review: exact shared slot only.
    if (/\.takeover-[0-9a-f]{16}\.slots\/[0-9]+$/.test(String(to))) {
      process.send({ type: 'slot-held', slot: String(to) });
      await resume;
    }
    return result;
  };
  syncBuiltinESMExports();
}
const { withFileLock } = await import(pathToFileURL(source));
try {
  const result = await withFileLock(filename, async () => {
    process.send({ type: 'main-held' });
    if (mode === 'hold-main') await resume;
    return 42;
  }, { waitMs: 0 });
  process.send({ type: 'finished', result });
  process.disconnect();
} catch (error) {
  process.send({ type: 'failure', code: error.code, message: error.message });
  process.disconnect();
  process.exitCode = 1;
}
