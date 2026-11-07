import { pathToFileURL } from 'node:url';
const { withFileLock } = await import(pathToFileURL(process.env.DSH_ATOMIC_SOURCE));
process.on('message', () => {});
await withFileLock(process.argv[2], async () => {
  process.send({kind:'held'});
  await new Promise(resolve => process.once('message', resolve));
}, {waitMs:0});
process.disconnect();
