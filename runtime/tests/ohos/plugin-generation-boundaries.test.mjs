import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, symlink, rm, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const { loadProfile, createRuntimeResolution } = await import(pathToFileURL(join(process.env.DSH_PREFIX, 'node_modules/@deepseek-ai/dsh-app-boot/lib/index.js')));

test('only current OH generation descendants bypass the internal profile exclusion', async t => {
  assert.ok(['linux', 'openharmony'].includes(process.platform), 'run both native Linux and OH simulation variants');
  const root = await mkdtemp(join(tmpdir(), 'ohos-linked-boundary-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const home = join(root, 'home'), dir = join(home, 'profiles', 'a');
  await mkdir(join(dir, 'node_modules'), { recursive: true });
  await writeFile(join(dir, 'package.json'), JSON.stringify({ name: 'a', dependencies: {}, dsh: { profile: { bundles: [] } } }));
  await writeFile(join(dir, 'cordis.yml'), '[]');
  const paths = {
    own: join(dir, '.plugin-manager/ohos/generations/generation-x/pkg'),
    similar: join(dir, '.plugin-manager/ohos/generations-other/pkg'),
    ordinary: join(dir, 'ordinary/pkg'),
    other: join(home, 'profiles/b/.plugin-manager/ohos/generations/generation-x/pkg'),
    external: join(root, 'external/pkg'),
  };
  for (const [name, path] of Object.entries(paths)) {
    await mkdir(path, { recursive: true });
    await writeFile(join(path, 'package.json'), JSON.stringify({ name, version: '1.0.0' }));
    await symlink(path, join(dir, 'node_modules', name));
  }
  const anchor = join(process.env.DSH_PREFIX, 'node_modules/@deepseek-ai/dsh/package.json');
  const profile = loadProfile('dsh', 'a', anchor, home);
  const resolution = await createRuntimeResolution({ installAnchor: anchor, home, profile });
  assert.deepEqual(resolution.linkedRoots.map(root => root.name).sort(), process.platform === 'openharmony' ? ['external', 'own'] : ['external']);
  for (const entry of resolution.linkedRoots) assert.equal(entry.realPath, await realpath(paths[entry.name]));
});
