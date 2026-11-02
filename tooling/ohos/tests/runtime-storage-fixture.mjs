import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { promisify } from 'node:util';

export const fileIo = {
  OpenMode: {
    CREATE: fs.constants.O_CREAT, READ_WRITE: fs.constants.O_RDWR,
    TRUNC: fs.constants.O_TRUNC, NOFOLLOW: fs.constants.O_NOFOLLOW,
    READ_ONLY: fs.constants.O_RDONLY, DIR: fs.constants.O_DIRECTORY,
  },
  async access(path) {
    try { await fsp.access(path); return true; } catch (error) {
      if (error.code === 'ENOENT' || error.code === 'ENOTDIR') return false;
      throw error;
    }
  },
  lstat: fsp.lstat, rename: fsp.rename, unlink: fsp.unlink,
  async mkdir(path) {
    try { await fsp.mkdir(path); } catch (error) {
      if (error.code === 'EEXIST') error.code = 13900015;
      throw error;
    }
  },
  async readText(path) { return await fsp.readFile(path, 'utf8'); },
  async open(path, flags) {
    const handle = await fsp.open(path, flags, 0o600);
    return { fd: handle.fd, handle };
  },
  async close(file) { await file.handle.close(); },
  async fsync(fd) { await promisify(fs.fsync)(fd); },
  async read(fd, buffer, options) {
    return (await promisify(fs.read)(fd, Buffer.from(buffer), 0, options.length ?? buffer.byteLength, options.offset)).bytesRead;
  },
  async write(fd, buffer, options) {
    return (await promisify(fs.write)(fd, Buffer.from(buffer), 0, buffer.byteLength, options.offset)).bytesWritten;
  },
  async listFile(path, options) { return (await fsp.readdir(path)).slice(0, options.listNum || undefined); },
  // OH's rmdir is recursive. The production adapter must check for foreign entries first.
  async rmdir(path) { await fsp.rm(path, { recursive: true }); },
};

export const fileHash = {
  async hash(path, algorithm) { return createHash(algorithm).update(await fsp.readFile(path)).digest('hex'); },
};
export const util = {
  TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
  TextDecoder: class {
    static create(encoding, options) { return { decodeToString: bytes => new TextDecoder(encoding, options).decode(bytes) }; }
  },
};

export class PackedResources {
  constructor(path, entries) {
    this.path = path;
    this.entries = entries;
    this.opened = new Map();
    this.reads = [];
  }

  async getRawFd(asset) {
    const entry = this.entries[asset];
    if (!entry) throw new Error(`fixture asset missing: ${asset}`);
    const handle = await fsp.open(this.path, 'r');
    this.opened.set(asset, handle);
    this.reads.push(asset);
    return { fd: handle.fd, offset: entry.offset, length: entry.length };
  }

  async closeRawFd(asset) {
    await this.opened.get(asset).close();
    this.opened.delete(asset);
  }
}

export async function makePack(path, files, version = 'v1') {
  const chunks = [Buffer.from('not-a-runtime-prefix\n')];
  let offset = chunks[0].length;
  const entries = {};
  const manifest = { schema: 1, runtimeVersion: version, dshVersion: '0.2.1-rc.4', nodeVersion: '24.22.1', files: [] };
  for (const [name, text] of Object.entries(files)) {
    const bytes = Buffer.from(text);
    entries['dsh-runtime/files/' + name] = { offset, length: bytes.length };
    chunks.push(bytes);
    offset += bytes.length;
    manifest.files.push({ path: name, size: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') });
  }
  chunks.push(Buffer.from('\nnot-a-runtime-suffix'));
  await fsp.writeFile(path, Buffer.concat(chunks));
  return { resources: new PackedResources(path, entries), manifest };
}
