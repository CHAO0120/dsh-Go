// Keep the real EFBIG observable rather than terminating on SIGXFSZ.
process.on('SIGXFSZ', () => {});
// Advance only the existing contention deadline; never sleep for five seconds.
if (process.env.TEST_FAST_LOCK_TIMEOUT === '1') {
  let now = Date.now();
  Date.now = () => { now += 6000; return now; };
  Atomics.wait = () => { throw new Error('unexpected real wait'); };
}
