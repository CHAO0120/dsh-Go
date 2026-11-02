// Exercise the assembled payload, not an npm development tree.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import * as fs from 'node:fs';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const payload = resolve(process.argv[2]);
const reportPath = resolve(process.argv[3]);
const require = createRequire(join(payload, 'package.json'));
const processRequire = createRequire(join(payload, 'runtime/ohos/process/package.json'));
const load = name => import(pathToFileURL(require.resolve(name)));
const rows = [];
const base = await mkdtemp(join(tmpdir(), 'ohos-composition-'));
let runtime;
async function check(name, action) {
  await action();
  rows.push({ name, status: 'PASS' });
  console.log(`PASS ${name}`);
}
try {
  assert.equal(process.versions.node, '24.22.1');
  assert.equal(process.platform, 'openharmony');
  assert.equal(typeof WebAssembly, 'undefined');
  assert(process.execArgv.includes('--jitless'));
  await check('Node built-in SQLite still executes SQL', async () => {
    const { DatabaseSync } = await import('node:sqlite');
    const db = new DatabaseSync(':memory:');
    try {
      db.exec('CREATE TABLE kept (value TEXT)');
      db.prepare('INSERT INTO kept VALUES (?)').run('中文 SQL');
      assert.equal(db.prepare('SELECT value FROM kept').get().value, '中文 SQL');
    } finally { db.close(); }
  });
  await check('isomorphic-git API works without its CLI or minimisted', async () => {
    const git = processRequire('isomorphic-git');
    const dir = join(base, 'git');
    await mkdir(dir);
    await git.init({ fs, dir, defaultBranch: 'main' });
    await writeFile(join(dir, '中文.txt'), 'first\n');
    await git.add({ fs, dir, filepath: '中文.txt' });
    const oid = await git.commit({ fs, dir, message: 'payload API',
      author: { name: 'Local Fixture', email: 'fixture@example.invalid', timestamp: 1, timezoneOffset: 0 } });
    assert.equal((await git.log({ fs, dir, depth: 1 }))[0].oid, oid);
    const gitRoot = dirname(processRequire.resolve('isomorphic-git'));
    assert.equal(fs.existsSync(join(gitRoot, 'cli.cjs')), false);
    assert.throws(() => processRequire.resolve('minimisted'), { code: 'MODULE_NOT_FOUND' });
  });
  await check('locked diff ESM API and license remain', async () => {
    const file = processRequire.resolve('diff/package.json');
    const metadata = JSON.parse(await readFile(file, 'utf8'));
    assert.equal(metadata.version, '8.0.4');
    assert.equal(metadata.license, 'BSD-3-Clause');
    assert.match(await readFile(join(dirname(file), 'LICENSE'), 'utf8'), /Redistribution/);
    const { diffLines, createTwoFilesPatch } = await import(pathToFileURL(join(dirname(file), metadata.exports['.'].import.default)));
    assert(diffLines('before\n', 'after\n').some(part => part.added && part.value === 'after\n'));
    assert.match(createTwoFilesPatch('a/中文', 'b/中文', 'before\n', 'after\n'), /\+after/);
  });
  const { VirtualSubprocessRuntime } = await import(pathToFileURL(join(payload, 'runtime/ohos/process/runtime.mjs')));
  const work = join(base, 'workspace');
  await mkdir(work);
  runtime = new VirtualSubprocessRuntime({ workspaceRoots: [work] });
  async function run(command) {
    const handle = runtime.spawn({ argv: ['bash', '-c', command], cwd: work, graceMs: 200,
      stdio: { stdin: 'ignore', stdout: { maxBytes: 65536 }, stderr: { maxBytes: 65536 } } });
    const outcome = await handle.done;
    return { ...outcome, stdout: handle.collected.stdout.readFrom(0).text,
      stderr: handle.collected.stderr.readFrom(0).text };
  }
  await check('private Bash filesystem still reads/writes and searches Chinese paths', async () => {
    const result = await run('printf "甲\\n乙\\n" > "中文 文件.txt"; cat "中文 文件.txt" | grep 乙');
    assert.equal(result.exitCode, 0);
    assert.equal(result.stdout, '乙\n');
    assert.equal(await readFile(join(work, '中文 文件.txt'), 'utf8'), '甲\n乙\n');
  });
  await check('Python/SQLite/QuickJS commands refuse without missing-module errors', async () => {
    for (const command of ['python3 --version', 'sqlite3 --version', 'js-exec --help']) {
      const result = await run(command);
      assert.equal(result.exitCode, 127, command);
      assert.doesNotMatch(result.stderr, /ERR_MODULE_NOT_FOUND|Cannot find module/);
      assert.match(result.stderr, /not found|不可用/i);
    }
  });
  await check('Office conversion gives explicit alternative without LibreOffice import', async () => {
    const { OfficeToPdf } = await load('@deepseek-ai/dsh-office-to-pdf');
    await assert.rejects(OfficeToPdf.prototype.convertBytes.call({}, Buffer.from('fixture'), 'docx', new AbortController().signal),
      error => error.code === 'unavailable' && /连接电脑/.test(error.message));
    const reason = new Error('explicit caller cancellation');
    await assert.rejects(OfficeToPdf.prototype.convertBytes.call({}, Buffer.from('fixture'), 'docx', AbortSignal.abort(reason)),
      error => error === reason);
  });
  await check('image codec gives explicit alternative instead of missing sharp', async () => {
    const { prepareImageFile } = await load('@deepseek-ai/dsh-attachment-local');
    const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZfQAAAABJRU5ErkJggg==', 'base64');
    await assert.rejects(prepareImageFile({ data: png, mediaType: 'image/png', name: 'fixture.png' },
      { maxImageBytes: 100000, maxPixels: 10000, maxDimension: 100 }, {}),
      error => error.code === 'OHOS_IMAGE_CODEC_UNAVAILABLE' && /电脑/.test(error.message));
  });
  await check('local speech preparation reports unavailability without a native load', async () => {
    const voice = await load('@deepseek-ai/dsh-experimental-speech-to-text-sensevoice');
    let registration, cleanup;
    voice.apply({ speechToText: { register(value) { registration = value; return async () => {}; } },
      effect(callback) { cleanup = callback(); }, logger: { warn() {} } },
      voice.Config({ dataRoot: join(base, 'speech'), idleTimeoutMs: 0 }));
    try {
      await registration.preparation.tail;
      await new Promise(resolve => setImmediate(resolve));
      const state = registration.preparation.snapshot();
      assert.equal(state.phase, 'failed');
      assert.match(state.message, /鸿蒙.*(?:输入法|电脑)/);
    } finally { await cleanup(); }
  });
} finally {
  await runtime?.dispose();
  await rm(base, { recursive: true, force: true });
  await writeFile(reportPath, JSON.stringify({ scope: 'actual assembled payload, Linux strict simulation; not target ABI', rows }, null, 2) + '\n');
}
