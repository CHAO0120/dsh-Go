import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const source = process.env.SAFE_MODE_SOURCE ?? fileURLToPath(new URL('../../app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/runtime/SafeMode.kt', import.meta.url));
const preload = fileURLToPath(new URL('./fixtures/safe-helper-file-limit.cjs', import.meta.url));
const linux = { skip: process.platform !== 'linux' ? 'real bash RLIMIT_FSIZE and SIGXFSZ require Linux' : false };
function fixture(t) {
  const bash = spawnSync('bash', ['-c', 'ulimit -S -f 0'], { encoding: 'utf8', timeout: 5000 });
  if (bash.error?.code === 'ENOENT' || (!bash.error && bash.status !== 0)) { t.skip('bash RLIMIT_FSIZE unavailable'); return null; }
  assert.ifError(bash.error);
  const dir = mkdtempSync(join(tmpdir(), 'safe-helper-write-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const profile = join(dir, 'profiles/web'); mkdirSync(profile, { recursive: true });
  const manifest = join(profile, 'package.json');
  const before = JSON.stringify({ dsh: { profile: { bundles: ['example-plugin'] } } });
  writeFileSync(manifest, before);
  const helper = join(dir, 'helper.cjs');
  const script = readFileSync(source, 'utf8').match(/const val PLUGINS_SCRIPT = """([\s\S]*?)"""/)?.[1];
  assert.ok(script, 'run the complete actual embedded helper'); writeFileSync(helper, script);
  function run(limited) {
    const args = ['--require', preload, helper, 'disable', 'example-plugin'];
    const result = limited
      ? spawnSync('bash', ['-c', 'ulimit -S -f 0; exec "$@"', '_', process.execPath, ...args], options())
      : spawnSync(process.execPath, args, options());
    assert.ifError(result.error); assert.equal(result.signal, null, result.stderr); return result;
  }
  function options() { return { encoding: 'utf8', timeout: 5000, env: { ...process.env, DSH_APP_ORIGINAL_HOME: dir, TEST_FAST_LOCK_TIMEOUT: '1' } }; }
  return { manifest, before, lock: manifest + '.lock', run };
}
test('helper removes its newly created main lock after a real EFBIG', linux, t => {
  const f = fixture(t); if (!f) return;
  const r = f.run(true); assert.notEqual(r.status, 0); assert.match(r.stderr, /EFBIG/);
  assert.equal(readFileSync(f.manifest, 'utf8'), f.before);
  assert.equal(existsSync(f.lock), false, 'acquired lock must not survive a caught write failure');
});
test('an unlimited actual helper succeeds after the size-limited helper fails', linux, t => {
  const f = fixture(t); if (!f) return;
  assert.match(f.run(true).stderr, /EFBIG/);
  const next = f.run(false); assert.equal(next.status, 0, next.stderr);
  assert.deepEqual(JSON.parse(readFileSync(f.manifest, 'utf8')).dsh.profile.bundles, []);
  assert.equal(existsSync(f.lock), false);
});
for (const [label, record] of [['empty legacy', ''], ['live owner', `${process.pid}\n`]]) {
  test(`a size-limited contender preserves an existing ${label} main lock`, linux, t => {
    const f = fixture(t); if (!f) return; writeFileSync(f.lock, record);
    const r = f.run(true); assert.notEqual(r.status, 0); assert.match(r.stderr, /package.json 正被别的进程修改/);
    assert.equal(readFileSync(f.lock, 'utf8'), record); assert.equal(readFileSync(f.manifest, 'utf8'), f.before);
  });
}
