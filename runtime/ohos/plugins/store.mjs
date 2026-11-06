import {
  closeSync, constants, existsSync, fsyncSync, lstatSync, mkdirSync, mkdtempSync,
  openSync, readFileSync, readlinkSync, realpathSync, renameSync, rmSync,
  symlinkSync, unlinkSync, writeFileSync,
} from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { randomUUID } from 'node:crypto';

const active = new Map();
const files = ['package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml', 'cordis.patch.yml', 'compatibility.json'];
const packageName = /^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/;
const generationName = /^generation-[A-Za-z0-9]+$/;
const failure = message => Object.assign(new Error(`[OHOS_PLUGIN_STORE] ${message}`), { code: 'ERR_OHOS_PLUGIN_STORE' });

function stat(path) {
  try { return lstatSync(path); }
  catch (error) { if (error.code === 'ENOENT') return; throw error; }
}

function syncDirectory(path) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
  try { fsyncSync(fd); } finally { closeSync(fd); }
}

function directory(parent, name) {
  const path = join(parent, name);
  const info = stat(path);
  if (!info) { mkdirSync(path, { mode: 0o700 }); syncDirectory(parent); }
  else if (!info.isDirectory() || info.isSymbolicLink()) throw failure(`安装目录不是普通目录：${name}`);
  return path;
}

function storeRoot(dir, create = false) {
  const path = join(dir, '.plugin-manager', 'ohos');
  if (!create && !existsSync(path)) return;
  const manager = create ? directory(dir, '.plugin-manager') : join(dir, '.plugin-manager');
  for (const item of [manager, path]) {
    if (create && item === path) directory(manager, 'ohos');
    const info = stat(item);
    if (!info?.isDirectory() || info.isSymbolicLink()) throw failure('插件事务目录包含链接或非目录');
  }
  return path;
}

function regularBytes(path) {
  const info = stat(path);
  if (!info) return null;
  if (!info.isFile() || info.nlink !== 1) throw failure(`配置不是独占普通文件：${path}`);
  return readFileSync(path);
}

