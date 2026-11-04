// Test builds only (DSH_IOS_SMOKE_IMPORT). Says why outbound requests fail, which the
// engine reports only as a connection error.
import http from 'node:http';
import { isMainThread } from 'node:worker_threads';

const describe = (error) => {
  const parts = [];
  for (let at = error; at; at = at.cause) parts.push(`${at.name}/${at.code ?? ''}/${at.message}`);
  return `${parts.join(' <- ')} @ ${String(error.stack).split('\n').slice(1, 7).join(' ; ')}`;
};

if (isMainThread && process.env.DSH_IOS_SMOKE_MODEL) {
  setTimeout(async () => {
    const url = `${process.env.DSH_IOS_SMOKE_MODEL}/models`;
    console.error(`[probe] platform=${process.platform} wasm=${typeof WebAssembly} proxy=${process.env.HTTP_PROXY ?? ''}`);
    await new Promise((done) => {
      http.get(url, (response) => {
        console.error(`[probe] node:http ${response.statusCode}`);
        response.resume();
        response.on('end', done);
      }).on('error', (error) => {
        console.error(`[probe] node:http failed: ${describe(error)}`);
        done();
      });
    });
    try {
      const response = await fetch(url);
      console.error(`[probe] fetch ${response.status} ${(await response.text()).length}`);
    } catch (error) {
      console.error(`[probe] fetch failed: ${describe(error)}`);
    }
  }, 2000);
}
