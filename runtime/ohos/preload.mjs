// The product host's sole --import. Keep sequential dynamic imports: network
// bootstrap must finish before publication's dependencies are even evaluated.
await import('./net/dsh-preload.mjs');
await import('./publication/preload.mjs');
await import('./process/node-worker-preload.mjs');
