import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve, isAbsolute } from 'node:path';
import { pathToFileURL } from 'node:url';

const base = join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai');
const load = name => import(pathToFileURL(join(base, name, 'lib/index.js')));
const { Context } = await load('cordis');
const { SystemPrompt } = await load('dsh-system-prompt');
const { ToolRuntime } = await load('dsh-tools');
const { LocalSubprocessRuntime } = await load('dsh-subprocess-local');
const { applyGlobTool } = await load('dsh-tool-fs-search');

async function fixture(t, names) {
  const dir = await mkdtemp(join(tmpdir(), 'glob-path-framing-'));
  const ctx = new Context();
  t.after(async () => {
    try { await ctx.fiber.dispose(); }
    finally { await rm(dir, { recursive: true, force: true }); }
  });
  for (const name of names) await writeFile(join(dir, name), `content:${name}`, 'utf8');
  await ctx.plugin(SystemPrompt, {});
  await ctx.plugin(ToolRuntime, {});
  await ctx.plugin(LocalSubprocessRuntime);
  await ctx.plugin({ inject: ['systemPrompt', 'tools', 'subprocess'], apply(ctx) {
    applyGlobTool(ctx, {
      maxResults: 100, maxMetaBytes: 100000, rawOutputMaxBytes: 100000,
      graceMs: 100, stderrMaxBytes: 4096, timeoutMs: 30000,
      sampleOverCapGlobResults: false,
    });
  } });
  const tool = ctx.tools.get('glob');
  assert.ok(tool, 'actual glob tool registered');
  const run = pattern => tool.execute({ pattern, path: dir }, { signal: t.signal });
  const absolute = path => isAbsolute(path) ? path : resolve(process.cwd(), path);
  return { dir, tool, run, absolute };
}

test('glob preserves a real LF filename as one canonical path', {
  skip: process.platform === 'win32' ? 'Windows forbids LF in filenames' : false,
  timeout: 30000,
}, async t => {
  const names = ['alpha\nbeta.txt', 'normal.txt'];
  const { dir, tool, run, absolute } = await fixture(t, names);
  const value = await run('*.txt');
  assert.deepEqual(value.paths.map(absolute).sort(), names.map(name => join(dir, name)).sort());
  assert.equal(value.paths.length, 2);
  const meta = tool.output.presentationMeta({}, value);
  assert.equal(meta.total, 2);
  assert.equal(meta.truncated, false);
  assert.deepEqual(meta.paths, value.paths);
  for (const path of value.paths) {
    const expectedName = names.find(name => join(dir, name) === absolute(path));
    assert.equal(await readFile(absolute(path), 'utf8'), `content:${expectedName}`);
  }
});

test('glob preserves legal boundary whitespace and ordinary filtering', {
  skip: process.platform === 'win32' ? 'POSIX boundary whitespace coverage' : false,
  timeout: 30000,
}, async t => {
  const names = [' leading.txt', 'trailing.txt ', 'normal.txt', 'other.bin'];
  const { dir, run, absolute } = await fixture(t, names);
  const all = await run('*');
  assert.deepEqual(all.paths.map(absolute).sort(), names.map(name => join(dir, name)).sort());
  const filtered = await run('*.bin');
  assert.deepEqual(filtered.paths.map(absolute), [join(dir, 'other.bin')]);
  assert.deepEqual((await run('*.absent')).paths, []);
});
