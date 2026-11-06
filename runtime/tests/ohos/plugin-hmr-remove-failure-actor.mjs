import assert from 'node:assert/strict';
import { existsSync, readFileSync, readlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fixture, name, executeTool } from './plugin-package-harness.mjs';
import { toolSource } from './plugin-package-fixture.mjs';
process.on('SIGXFSZ', () => {});
async function barrier(stage, facts = {}) {
  const acknowledged = new Promise(resolve => process.once('message', resolve));
  process.send({ stage, ...facts });
  assert.deepEqual(await acknowledged, { stage });
}
let cleanup, armed = false, f;
try {
  const mode = process.argv[2];
  assert.ok(['terminal', 'zero', 'healthy'].includes(mode));
  const yaml = JSON.stringify([{ insert: [{ id: 'owned-tool', name }] }]);
  const source = toolSource('1.0.0').replace('  ctx.tools.register({',
    '  ctx.effect(() => () => globalThis.__pluginRemoveBarrier());\n  ctx.tools.register({');
  f = await fixture({ name: 'hmr-remove-write-' + mode, after(fn) { cleanup = fn; }, diagnostic() {} },
    { '1.0.0': { yaml, source } }, { hmr: true, profileName: 'hmr-remove-failure' });
  const initial = await f.invoke('installBundle', name + '@1.0.0', { registry: f.registry, enabled: true });
  assert.equal(initial.application, 'applied', JSON.stringify(initial));
  await executeTool(f.ctx, '1.0.0');
  const previous = [...f.ctx.loader.entries()].filter(e => e.options.id !== 'owned-tool' && e.fiber?.state === 2)
    .map(entry => ({ entry, fiber: entry.fiber }));
  const journal = join(f.dir, '.plugin-manager/ohos/transaction.json');
  const link = join(f.dir, 'node_modules', name);
  const beforeLink = readlinkSync(link), beforeManifest = readFileSync(f.manifestPath, 'utf8');
  let predicted;
  globalThis.__pluginRemoveBarrier = async () => {
    if (!armed) return;
    armed = false;
    const record = JSON.parse(readFileSync(journal, 'utf8'));
    assert.equal(record.phase, 'pending'); assert.deepEqual(record.links, []);
    record.links.push({ name, before: readlinkSync(link), after: null });
    predicted = JSON.stringify(record) + '\n';
    const limit = Buffer.byteLength(predicted);
    const committed = JSON.stringify({ ...record, phase: 'committed' }) + '\n';
    assert.equal(Buffer.byteLength(committed), limit + 2);
    // Existing file restoration fits the limit. Only the committed journal grows past it.
    for (const file of record.files) if (file.bytes !== null) assert.ok(Buffer.from(file.bytes, 'base64').length <= limit);
    await barrier('limit', { limit, pendingBytes: limit, committedBytes: limit + 2 });
  };
  armed = true;
  const result = await f.invoke('removeBundle', name);
  for (const { entry, fiber } of previous) {
    assert.equal(entry.fiber, fiber, 'unchanged active services retain their fibers'); assert.equal(fiber.state, 2);
  }
  if (mode === 'healthy') {
    assert.equal(result.application, 'applied', JSON.stringify(result));
    assert.equal(result.packageResult.exitCode, 0);
    assert.equal(f.ctx.tools.get('ohos_installed_echo'), undefined);
    assert.equal(existsSync(link), false); assert.equal(existsSync(journal), false);
    assert.equal(JSON.parse(readFileSync(f.manifestPath, 'utf8')).dependencies[name], undefined);
    process.send({ stage: 'healthy', result });
  } else {
    assert.equal(result.application, 'failed', JSON.stringify(result)); assert.match(result.error.diagnostic, /EFBIG/);
    process.send({stage:'remove-result',mode,result,journalPresent:existsSync(journal),manifest:JSON.parse(readFileSync(f.manifestPath,'utf8')),toolPresent:f.ctx.tools.get('ohos_installed_echo')!==undefined});
    await executeTool(f.ctx, '1.0.0');
    if (mode === 'terminal') {
      assert.equal(result.packageResult?.exitCode, 0, 'remove publication succeeded before terminal failure');
      assert.equal(result.changed, false);
      assert.equal(existsSync(journal), false);
      assert.equal(readlinkSync(link), beforeLink);
      assert.equal(readFileSync(f.manifestPath, 'utf8'), beforeManifest);
      assert.doesNotMatch(result.error.diagnostic, /rollback failed/);
    } else {
      if (result.error.diagnostic.includes('Disk plugin rollback failed:')) assert.match(result.error.diagnostic, /Disk plugin rollback failed:.*EFBIG/);
      assert.doesNotMatch(result.error.diagnostic, /Live plugin rollback failed/);
      assert.equal(JSON.parse(readFileSync(journal, 'utf8')).phase, 'pending');
    }
    await executeTool(f.ctx, '1.0.0');
    process.send({ stage: 'failed', result, toolVersion: '1.0.0', journalPending: existsSync(journal) });
    await barrier('restore');
    writeFileSync(join(f.root, 'writes-restored'), 'actual child write');
    const retry = await f.invoke('installBundle', name + '@1.0.0', { registry: f.registry, enabled: true });
    assert.equal(retry.error?.code, 'already-installed', JSON.stringify(retry));
    await executeTool(f.ctx, '1.0.0');
    assert.equal(existsSync(journal), false);
    assert.equal(readlinkSync(link), beforeLink);
    assert.equal(readFileSync(f.manifestPath, 'utf8'), beforeManifest);
    process.send({ stage: 'recovered', mode, retry, writesRestored: true, journalRemoved: true });
  }
} catch (error) {
  process.send({ stage: 'failure', message: error.message }); console.error(error); process.exitCode = 1;
} finally {
  armed = false;
  await barrier('restore'); await cleanup?.();
  delete globalThis.__pluginRemoveBarrier; process.disconnect();
}
