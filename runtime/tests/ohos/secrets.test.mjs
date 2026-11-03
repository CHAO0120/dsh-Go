import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { secretsFixture, deferred } from './secrets-fixture.mjs';

test('first empty reads are empty without generating a key; four methods preserve Unicode namespaces', async t => {
  const f = await secretsFixture(t);
  assert.deepEqual(await f.request('read', { key: 'remote.未保存' }), { value: null });
  assert.deepEqual(await f.request('readAll'), { value: {} });
  assert.deepEqual(await f.request('delete', { key: 'absent' }), { value: null });
  assert.equal(f.events.filter(row => row.op === 'generate').length, 0);
  const value = '秘密材料—中文🔐\nsecond line';
  assert.deepEqual(await f.request('write', { key: 'remote.密码', value }), { value: null });
  assert.deepEqual(await f.request('write', { key: 'deepseek_api_key', value: '' }), { value: null });
  assert.deepEqual(await f.request('read', { key: 'remote.密码' }), { value });
  assert.deepEqual(await f.request('readAll'), { value: { 'remote.密码': value, deepseek_api_key: '' } });
  const bytes = await fs.readFile(f.vaultPath);
  assert.equal(bytes.includes(Buffer.from(value)), false);
  assert.equal(bytes.includes(Buffer.from('remote.密码')), false);
  assert.deepEqual(await f.request('delete', { key: 'remote.密码' }), { value: null });
  assert.deepEqual(await f.request('readAll'), { value: { deepseek_api_key: '' } });
});

test('large private-key/hosted-list text exceeds Asset size and HUKS chunk size; actual short file IO completes', async t => {
  const f = await secretsFixture(t, { maxRead: 8191, maxWrite: 4093 });
  const value = '-----BEGIN PRIVATE KEY-----\n' + '中文内容-and-key-data\n'.repeat(12000) + '-----END PRIVATE KEY-----';
  assert(Buffer.byteLength(value) > 100 * 1024);
  assert.deepEqual(await f.request('write', { key: 'remote.private-key', value }), { value: null });
  assert.deepEqual(await f.request('read', { key: 'remote.private-key' }), { value });
  assert(f.events.some(row => row.op === 'update' && row.bytes === 64 * 1024));
  assert(f.events.filter(row => row.op === 'update').every(row => row.bytes <= 64 * 1024));
  assert.equal(f.fds.size, 0);
});

test('same value gets a fresh nonce; a new engine instance reuses the original non-overwritten key', async t => {
  const f = await secretsFixture(t);
  const args = { key: 'forum.keypair', value: '{"private":"retained"}' };
  assert.deepEqual(await f.request('write', args), { value: null });
  const first = await fs.readFile(f.vaultPath);
  f.plugin.onDetachedFromEngine(f.engine);
  const next = f.attach();
  assert.deepEqual(await f.request('read', { key: args.key }, next.channel), { value: args.value });
  assert.deepEqual(await f.request('write', args, next.channel), { value: null });
  const second = await fs.readFile(f.vaultPath);
  assert.notDeepEqual(first.subarray(8, 20), second.subarray(8, 20));
  assert.notDeepEqual(first, second);
  assert.equal(f.events.filter(row => row.op === 'generate').length, 1);
  next.plugin.onDetachedFromEngine(next.engine);
});

test('two live instances serialize read-modify-write without dropping concurrent keys', async t => {
  const f = await secretsFixture(t), next = f.attach();
  const writes = Array.from({ length: 12 }, (_, i) => f.request('write', { key: 'provider_key_' + i, value: 'key-' + i }, i % 2 ? next.channel : f.channel));
  assert((await Promise.all(writes)).every(reply => reply.value === null && !reply.error));
  assert.deepEqual(await f.request('delete', { key: 'provider_key_3' }, next.channel), { value: null });
  assert.deepEqual(await f.request('readAll'), { value: Object.fromEntries(Array.from({ length: 12 }, (_, i) => i).filter(i => i !== 3).map(i => ['provider_key_' + i, 'key-' + i])) });
  assert.equal(f.events.filter(row => row.op === 'generate').length, 1);
  next.plugin.onDetachedFromEngine(next.engine);
});

test('corrupt version or GCM tag makes all four operations fail without replacing existing ciphertext', async t => {
  const f = await secretsFixture(t);
  await f.request('write', { key: 'hosted_links', value: '[{"secret":"old-data"}]' });
  const original = await fs.readFile(f.vaultPath);
  for (const index of [4, original.length - 1]) {
    const corrupt = Buffer.from(original); corrupt[index] ^= 1; await fs.writeFile(f.vaultPath, corrupt);
    for (const [method, args] of [['read', { key: 'hosted_links' }], ['readAll', {}], ['write', { key: 'hosted_links', value: '[]' }], ['delete', { key: 'hosted_links' }]]) {
      const result = await f.request(method, args);
      assert.equal(result.error, 'secrets_unreadable');
      assert.deepEqual(await fs.readFile(f.vaultPath), corrupt);
    }
  }
  assert.equal(f.events.filter(row => row.op === 'generate').length, 1);
});

