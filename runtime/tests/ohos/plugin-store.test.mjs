import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync, realpathSync, readdirSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { beginTransaction, recoverProfile, transactionFor } from '../../ohos/plugins/store.mjs';

const moduleUrl = new URL('../../ohos/plugins/store.mjs', import.meta.url).href;
function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(), 'ohos-plugin-store-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  writeFileSync(join(dir, 'package.json'), '{"dependencies":{},"dsh":{"profile":{"bundles":[]}}}\n');
  writeFileSync(join(dir, 'cordis.patch.yml'), '[]\n');
  return dir;
}
function manifest(dir) { return JSON.parse(readFileSync(join(dir, 'package.json'))); }
function stage(transaction, version = '1.0.0') {
  const generation = transaction.newGeneration();
  const pkg = join(generation, 'pkg');
  mkdirSync(pkg);
  writeFileSync(join(pkg, 'package.json'), JSON.stringify({ name: 'fixture-plugin', version }));
  writeFileSync(join(pkg, 'value.txt'), version);
  return pkg;
}
function install(dir, version) {
  const transaction = beginTransaction(dir);
  const pkg = stage(transaction, version);
  transaction.publish('fixture-plugin', pkg);
  const value = manifest(dir);
  value.dependencies['fixture-plugin'] = version;
  transaction.writeManifest(value);
  transaction.finish(true);
  return pkg;
}

test('install commits exact manifest and package link while retaining immutable files', t => {
  const dir = fixture(t), pkg = install(dir, '1.0.0');
  assert.equal(manifest(dir).dependencies['fixture-plugin'], '1.0.0');
  assert.equal(realpathSync(join(dir, 'node_modules/fixture-plugin')), pkg);
  assert.equal(existsSync(join(dir, '.plugin-manager/ohos/transaction.json')), false);
});

test('failure after package publication and bundle selection restores both', t => {
  const dir = fixture(t), old = install(dir, '1.0.0');
  const before = readFileSync(join(dir, 'package.json'));
  const transaction = beginTransaction(dir), newer = stage(transaction, '2.0.0');
  transaction.publish('fixture-plugin', newer);
  transaction.writeManifest({ dependencies: { 'fixture-plugin': '2.0.0' }, dsh: { profile: { bundles: ['fixture-plugin'] } } });
  writeFileSync(join(dir, 'compatibility.json'), '{"changed":true}');
  transaction.finish(false);
  assert.deepEqual(readFileSync(join(dir, 'package.json')), before);
  assert.equal(existsSync(join(dir, 'compatibility.json')), false);
  assert.equal(realpathSync(join(dir, 'node_modules/fixture-plugin')), old);
  assert.equal(existsSync(newer), false);
});

test('update retains an old real path for a live Node module and points new readers at new bytes', t => {
  const dir = fixture(t), old = install(dir, '1.0.0'), newer = install(dir, '2.0.0');
  assert.equal(readFileSync(join(old, 'value.txt'), 'utf8'), '1.0.0');
  assert.equal(readFileSync(join(newer, 'value.txt'), 'utf8'), '2.0.0');
  assert.equal(realpathSync(join(dir, 'node_modules/fixture-plugin')), newer);
});

test('remove rollback restores old link and selection without a download', t => {
  const dir = fixture(t), old = install(dir, '1.0.0');
  const transaction = beginTransaction(dir);
  transaction.publish('fixture-plugin', null);
  transaction.writeManifest({ dependencies: {}, dsh: { profile: { bundles: [] } } });
  transaction.finish(false);
  assert.equal(manifest(dir).dependencies['fixture-plugin'], '1.0.0');
  assert.equal(realpathSync(join(dir, 'node_modules/fixture-plugin')), old);
});

test('failed registry attempt is reversible and can retry under the same transaction', t => {
  const dir = fixture(t), transaction = beginTransaction(dir);
  const first = stage(transaction);
  transaction.publish('fixture-plugin', first);
  transaction.writeManifest({ dependencies: { 'fixture-plugin': '1.0.0' } });
  transaction.rollbackAttempt();
  assert.equal(existsSync(first), false);
  assert.deepEqual(manifest(dir).dependencies, {});
  const second = stage(transaction, '1.1.0');
  transaction.publish('fixture-plugin', second);
  transaction.writeManifest({ dependencies: { 'fixture-plugin': '1.1.0' } });
  transaction.finish(true);
  assert.equal(manifest(dir).dependencies['fixture-plugin'], '1.1.0');
});

