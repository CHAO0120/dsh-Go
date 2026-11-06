import { isMainThread } from 'node:worker_threads';

if (process.platform === 'openharmony' && isMainThread) {
  const { createPluginBackend } = await import('./backend.mjs');
  globalThis[Symbol.for('dsh.go.ohos.plugins')] ??= createPluginBackend();
}
