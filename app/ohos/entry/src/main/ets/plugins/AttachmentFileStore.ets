import fs from '@ohos.file.fs';
import fileUri from '@ohos.file.fileuri';

const CHUNK_BYTES = 256 * 1024;
const FILE_BYTES = 200 * 1024 * 1024;
const TOTAL_BYTES = 400 * 1024 * 1024;
const IMAGE_BYTES = 20 * 1024 * 1024;

function integer(value: Object | null | undefined, minimum: number, maximum: number): boolean {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= minimum && value <= maximum;
}

export class AttachmentFileRequest {
  readonly owner: string;
  readonly limit: number;
  readonly maxFileBytes: number;
  readonly maxTotalBytes: number;
  readonly maxImageBytes: number;
  readonly allowEmpty: boolean;

  constructor(owner: string, limit: number, fileBytes: number, totalBytes: number,
    imageBytes: number, allowEmpty: boolean) {
    this.owner = owner; this.limit = limit; this.maxFileBytes = fileBytes;
    this.maxTotalBytes = totalBytes; this.maxImageBytes = imageBytes; this.allowEmpty = allowEmpty;
  }

  static parse(args: Map<string, Object | null> | null): AttachmentFileRequest | null {
    if (!(args instanceof Map)) return null;
    const owner = args.get('owner');
    if (typeof owner !== 'string' || !/^[A-Za-z0-9._:-]{1,160}$/.test(owner) ||
        !integer(args.get('limit'), 1, 9) || !integer(args.get('maxFileBytes'), 0, FILE_BYTES) ||
        !integer(args.get('maxTotalBytes'), 0, TOTAL_BYTES) ||
        !integer(args.get('maxImageBytes'), 0, IMAGE_BYTES) || typeof args.get('allowEmpty') !== 'boolean') return null;
    return new AttachmentFileRequest(owner, args.get('limit') as number, args.get('maxFileBytes') as number,
      args.get('maxTotalBytes') as number, args.get('maxImageBytes') as number, args.get('allowEmpty') as boolean);
  }
}

export class AttachmentFileRetired extends Error {}
class AttachmentFileRejected extends Error {
  readonly reason: string;
  constructor(reason: string) { super(reason); this.reason = reason; }
}

function requireCurrent(current: () => boolean): void {
  if (!current()) throw new AttachmentFileRetired();
}

function imagePrefix(bytes: Uint8Array): boolean {
  const at = (start: number, expected: number[]): boolean => {
    if (bytes.byteLength < start + expected.length) return false;
    for (let i = 0; i < expected.length; i++) if (bytes[start + i] !== expected[i]) return false;
    return true;
  };
  return at(0, [137, 80, 78, 71, 13, 10, 26, 10]) || at(0, [255, 216, 255]) ||
    at(0, [71, 73, 70, 56]) || (at(0, [82, 73, 70, 70]) && at(8, [87, 69, 66, 80]));
}

export class AttachmentFileEntry {
  readonly name: string;
  readonly path: string | null;
  readonly size: number;
  readonly problem: string | null;
  constructor(name: string, path: string | null, size: number, problem: string | null) {
    this.name = name; this.path = path; this.size = size; this.problem = problem;
  }
  toMap(): Map<string, Object | null> {
    return new Map<string, Object | null>([['name', this.name], ['path', this.path],
      ['size', this.size], ['problem', this.problem]]);
  }
}

// Only DocumentViewPicker supplies source URIs. Names are display metadata;
// private filenames are numeric within an atomically created unique directory.
export class AttachmentFileBatch {
  private directory: string | null = null;
  private readonly paths: string[] = [];
  private readonly cacheDir: string;
  constructor(cacheDir: string) { this.cacheDir = cacheDir; }

