// Keep the real EFBIG observable rather than terminating on SIGXFSZ.
process.on('SIGXFSZ', () => {});
// Advance either helper deadline clock; never sleep for five seconds.
if (process.env.TEST_FAST_LOCK_TIMEOUT === '1') {
  let now = Date.now();
  Date.now = () => { now += 6000; return now; };
  const { performance } = require('node:perf_hooks');
  let monotonic = performance.now();
  Object.defineProperty(performance, 'now', {
    configurable: true,
    value: () => { monotonic += 6000; return monotonic; },
  });
  Atomics.wait = () => { throw new Error('unexpected real wait'); };
}