function writeAtomic(path, bytes) {
  const temporary = join(dirname(path), `.ohos-write-${randomUUID()}`);
  const fd = openSync(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try {
    writeFileSync(fd, bytes); fsyncSync(fd);
  } catch (error) {
    unlinkSync(temporary); throw error;
  } finally { closeSync(fd); }
  try { renameSync(temporary, path); syncDirectory(dirname(path)); }
  finally { if (stat(temporary)) unlinkSync(temporary); }
}

function removeFile(path) {
  if (!stat(path)) return;
  unlinkSync(path); syncDirectory(dirname(path));
}

function linkPath(dir, name) {
  if (!packageName.test(name)) throw failure('插件包名无效');
  let parent = directory(dir, 'node_modules');
  const parts = name.split('/');
  if (parts.length === 2) parent = directory(parent, parts.shift());
  return join(parent, parts[0]);
}

function ownedTarget(dir, path, target) {
  const root = join(dir, '.plugin-manager', 'ohos', 'generations') + sep;
  const absolute = resolve(dirname(path), target);
  if (!absolute.startsWith(root) || !generationName.test(absolute.slice(root.length).split(sep)[0])) {
    throw failure('已有插件目录不属于鸿蒙安装器，不能覆盖或删除');
  }
  return absolute;
}

function currentLink(dir, path) {
  const info = stat(path);
  if (!info) return null;
  if (!info.isSymbolicLink()) throw failure('已有插件不是鸿蒙管理的版本链接，不能覆盖或删除');
  const target = readlinkSync(path);
  ownedTarget(dir, path, target);
  return target;
}

function replaceLink(path, target) {
  if (target === null) { removeFile(path); return; }
  const temporary = join(dirname(path), `.ohos-link-${randomUUID()}`);
  symlinkSync(target, temporary, 'dir');
  try { renameSync(temporary, path); syncDirectory(dirname(path)); }
  finally { if (stat(temporary)) unlinkSync(temporary); }
}

function validateJournal(record) {
  if (record.schema !== 1 || !['pending', 'committed'].includes(record.phase)
    || !Array.isArray(record.files) || !Array.isArray(record.links) || !Array.isArray(record.created)
    || record.files.length !== files.length || new Set(record.files.map(item => item.name)).size !== files.length
    || record.files.some(item => !files.includes(item.name) || item.bytes !== null && typeof item.bytes !== 'string')
    || record.links.some(item => !packageName.test(item.name) || ![item.before, item.after].every(value => value === null || typeof value === 'string'))
    || record.created.some(name => !generationName.test(name))) throw failure('插件事务记录无效，保留现场并停止加载');
}

function restore(dir, root, record) {
  if (record.links.length || record.created.length) directory(root, 'generations');
  for (const item of record.links) {
    const path = linkPath(dir, item.name);
    const current = currentLink(dir, path);
    if (current !== null && current !== item.before && current !== item.after) throw failure('插件链接已由其他操作改变，不能覆盖');
    if (item.before !== null) ownedTarget(dir, path, item.before);
    replaceLink(path, item.before);
  }
  for (const item of record.files) {
    const path = join(dir, item.name);
    regularBytes(path);
    if (item.bytes === null) removeFile(path);
    else writeAtomic(path, Buffer.from(item.bytes, 'base64'));
  }
  for (const name of record.created) {
    const path = join(root, 'generations', name);
    if (stat(path)?.isSymbolicLink()) throw failure('本次版本目录被链接替换，保留现场');
    rmSync(path, { recursive: true, force: true });
  }
  if (existsSync(join(root, 'generations'))) syncDirectory(join(root, 'generations'));
}

// Called before profile configuration is read. A live operation may itself cause
// resolution reads; those reads must not undo that operation's journal.
export function recoverProfile(dir) {
  if (!existsSync(dir)) return;
  dir = realpathSync(dir);
  if (active.has(dir)) return;
  const root = storeRoot(dir);
  if (!root) return;
  const path = join(root, 'transaction.json');
  const bytes = regularBytes(path);
  if (bytes === null) return;
  const record = JSON.parse(bytes);
  validateJournal(record);
  if (record.phase === 'pending') restore(dir, root, record);
  removeFile(path);
}

export function transactionFor(dir) {
  const transaction = active.get(realpathSync(dir));
  if (!transaction) throw failure('插件操作缺少 profile 写事务');
  return transaction;
}

// The manager holds its existing package.json write lock for this entire lifetime.
export function beginTransaction(dir) {
  if (!isAbsolute(dir)) throw failure('profile 路径必须为绝对路径');
  dir = realpathSync(dir);
  if (active.has(dir)) throw failure('profile 已有未结束的插件操作');
  recoverProfile(dir);
  const root = storeRoot(dir, true);
  const path = join(root, 'transaction.json');
  const record = {
    schema: 1, phase: 'pending',
    files: files.map(name => ({ name, bytes: regularBytes(join(dir, name))?.toString('base64') ?? null })),
    links: [], created: [],
  };
  const save = () => writeAtomic(path, `${JSON.stringify(record)}\n`);
  save();
  const transaction = {
    newGeneration() {
      const parent = directory(root, 'generations');
      const destination = mkdtempSync(join(parent, 'generation-'));
      const name = destination.slice(parent.length + 1);
      record.created.push(name); save(); syncDirectory(parent);
      return destination;
    },
    publish(name, destination) {
      if (record.links.some(item => item.name === name)) throw failure('同一次安装尝试不能重复发布同名插件');
      const targetPath = linkPath(dir, name);
      const target = destination === null ? null : relative(dirname(targetPath), destination);
      if (target !== null) {
        const absolute = ownedTarget(dir, targetPath, target);
        if (realpathSync(absolute) !== absolute || !stat(absolute)?.isDirectory()) throw failure('发布目录不是已验证的真实版本目录');
      }
      const item = { name, before: currentLink(dir, targetPath), after: target };
      record.links.push(item);
      save();
      replaceLink(targetPath, target);
    },
    writeManifest(manifest) { writeAtomic(join(dir, 'package.json'), `${JSON.stringify(manifest, null, 2)}\n`); },
    rollbackAttempt() {
      restore(dir, root, record);
      record.links = []; record.created = []; save();
    },
    finish(success) {
      try {
        if (success) {
          for (const name of files) {
            const file = join(dir, name);
            if (regularBytes(file) === null) continue;
            const fd = openSync(file, constants.O_RDONLY | constants.O_NOFOLLOW);
            try { fsyncSync(fd); } finally { closeSync(fd); }
          }
          syncDirectory(dir);
          record.phase = 'committed'; save();
        } else restore(dir, root, record);
        removeFile(path);
      } finally {
        // A failed terminal write leaves the journal for the next owner to recover.
        active.delete(dir);
      }
    },
  };
  active.set(dir, transaction);
  return transaction;
}
