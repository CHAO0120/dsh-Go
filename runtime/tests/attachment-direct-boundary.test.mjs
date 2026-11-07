import test from 'node:test';
import assert from 'node:assert/strict';
import { constants } from 'node:fs';
import { mkdtemp, mkdir, open, chmod, realpath, symlink, writeFile, readFile, rename, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createPaths } from '../direct/paths.mjs';

const directKey = Symbol.for('dsh.go.direct');
const payload = Buffer.from([0, 1, 255, 128, 65, 10]);
let loaded;
async function api() {
  if (!loaded) {
    const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
    assert(prefix, 'setup: prepared locked runtime prefix is required');
    const load = name => import(pathToFileURL(join(resolve(prefix), 'node_modules/@deepseek-ai', name, 'lib/index.js')));
    loaded = Promise.all(['cordis', 'dsh-attachment-local'].map(load))
      .then(parts => Object.assign({}, ...parts));
  }
  return loaded;
}
function permissionPlatform(t) {
  if (process.platform !== 'linux' || typeof process.geteuid !== 'function' || process.geteuid() === 0) {
    t.skip('requires ordinary non-root Linux directory permissions; not a semantic pass');
    return false;
  }
  return true;
}
async function syncDirectory(path) {
  const handle = await open(path, constants.O_RDONLY);
  try { await handle.sync(); } finally { await handle.close(); }
}
async function fixture(t) {
  const a = await api();
  const temp = await realpath(await mkdtemp(join(tmpdir(), 'dsh-attachment-boundary-')));
  const denied = join(temp, 'denied');
  const rootfs = join(denied, 'rootfs');
  const home = join(rootfs, 'root', '.dsh');
  const previous = Object.getOwnPropertyDescriptor(globalThis, directKey);
  const permissions = [];
  const ctx = new a.Context();
  t.after(async () => {
    if (previous) Object.defineProperty(globalThis, directKey, previous);
    else delete globalThis[directKey];
    try {
      for (const path of permissions) await chmod(path, 0o700);
    } finally {
      try { await ctx.fiber.dispose(); }
      finally { await rm(temp, { recursive: true, force: true }); }
    }
  });
  await mkdir(join(rootfs, 'root'), { recursive: true, mode: 0o700 });
  assert.equal(await realpath(rootfs), rootfs, 'setup: root spelling must be physical before restricting permissions');
  // Establish the caller-vouched fixture boundary before removing parent read access.
  for (const path of [join(rootfs, 'root'), rootfs, denied, temp, dirname(temp)]) await syncDirectory(path);
  globalThis[directKey] = Object.freeze(createPaths(rootfs));
  async function mount(dshHome = home) {
    await ctx.plugin(a.LocalAttachmentStore, { dshHome });
    assert(ctx.attachments, 'setup: actual attachment service must be mounted');
    return ctx.attachments;
  }
  async function denyRead(path) {
    permissions.push(path);
    await chmod(path, 0o111);
    let handle;
    try {
      handle = await open(path, constants.O_RDONLY);
    } catch (error) {
      if (error.code === 'EACCES') return true;
      throw error;
    } finally {
      if (handle) await handle.close();
    }
    t.skip('directory open still succeeds: permission precondition ineffective, not a semantic pass');
    return false;
  }
  return { ctx, temp, denied, rootfs, home, mount, denyRead };
}
async function readExact(store, ref) {
  const chunks = [];
  for await (const chunk of store.readFileStream(ref)) chunks.push(chunk);
  return Buffer.concat(chunks);
}
function deniedAt(path) {
  return error => error.code === 'ATTACHMENT_WRITE_FAILED'
    && error.cause?.code === 'EACCES' && error.cause?.syscall === 'open'
    && error.cause?.path === path;
}

