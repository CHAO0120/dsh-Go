import { isMainThread } from 'node:worker_threads';
import { posix } from 'node:path';
import { setImmediate } from 'node:timers/promises';
import { loadGrantBinding } from './authority.mjs';
import { grantFileObservation } from './grant-fs.mjs';
import { borrowProcessGrantAuthority, processWorkspaceGrant, isLogicalWorkspacePath,
  quarantineProcessGrantRetirement } from './process-authority.mjs';

const fail = (code, message = code) => Object.assign(new Error(message), { code });
let binding, unavailable;

// Evaluated by the sole preload before plugins. No writable global bridge.
if (isMainThread && process.platform === 'openharmony') {
  try {
    borrowProcessGrantAuthority();
    const loaded = loadGrantBinding();
    const methods = ['consume', 'statExact', 'openEditInput', 'readEditInput', 'closeEditInput',
      'beginEdit', 'writeEdit', 'closeEdit', 'publishEdit', 'abortEdit', 'close'];
    binding = Object.freeze(Object.fromEntries(methods.map(name => {
      if (typeof loaded[name] !== 'function') throw fail('ERR_WORKSPACE_EDIT_ABI');
      return [name, loaded[name].bind(loaded)];
    })));
  } catch (error) { unavailable = error; }
}

function combined(primary, secondary, stage) {
  return Object.assign(new AggregateError([primary, secondary],
    `${primary?.message ?? String(primary)}; ${stage}: ${secondary?.message ?? String(secondary)}`, { cause: primary }),
  { code: primary?.code ?? secondary?.code });
}

function checkAbort(signal) {
  if (signal?.aborted) throw Object.assign(
    new Error('The operation was aborted', { cause: signal.reason }),
    { name: 'AbortError', code: 'ABORT_ERR' });
}

async function turn(signal) {
  await setImmediate();
  checkAbort(signal);
}

// The trusted sandbox provider supplies its checked target and the same policy.
// Creation acquires nothing; LocalFileSystem invokes the closure under its lock.
export function workspaceEditScope(target, policy, signal) {
  if (process.platform !== 'openharmony' || !isLogicalWorkspacePath(String(target.targetKey))) return;
  return async action => {
    checkAbort(signal);
    if (!isMainThread) throw fail('ERR_WORKSPACE_OWNER');
    if (unavailable) throw unavailable;
    if (!binding) throw fail('ERR_WORKSPACE_OWNER_UNINITIALIZED');
    const canonical = posix.resolve(String(target.targetKey));
    const root = canonical.split('/').slice(0, 3).join('/');
    const relative = canonical.slice(root.length + 1);
    let grant;
    try { grant = processWorkspaceGrant(root); }
    catch (error) {
      if (error.code !== 'ERR_WORKSPACE_UNAVAILABLE') throw error;
      throw Object.assign(new Error('文件夹授权当前不可用，请在系统选择器中重新选择该文件夹。', { cause: error }),
        { code: 'ENOENT', reason: 'ERR_WORKSPACE_REAUTHORIZATION_REQUIRED' });
    }
    if (policy.mode === 'read-only' || !grant.writable) throw fail('EACCES', '授权文件夹没有本次编辑所需的写入权限。');
    const lease = borrowProcessGrantAuthority().issue([grant], { readOnly: false, workspaceRoot: root });
    let handle, result, failure, failed = false, committed = false, publicationAttempted = false, cleanupFailed = false;
    function recordFailure(error, stage) {
      failure = failed ? combined(failure, error, stage) : error;
      failed = true;
    }

    async function probe() {
      await setImmediate();
      if (!committed) checkAbort(signal);
      let info;
      try { info = binding.statExact(handle, relative); }
      catch (error) {
        if (error.code === 'ENOENT' || error.code === 'ENOTDIR') return null;
        throw error;
      }
      if (info.type === 3) throw fail('ELOOP');
      return { ...grantFileObservation(info, grant), mode: info.mode & 0o777 };
    }

    async function read() {
      let opened = false, content, readFailure, readFailed = false;
      try {
        await turn(signal);
        const sizeText = binding.openEditInput(handle, relative);
        opened = true;
        const exactSize = BigInt(sizeText);
        // Node v24.22.1 default fs/promises.readFile checks the initial stat size.
        if (exactSize > 2147483647n) throw Object.assign(
          new RangeError(`File size (${sizeText}) is greater than 2 GiB`), { code: 'ERR_FS_FILE_TOO_LARGE' });
        const size = Number(exactSize);
        let total = 0;
        if (size > 0) {
          const bytes = Buffer.allocUnsafeSlow(size);
          while (true) {
            await turn(signal);
            const part = binding.readEditInput(handle, Math.min(size - total, 524288));
            part.copy(bytes, total);
            total += part.length;
            // A known positive size <=512 KiB also finishes on a positive short read.
            if (part.length === 0 || total === size || size <= 524288) {
              content = bytes.subarray(0, total);
              break;
            }
          }
        } else {
          const parts = [];
          while (true) {
            await turn(signal);
            const part = binding.readEditInput(handle, 65536);
            if (part.length === 0) { content = Buffer.concat(parts, total); break; }
            parts.push(part);
            total += part.length;
          }
        }
      } catch (error) { readFailure = error; readFailed = true; }
      if (opened) {
        try { binding.closeEditInput(handle); }
        catch (error) {
          cleanupFailed = true;
          readFailure = readFailed ? combined(readFailure, error, 'input close failed') : error;
          readFailed = true;
        }
      }
      if (readFailed) throw readFailure;
      return content;
    }

    async function write(content, mode) {
      await turn(signal);
      binding.beginEdit(handle, relative, mode);
      const bytes = Buffer.from(content, 'utf8');
      let offset = 0;
      while (offset < bytes.length) {
        await turn(signal);
        const part = bytes.subarray(offset, Math.min(offset + 1048576, bytes.length));
        const written = binding.writeEdit(handle, part);
        if (written <= 0 || written > part.length) throw fail('EIO', 'workspace edit made invalid write progress');
        offset += written;
      }
      binding.closeEdit(handle);
      await turn(signal);
      publicationAttempted = true;
      // A normal return confirms rename. The bool concerns only directory removal.
      binding.publishEdit(handle);
      committed = true;
    }

    try {
      handle = binding.consume(lease.mounts[0].ticket);
      result = await action(Object.freeze({ probe, read, write }));
    } catch (error) { recordFailure(error, 'workspace edit failed'); }
    if (handle !== undefined) {
      try { binding.abortEdit(handle); }
      catch (error) {
        cleanupFailed = true;
        recordFailure(error, 'workspace edit cleanup failed');
      }
      try { binding.close(handle); }
      catch (error) {
        cleanupFailed = true;
        recordFailure(error, 'workspace lease close failed');
      }
    }
    let drained = false;
    try { drained = lease.retire() === true; }
    catch (error) { recordFailure(error, 'workspace lease retirement failed'); }
    if (!drained) {
      cleanupFailed = true;
      quarantineProcessGrantRetirement();
      recordFailure(fail('ERR_WORKSPACE_DRAIN'), 'workspace lease retirement was not confirmed');
    }
    if (failed) {
      if (committed || publicationAttempted || cleanupFailed) {
        throw Object.assign(new Error(failure?.message ?? String(failure), { cause: failure }), {
          code: failure?.code,
          workspaceEditState: committed ? 'committed' : publicationAttempted ? 'unknown' : 'unpublished',
          workspaceEditCleanupFailed: cleanupFailed,
        });
      }
      throw failure;
    }
    return result;
  };
}