test('missing HUKS key with existing ciphertext is not first use, including subsequent UI-style empty save', async t => {
  const f = await secretsFixture(t);
  await f.request('write', { key: 'hosted_links', value: '[{"secret":"saved"}]' });
  const before = await fs.readFile(f.vaultPath); f.keys.clear();
  for (const [method, args] of [['read', { key: 'hosted_links' }], ['readAll', {}], ['write', { key: 'hosted_links', value: '[]' }], ['delete', { key: 'hosted_links' }]]) {
    assert.equal((await f.request(method, args)).error, 'secrets_unavailable');
    assert.deepEqual(await fs.readFile(f.vaultPath), before);
  }
  assert.equal(f.events.filter(row => row.op === 'generate').length, 1);
});

test('non-missing key-service errors do not trigger creation or an empty fallback', async t => {
  const f = await secretsFixture(t, { keyQueryError: 12000005 });
  assert.equal((await f.request('write', { key: 'deepseek_api_key', value: 'not-logged' })).error, 'secrets_unavailable');
  assert.equal(f.events.filter(row => row.op === 'generate').length, 0);
  await assert.rejects(fs.stat(f.vaultPath), { code: 'ENOENT' });
});

test('failed ciphertext write preserves the prior vault and does not poison later queued requests', async t => {
  const f = await secretsFixture(t);
  await f.request('write', { key: 'remote.password', value: 'prior' });
  const before = await fs.readFile(f.vaultPath);
  f.change({ beforeWrite: async () => { throw Error('controlled write failure'); } });
  assert.equal((await f.request('write', { key: 'remote.password', value: 'replacement' })).error, 'secrets_io');
  assert.deepEqual(await fs.readFile(f.vaultPath), before);
  assert.deepEqual(await fs.readdir(f.vaultPath.slice(0, f.vaultPath.lastIndexOf('/'))), ['vault-v1.bin']);
  f.change({ beforeWrite: null });
  assert.deepEqual(await f.request('read', { key: 'remote.password' }), { value: 'prior' });
  assert.deepEqual(await f.request('write', { key: 'remote.password', value: 'next' }), { value: null });
});

test('GCM finish failure after partial update never returns unauthenticated plaintext and aborts the session', async t => {
  const f = await secretsFixture(t);
  await f.request('write', { key: 'remote.private-key', value: '秘密'.repeat(50000) });
  const before = await fs.readFile(f.vaultPath);
  f.change({ finishFailure: true });
  const result = await f.request('readAll');
  assert.equal(result.error, 'secrets_unreadable'); assert.equal('value' in result, false);
  assert(f.events.some(row => row.op === 'abort')); assert.equal(f.sessions.size, 0);
  assert.deepEqual(await fs.readFile(f.vaultPath), before);
});

test('detach during encryption prevents publication and replies once; next instance can proceed', async t => {
  const entered = deferred(), release = deferred();
  const f = await secretsFixture(t, { beforeFinish: async ({ encrypt }) => { if (encrypt) { entered.resolve(); await release.promise; } } });
  const pending = f.call(f.channel, 'write', { key: 'retired', value: 'do-not-publish' });
  await entered.promise; f.plugin.onDetachedFromEngine(f.engine); const next = f.attach();
  release.resolve();
  assert.equal((await pending.done).error, 'cancelled'); assert.equal(pending.replies.length, 1);
  await assert.rejects(fs.stat(f.vaultPath), { code: 'ENOENT' });
  f.change({ beforeFinish: null });
  assert.deepEqual(await f.request('write', { key: 'current', value: 'saved' }, next.channel), { value: null });
  assert.deepEqual(await f.request('readAll', {}, next.channel), { value: { current: 'saved' } });
  next.plugin.onDetachedFromEngine(next.engine);
});

test('channel rejects malformed arguments without echoing secrets and keeps retired transport to one reply', async t => {
  const f = await secretsFixture(t);
  assert.deepEqual(await f.request('containsKey', { key: 'unused' }), { missing: true });
  const bad = await f.request('write', { key: 'secret-key', value: { secret: 'secret-value' } });
  assert.equal(bad.error, 'secrets_invalid'); assert(!bad.message.includes('secret-key')); assert(!bad.message.includes('secret-value'));
  f.change({ replyFailure: true });
  const read = f.call(f.channel, 'read', { key: 'absent' });
  assert.deepEqual(await read.done, { value: null }); await new Promise(resolve => setImmediate(resolve));
  assert.equal(read.replies.length, 1);
});
