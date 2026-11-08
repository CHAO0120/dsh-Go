import test from 'node:test';
import assert from 'node:assert/strict';
import { access, readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { ownerFixture, until } from './linux-control-fixture.mjs';

test('progress observer failures do not change verified installation success', async t => {
  const f = await ownerFixture(t, { progress() { throw new Error('display observer failed'); } });
  const owner = f.createOwner(); const result = await owner.install();
  assert.equal(owner.state, 'active'); assert.equal(result.backend.state, 'opened');
  assert.equal(f.counts().created, 1);
});

test('published writable data survives controlled native retirement acknowledgement', async t => {
  const joined = Promise.withResolvers(), f = await ownerFixture(t, { joinBarrier: joined.promise });
  const owner = f.createOwner(), { active } = await owner.install();
  const targetBefore = await readFile(active.target), disposing = owner.dispose();
  await until(() => f.counts().joined === 1);
  await access(active.target); joined.resolve(); const retirement = await disposing;
  assert.deepEqual(await readFile(active.target), targetBefore, 'published target bytes cannot be deleted by shutdown');
  assert.equal(retirement.resourcesRetired, true);
  assert.equal(retirement.filesRemoved, false);
  assert.equal(retirement.dataRetained, true);
  assert.equal(retirement.native.joined, true); assert.equal(retirement.native.retirementError, false);
  assert.equal((await readdir(f.data)).length, 2, 'fixed lock inode remains beside the retained instance');
  assert.equal(retirement.cleanCheckpoint, true);
  assert.equal(JSON.parse(await readFile(join(active.directory, 'instance.json'), 'utf8')).state, 'clean');
  await assert.rejects(access(join(active.directory, 'active.json')), { code: 'ENOENT' });
  await assert.rejects(owner.install(), { code: 'ERR_OHOS_LINUX_OWNER_CLOSED' });
});

test('a live owner rejects another owner before download or VM, without deletion', async t => {
  const f = await ownerFixture(t), first = f.createOwner(), { active } = await first.install();
  let downloaded = 0;
  const { LinuxInstallationOwner } = await import('../../ohos/linux/owner.mjs');
  const second = new LinuxInstallationOwner(f.options, { ...f.internals, download: { fetch() { downloaded++; throw new Error('must not download'); } } });
  await assert.rejects(second.install(), { code: 'ERR_OHOS_LINUX_BUSY' });
  assert.equal(downloaded, 0); assert.equal(f.counts().created, 1); await access(active.target);
  const retirement = await second.dispose(); assert.equal(retirement.filesRemoved, false);
});
