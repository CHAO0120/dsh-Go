import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import fs from 'node:fs/promises';
import { createHash } from 'node:crypto';

const [mode, filename] = process.argv.slice(2);
if (mode === 'fail-claim') process.on('SIGXFSZ', () => {});
// A message listener references the child IPC channel while the explicit gate
// is held; an unresolved Promise alone does not keep Node running.
if (mode === 'hold-main' || mode === 'hold-claim') process.on('message', () => {});

// Explicit legacy compatibility producer: complete PID record owned by this real
// process, not a claim created by the new slot protocol. No fake liveness probe.
if (mode === 'hold-claim') {
  const record = await fs.readFile(filename + '.lock', 'utf8');
  const claim = filename + '.lock.takeover-' + createHash('sha256').update(record).digest('hex').slice(0, 16);
  const handle = await fs.open(claim, 'wx', 0o600);
  try { await handle.writeFile(`${process.pid}\n`); } finally { await handle.close(); }
  process.send({ type: 'claim-held' });
  await new Promise(() => {});
}

const { withFileLock } = await import(pathToFileURL(join(resolve(process.env.DSH_PREFIX),
  'node_modules/@deepseek-ai/dsh-atomic-write/lib/index.js')));

if (mode === 'hold-main') {
  await withFileLock(filename, async () => {
    process.send({ type: 'main-held' });
    await new Promise(() => {});
  }, { waitMs: 0 });
} else {
  const result = { operations: 0 };
  try {
    await withFileLock(filename, () => { result.operations++; }, { waitMs: 0 });
  } catch (error) {
    result.error = { code: error.code, message: error.message };
  }
  process.stdout.write(`${JSON.stringify(result)}\n`);
}