  async copy(uris: string[], request: AttachmentFileRequest, current: () => boolean): Promise<AttachmentFileEntry[]> {
    requireCurrent(current);
    this.directory = await fs.mkdtemp(this.cacheDir + '/dsh-attachments-XXXXXX');
    requireCurrent(current);
    const entries: AttachmentFileEntry[] = [];
    let used = 0;
    const count = Math.min(uris.length, request.limit);
    for (let index = 0; index < count; index++) {
      requireCurrent(current);
      const entry = await this.copyOne(uris[index], index, request, request.maxTotalBytes - used, current);
      entries.push(entry);
      if (entry.problem === null) used += entry.size;
    }
    if (uris.length > request.limit) entries.push(new AttachmentFileEntry('', null, 0, 'too_many'));
    return entries;
  }

  private async copyOne(uri: string, index: number, request: AttachmentFileRequest,
    remaining: number, current: () => boolean): Promise<AttachmentFileEntry> {
    let name = 'file';
    const path = this.directory + '/' + index.toString();
    try {
      name = new fileUri.FileUri(uri).name || name;
      requireCurrent(current);
      const input = await fs.open(uri, fs.OpenMode.READ_ONLY | fs.OpenMode.NONBLOCK);
      let size = 0;
      try {
        const metadata = await fs.stat(input.fd);
        if (metadata.size > request.maxFileBytes) throw new AttachmentFileRejected('file_too_large');
        if (metadata.size > remaining) throw new AttachmentFileRejected('total_too_large');
        requireCurrent(current);
        const output = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY |
          fs.OpenMode.TRUNC | fs.OpenMode.NOFOLLOW);
        this.paths.push(path);
        try {
          const buffer = new ArrayBuffer(CHUNK_BYTES);
          const prefix = new Uint8Array(12);
          let prefixSize = 0;
          let image = false;
          while (true) {
            requireCurrent(current);
            const budget = image ? Math.min(request.maxFileBytes, request.maxImageBytes) : request.maxFileBytes;
            const length = Math.min(CHUNK_BYTES, budget - size + 1, remaining - size + 1);
            const count = await fs.read(input.fd, buffer, { offset: size, length: length });
            requireCurrent(current);
            if (!Number.isInteger(count) || count < 0 || count > length) throw new Error('Invalid read count');
            if (count === 0) break;
            const bytes = new Uint8Array(buffer, 0, count);
            const take = Math.min(prefix.length - prefixSize, count);
            prefix.set(bytes.subarray(0, take), prefixSize); prefixSize += take;
            image = request.maxImageBytes > 0 && imagePrefix(prefix.subarray(0, prefixSize));
            const actualBudget = image ? Math.min(request.maxFileBytes, request.maxImageBytes) : request.maxFileBytes;
            if ((image && metadata.size > actualBudget) || count > actualBudget - size)
              throw new AttachmentFileRejected(image ? 'image_too_large' : 'file_too_large');
            if (count > remaining - size) throw new AttachmentFileRejected('total_too_large');
            let written = 0;
            while (written < count) {
              requireCurrent(current);
              // SDK offset is the FILE offset. A short write must also advance
              // the buffer view; passing the original buffer would repeat bytes.
              const part = buffer.slice(written, count);
              const accepted = await fs.write(output.fd, part, { offset: size + written });
              if (!Number.isInteger(accepted) || accepted <= 0 || accepted > part.byteLength)
                throw new Error('Invalid write count');
              written += accepted;
            }
            size += count;
          }
          if (size === 0 && !request.allowEmpty) throw new AttachmentFileRejected('empty');
        } finally { await fs.close(output); }
      } finally { await fs.close(input); }
      requireCurrent(current);
      return new AttachmentFileEntry(name, path, size, null);
    } catch (error) {
      await this.remove(path);
      if (error instanceof AttachmentFileRetired) throw error;
      return new AttachmentFileEntry(name, null, 0,
        error instanceof AttachmentFileRejected ? error.reason : 'unreadable');
    }
  }

  private async remove(path: string): Promise<void> {
    const index = this.paths.indexOf(path);
    if (index < 0) return;
    await fs.unlink(path);
    this.paths.splice(index, 1);
  }

  async release(): Promise<void> {
    for (const path of this.paths.slice()) await this.remove(path);
    if (this.directory !== null) {
      await fs.rmdir(this.directory);
      this.directory = null;
    }
  }
}
