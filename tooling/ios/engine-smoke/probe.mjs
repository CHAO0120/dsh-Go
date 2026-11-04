// Test builds only (DSH_IOS_SMOKE_IMPORT). Says why the first outbound request fails, which
// the engine reports only as a connection error. It must not make a request of its own:
// one made early is what hides the failure.
import { isMainThread } from 'node:worker_threads';

const describe = (error) => {
  const parts = [];
  for (let at = error; at; at = at.cause) parts.push(`${at.name}/${at.code ?? ''}/${at.message}`);
  return `${parts.join(' <- ')} @ ${String(error.stack).split('\n').slice(1, 8).join(' ; ')}`;
};

if (isMainThread) {
  const original = globalThis.fetch;
  globalThis.fetch = async function fetch(input, init) {
    const startedAt = Date.now();
    const url = String(input?.url ?? input);
    console.error(`[probe] fetch ${url}`);
    try {
      const response = await original.call(this, input, init);
      console.error(`[probe] fetch ${response.status} after ${Date.now() - startedAt} ms`);
      return response;
    } catch (error) {
      console.error(`[probe] fetch failed after ${Date.now() - startedAt} ms: ${describe(error)}`);
      throw error;
    }
  };
}
