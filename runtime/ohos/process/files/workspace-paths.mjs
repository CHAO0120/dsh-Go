import { isMainThread } from 'node:worker_threads';
import { posix } from 'node:path';
import { loadGrantBinding } from './authority.mjs';
import { NativeGrantFs } from './grant-fs.mjs';
import { borrowProcessGrantAuthority, processWorkspaceGrant, isLogicalWorkspacePath,
  quarantineProcessGrantRetirement } from './process-authority.mjs';

const rootPattern = /^\/workspaces\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const fail = code => Object.assign(new Error(code), { code });

// DSH-only path operations. Node's filesystem functions remain untouched.
// Capture native methods in the sole preload, before plugins are admitted.
if (isMainThread && process.platform === 'openharmony') {
  let binding, unavailable;
  try {
    borrowProcessGrantAuthority();
    const loaded = loadGrantBinding();
    binding = Object.freeze(Object.fromEntries(['consume', 'stat', 'close'].map(name => {
      if (typeof loaded[name] !== 'function') throw fail('ERR_WORKSPACE_HOST_ABI');
      return [name, loaded[name].bind(loaded)];
    })));
  } catch (error) { unavailable = error; }

  function location(value) {
    if (!isLogicalWorkspacePath(value) || value.includes('\0')) throw fail('ERR_WORKSPACE_SCOPE_UNSUPPORTED');
    const canonical = posix.resolve(value);
    const root = canonical.split('/').slice(0, 3).join('/');
    if (!rootPattern.test(root)) throw fail('ERR_WORKSPACE_SCOPE_UNSUPPORTED');
    return { canonical, root, relative: canonical.slice(root.length) || '/' };
  }

  async function stat(value, signal) {
    signal?.throwIfAborted();
    const { root, relative } = location(value);
    if (unavailable) throw unavailable;
    let grant;
    try { grant = processWorkspaceGrant(root); }
    catch (error) {
      if (error.code !== 'ERR_WORKSPACE_UNAVAILABLE') throw error;
      throw Object.assign(new Error('文件夹授权当前不可用，请在系统选择器中重新选择该文件夹。', { cause: error }),
        { code: 'ENOENT', reason: 'ERR_WORKSPACE_REAUTHORIZATION_REQUIRED' });
    }
    const lease = borrowProcessGrantAuthority().issue([grant], { readOnly: true, workspaceRoot: root });
    let fs;
    try {
      fs = new NativeGrantFs(binding, lease.mounts[0].ticket);
      const info = await fs.stat(relative);
      signal?.throwIfAborted();
      return { ...info, isDirectory: () => info.isDirectory, isFile: () => info.isFile };
    } finally {
      try { fs?.close(); }
      finally {
        let drained = false;
        try { drained = lease.retire(); }
        catch (error) {
          quarantineProcessGrantRetirement();
          throw Object.assign(fail('ERR_WORKSPACE_DRAIN'), { cause: error });
        }
        if (!drained) {
          quarantineProcessGrantRetirement();
          throw fail('ERR_WORKSPACE_DRAIN');
        }
      }
    }
  }

  async function realpath(value) {
    const { canonical, root } = location(value);
    if (canonical !== root) throw fail('ERR_WORKSPACE_SCOPE_UNSUPPORTED');
    if (!(await stat(root)).isDirectory()) throw fail('ENOTDIR');
    return root;
  }

  async function directory(value, cwd, signal) {
    const target = location(posix.resolve(cwd, value));
    if (isLogicalWorkspacePath(cwd) && target.root !== location(cwd).root) throw fail('ERR_WORKSPACE_SCOPE_UNSUPPORTED');
    if (!(await stat(target.canonical, signal)).isDirectory()) throw Object.assign(
      new Error(`工作目录不是文件夹：${JSON.stringify(value)}`), { code: 'ENOTDIR' });
    return target.canonical;
  }

  Object.defineProperty(globalThis, Symbol.for('dsh.go.ohos.workspace-paths'), {
    value: Object.freeze({ handles: isLogicalWorkspacePath, isRoot: value => rootPattern.test(value),
      stat, realpath, directory }), writable: false, configurable: false,
  });
}