test('direct public save stops at the vouched physical root, then reads exact bytes', async t => {
  if (!permissionPlatform(t)) return;
  const f = await fixture(t);
  const store = await f.mount();
  if (!await f.denyRead(f.denied)) return;
  let ref;
  try {
    ref = await store.saveFile({ data: payload, name: 'boundary.bin' });
  } catch (error) {
    t.diagnostic(JSON.stringify({ code: error.code, causeCode: error.cause?.code,
      causeSyscall: error.cause?.syscall, causePath: error.cause?.path, expectedDenied: f.denied }));
    throw error;
  }
  assert.deepEqual(await readExact(store, ref), payload);
  assert.deepEqual(await readdir(join(f.home, 'attachments', 'v1', 'tmp')), []);
});

test('direct root directory itself must sync; failure is not cached and recovery works', async t => {
  if (!permissionPlatform(t)) return;
  const f = await fixture(t);
  const store = await f.mount();
  if (!await f.denyRead(f.rootfs)) return;
  await assert.rejects(store.saveFile({ data: payload, name: 'root-sync.bin' }), deniedAt(f.rootfs));
  await chmod(f.rootfs, 0o700);
  const ref = await store.saveFile({ data: payload, name: 'root-sync.bin' });
  assert.deepEqual(await readExact(store, ref), payload);
});

test('direct internal file obstacle remains an error and can be repaired without losing it', async t => {
  if (process.platform !== 'linux') return t.skip('Linux directory durability contract');
  const f = await fixture(t);
  await mkdir(f.home, { recursive: true });
  const obstacle = join(f.home, 'attachments');
  await writeFile(obstacle, 'preserve internal obstacle');
  const store = await f.mount();
  await assert.rejects(store.saveFile({ data: payload, name: 'internal.bin' }), error =>
    error.code === 'ATTACHMENT_WRITE_FAILED' && ['EEXIST', 'ENOTDIR'].includes(error.cause?.code));
  assert.equal(await readFile(obstacle, 'utf8'), 'preserve internal obstacle');
  const preserved = join(f.home, 'preserved-obstacle');
  await rename(obstacle, preserved);
  const ref = await store.saveFile({ data: payload, name: 'internal.bin' });
  assert.deepEqual(await readExact(store, ref), payload);
  assert.equal(await readFile(preserved, 'utf8'), 'preserve internal obstacle');
});

test('home outside the direct root does not acquire the shorter boundary', async t => {
  if (!permissionPlatform(t)) return;
  const f = await fixture(t);
  const external = join(f.denied, 'external', '.dsh');
  await mkdir(external, { recursive: true });
  globalThis[directKey] = Object.freeze(createPaths(f.rootfs, [
    { guest: '/external', host: join(f.denied, 'external') },
  ]));
  const store = await f.mount('/external/.dsh');
  assert.equal(store.root, join(external, 'attachments', 'v1'), 'setup: guest mount must select the physical external store');
  if (!await f.denyRead(f.denied)) return;
  await assert.rejects(store.saveFile({ data: payload, name: 'outside.bin' }), deniedAt(f.denied));
});

test('home symlink escaping the direct root retains the original ancestor walk', async t => {
  if (!permissionPlatform(t)) return;
  const f = await fixture(t);
  const external = join(f.denied, 'external', '.dsh');
  await mkdir(external, { recursive: true });
  await symlink(external, f.home, 'dir');
  const store = await f.mount();
  if (!await f.denyRead(f.denied)) return;
  await assert.rejects(store.saveFile({ data: payload, name: 'link.bin' }), deniedAt(f.denied));
});

test('two concurrent first public saves retain both contents and clean their temporary files', async t => {
  if (process.platform !== 'linux') return t.skip('Linux directory durability contract');
  const f = await fixture(t);
  const store = await f.mount();
  const other = Buffer.from('second immutable object');
  const [first, second] = await Promise.all([
    store.saveFile({ data: payload, name: 'first.bin' }),
    store.saveFile({ data: other, name: 'second.bin' }),
  ]);
  assert.deepEqual(await readExact(store, first), payload);
  assert.deepEqual(await readExact(store, second), other);
  assert.deepEqual(await readdir(join(f.home, 'attachments', 'v1', 'tmp')), []);
});
