import test from 'node:test';
import assert from 'node:assert/strict';
import fsp from 'node:fs/promises';
import { attachmentFixture, deferred, until } from './attachment-files-fixture.mjs';

const request = (owner = 'test-1', extra = {}) => ({ owner, limit: 9, maxFileBytes: 200 * 1024 * 1024,
  maxTotalBytes: 400 * 1024 * 1024, maxImageBytes: 20 * 1024 * 1024, allowEmpty: false, ...extra });
async function pick(f, uris, extra = {}, owner = 'test-1') {
  const call = f.invoke('pick', request(owner, extra));
  f.select(uris);
  const reply = await call.done;
  assert(!reply.error, JSON.stringify(reply));
  return reply.value;
}
async function release(f, owner = 'test-1') {
  assert.deepEqual(await f.invoke('release', { owner }).done, { value: null });
  assert.deepEqual(await f.cached(), []);
  assert.equal(f.descriptors.size, 0);
}

test('public URI bytes stream to unique private paths; short read/write offsets and Unicode names survive', async t => {
  const f = await attachmentFixture(t, { maxRead: 3, maxWrite: 1 });
  const a = Buffer.from('中文\nfirst'), b = Buffer.from('second\0末');
  const entries = await pick(f, [await f.file('同名.txt', a), await f.file('同名.txt', b)]);
  assert.deepEqual(entries.map(v => v.name), ['同名.txt', '同名.txt']);
  assert.notEqual(entries[0].path, entries[1].path);
  assert.deepEqual(await fsp.readFile(entries[0].path), a);
  assert.deepEqual(await fsp.readFile(entries[1].path), b);
  assert.deepEqual(entries.map(v => v.size), [a.length, b.length]);
  assert.equal(f.descriptors.size, 0);
  assert(f.operations.filter(v => v.op === 'read').every(v => v.length <= 256 * 1024));
  assert.equal((await f.invoke('pick', request('next')).done).error, 'ohos_attachment_busy');
  await f.invoke('release', { owner: 'not-the-owner' }).done;
  assert.equal((await fsp.readFile(entries[0].path)).length, a.length);
  await release(f);
});

test('a rejected item preserves selection order and later valid items within the remaining total budget', async t => {
  const f = await attachmentFixture(t);
  const entries = await pick(f, [await f.file('a', '123456'), await f.file('too-big', '12345678'),
    await f.file('c', 'abc')], { maxFileBytes: 8, maxTotalBytes: 10 });
  assert.deepEqual(entries.map(v => [v.name, v.size, v.problem]),
    [['a', 6, null], ['too-big', 0, 'total_too_large'], ['c', 3, null]]);
  assert.equal(await fsp.readFile(entries[2].path, 'utf8'), 'abc');
  await release(f);
});

test('stale metadata cannot authorize extra bytes and exact limit still permits EOF', async t => {
  const f = await attachmentFixture(t, { reportedSize: 0, maxRead: 3 });
  const entries = await pick(f, [await f.file('growth', '123456'), await f.file('exact', 'abcde')],
    { maxFileBytes: 5, maxTotalBytes: 5 });
  assert.equal(entries[0].problem, 'file_too_large');
  assert.equal(entries[0].path, null);
  assert.equal(entries[1].problem, null);
  assert.equal(await fsp.readFile(entries[1].path, 'utf8'), 'abcde');
  const files = (await f.cached()).filter(v => /\/\d+$/.test(v));
  assert.equal(files.length, 1);
  await release(f);
});

test('split true image prefix enforces image budget and does not spend the next file total', async t => {
  const f = await attachmentFixture(t, { reportedSize: 0, maxRead: 2 });
  const png = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4]);
  const entries = await pick(f, [await f.file('image.txt', png), await f.file('binary.png', 'abc')],
    { maxFileBytes: 20, maxTotalBytes: 20, maxImageBytes: 8 });
  assert.equal(entries[0].problem, 'image_too_large');
  assert.equal(entries[1].problem, null);
  assert.equal(await fsp.readFile(entries[1].path, 'utf8'), 'abc');
  await release(f);
});

for (const failure of ['read', 'write']) {
  test(`partial ${failure} failure closes both streams, deletes partial cache, and preserves a later file`, async t => {
    let count = 0;
    const f = await attachmentFixture(t, { maxRead: 2, maxWrite: 1,
      [failure]: () => { if (++count === 2) throw new Error('controlled I/O failure'); } });
    const entries = await pick(f, [await f.file('failed', 'abcdef'), await f.file('good', 'xyz')]);
    assert.equal(entries[0].problem, 'unreadable');
    assert.equal(entries[0].path, null);
    assert.equal(entries[1].problem, null);
    assert.equal(await fsp.readFile(entries[1].path, 'utf8'), 'xyz');
    assert.equal(f.descriptors.size, 0);
    assert.equal((await f.cached()).filter(v => /\/\d+$/.test(v)).length, 1);
    await release(f);
  });
}