test('resolution reads never recover an active transaction and overlapping begin is refused', t => {
  const dir = fixture(t), transaction = beginTransaction(dir), pkg = stage(transaction);
  transaction.publish('fixture-plugin', pkg);
  recoverProfile(dir);
  assert.equal(realpathSync(join(dir, 'node_modules/fixture-plugin')), pkg);
  assert.equal(transactionFor(dir), transaction);
  assert.throws(() => beginTransaction(dir), /未结束/);
  transaction.finish(false);
});

test('one attempt refuses a second publication before changing its durable intent', t => {
  const dir = fixture(t), old = install(dir, '1.0.0');
  const transaction = beginTransaction(dir), first = stage(transaction, '2.0.0'), second = stage(transaction, '3.0.0');
  transaction.publish('fixture-plugin', first);
  const journal = readFileSync(join(dir, '.plugin-manager/ohos/transaction.json'));
  assert.throws(() => transaction.publish('fixture-plugin', second), /重复发布/);
  assert.deepEqual(readFileSync(join(dir, '.plugin-manager/ohos/transaction.json')), journal);
  assert.equal(realpathSync(join(dir, 'node_modules/fixture-plugin')), first);
  transaction.finish(false);
  assert.equal(realpathSync(join(dir, 'node_modules/fixture-plugin')), old);
});

for (const point of ['generation', 'published', 'manifest']) test(`process death after ${point} restores on next startup`, t => {
  const dir = fixture(t), old = install(dir, '1.0.0');
  const before = readFileSync(join(dir, 'package.json'));
  const code = `
    import { beginTransaction } from ${JSON.stringify(moduleUrl)};
    import { mkdirSync, writeFileSync } from 'node:fs';
    import { join } from 'node:path';
    const transaction = beginTransaction(${JSON.stringify(dir)});
    const generation = transaction.newGeneration(), pkg = join(generation, 'pkg');
    mkdirSync(pkg); writeFileSync(join(pkg, 'package.json'), '{"name":"fixture-plugin","version":"2.0.0"}');
    if (${JSON.stringify(point)} === 'generation') process.exit(71);
    transaction.publish('fixture-plugin', pkg);
    if (${JSON.stringify(point)} === 'published') process.exit(71);
    transaction.writeManifest({ dependencies: { 'fixture-plugin': '2.0.0' } });
    process.exit(71);
  `;
  const result = spawnSync(process.execPath, ['--jitless', '--input-type=module', '-e', code], { encoding: 'utf8' });
  assert.equal(result.status, 71, result.stderr);
  recoverProfile(dir);
  assert.deepEqual(readFileSync(join(dir, 'package.json')), before);
  assert.equal(realpathSync(join(dir, 'node_modules/fixture-plugin')), old);
  assert.equal(readdirSync(join(dir, '.plugin-manager/ohos/generations')).length, 1);
});

test('refuses unmanaged package directory before replacing its bytes', t => {
  const dir = fixture(t);
  mkdirSync(join(dir, 'node_modules/fixture-plugin'), { recursive: true });
  writeFileSync(join(dir, 'node_modules/fixture-plugin/sentinel'), 'keep');
  const transaction = beginTransaction(dir), pkg = stage(transaction);
  assert.throws(() => transaction.publish('fixture-plugin', pkg), /不能覆盖/);
  transaction.finish(false);
  assert.equal(readFileSync(join(dir, 'node_modules/fixture-plugin/sentinel'), 'utf8'), 'keep');
});

test('refuses symlinked store and metadata paths without writing their targets', t => {
  const dir = fixture(t), outside = fixture(t);
  symlinkSync(outside, join(dir, '.plugin-manager'), 'dir');
  assert.throws(() => beginTransaction(dir), /目录/);
  assert.deepEqual(readdirSync(outside).sort(), ['cordis.patch.yml', 'package.json']);
  rmSync(join(dir, '.plugin-manager'));
  rmSync(join(dir, 'package.json'));
  symlinkSync(join(outside, 'package.json'), join(dir, 'package.json'));
  assert.throws(() => beginTransaction(dir), /普通文件/);
  assert.deepEqual(manifest(outside).dependencies, {});
});