test('logical cancellation replies once but retains the physical picker slot until selection settles', async t => {
  const f = await attachmentFixture(t);
  const selected = f.invoke('pick', request());
  await f.invoke('cancel', { owner: 'wrong-owner' }).done;
  assert.equal(selected.replies.length, 0);
  await f.invoke('cancel', { owner: 'test-1' }).done;
  assert.deepEqual(await selected.done, { value: [] });
  assert.equal((await f.invoke('pick', request('next')).done).error, 'ohos_attachment_busy');
  f.select([await f.file('unused', 'private bytes')]);
  await until(() => f.pickers[0].settled);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(await f.cached(), []);
  assert.equal(f.operations.filter(v => v.op === 'open').length, 0);
  const next = f.invoke('pick', request('next')); f.select([]);
  assert.deepEqual(await next.done, { value: [] });
  assert.equal(selected.replies.length, 1);
});

test('Ability retirement during a pending read cleans the undisclosed cache and closes owned descriptors', async t => {
  const gate = deferred(); let entered = false;
  const f = await attachmentFixture(t, { read: async () => { entered = true; await gate.promise; } });
  const selected = f.invoke('pick', request()); f.select([await f.file('key', 'private bytes')]);
  await until(() => entered);
  f.plugin.onDetachedFromAbility();
  assert.deepEqual(await selected.done, { value: [] });
  assert.equal((await f.invoke('pick', request('next')).done).error, 'ohos_attachment_detached');
  gate.resolve();
  await until(() => f.descriptors.size === 0);
  await until(async () => (await f.cached()).length === 0);
  assert.deepEqual(await f.cached(), []);
  assert.equal(selected.replies.length, 1);
  assert.equal(f.operations.filter(v => v.op === 'write').length, 0);
});

test('engine detachment releases an already delivered cache without waiting for Dart to return a token', async t => {
  const f = await attachmentFixture(t);
  const entries = await pick(f, [await f.file('ready', 'abc')]);
  f.plugin.onDetachedFromEngine(f.engine);
  await until(() => f.operations.some(v => v.op === 'unlink' && v.path === entries[0].path));
  await until(async () => (await f.cached()).length === 0);
  assert.deepEqual(await f.cached(), []);
});

test('text mode permits empty files, honors a smaller byte limit and does not treat signatures as images', async t => {
  const f = await attachmentFixture(t, { maxRead: 1 });
  let entries = await pick(f, [await f.file('empty', '')], { limit: 1, maxFileBytes: 0, maxTotalBytes: 0,
    maxImageBytes: 0, allowEmpty: true });
  assert.equal(entries[0].size, 0); assert.equal(entries[0].problem, null); await release(f);
  entries = await pick(f, [await f.file('text', '中文')], { limit: 1, maxFileBytes: 5, maxTotalBytes: 5,
    maxImageBytes: 0, allowEmpty: true });
  assert.equal(entries[0].problem, 'file_too_large'); await release(f);
});

test('failed cache release keeps ownership and busy state, while an explicit retry cleans the remainder', async t => {
  let once = true;
  const f = await attachmentFixture(t, { unlink: () => {
    if (once) { once = false; throw new Error('controlled cache cleanup failure'); }
  } });
  const entries = await pick(f, [await f.file('owned', 'abc')]);
  assert.equal((await f.invoke('release', { owner: 'test-1' }).done).error, 'ohos_attachment_cleanup');
  assert.equal(await fsp.readFile(entries[0].path, 'utf8'), 'abc');
  assert.equal((await f.invoke('pick', request('next')).done).error, 'ohos_attachment_busy');
  await release(f);
  assert.deepEqual(await pick(f, [], {}, 'next'), []);
});

test('invalid budgets do not launch a picker; returned excess selection is bounded and empty cancel creates no cache', async t => {
  const f = await attachmentFixture(t);
  for (const extra of [{ limit: 10 }, { maxFileBytes: 200 * 1024 * 1024 + 1 },
    { maxTotalBytes: 400 * 1024 * 1024 + 1 }, { maxImageBytes: 20 * 1024 * 1024 + 1 }]) {
    assert.equal((await f.invoke('pick', request('invalid', extra)).done).error, 'ohos_attachment_arguments');
  }
  assert.equal(f.pickers.length, 0);
  const entries = await pick(f, [await f.file('first', 'a'), await f.file('second', 'b')], { limit: 1 });
  assert.deepEqual(entries.map(v => v.problem), [null, 'too_many']);
  assert.equal(f.operations.filter(v => v.op === 'open' && v.path.startsWith('file:')).length, 1);
  await release(f);
  assert.deepEqual(await pick(f, []), []); await release(f);
});
