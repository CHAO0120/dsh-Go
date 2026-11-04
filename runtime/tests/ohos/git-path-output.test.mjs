import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fixture } from './git-owned-fixture.mjs';

// Native Git recorded byte outputs, independent of the OH formatting helper.
const oracle = JSON.parse(await readFile(new URL('./git-path-output-oracle.json', import.meta.url), 'utf8'));
for (const sample of oracle.cases) {
  test(`Git path fields preserve native quoting and NUL bytes: core.quotePath=${JSON.stringify(sample.quotePath)}`, async t => {
    const f = await fixture(t);
    await f.run(['init']);
    for (const name of oracle.names) await writeFile(join(f.dir, name), 'content\n');
    await f.run(['add', '--all']);
    if (sample.quotePath === '-1') {
      // The existing OH setter rejects dash-prefixed values. A repository may
      // nevertheless already contain Git's valid signed boolean integer.
      const config = join(f.dir, '.git/config');
      await writeFile(config, await readFile(config, 'utf8') + '\n[core]\n\tquotePath = -1\n');
    } else if (sample.quotePath !== null) await f.run(['config', 'core.quotePath', sample.quotePath]);
    for (const expected of sample.results) {
      const actual = await f.run(expected.args);
      assert.equal(actual.exitCode, expected.exitCode, expected.args.join(' '));
      assert.equal(actual.stderr, expected.stderr, expected.args.join(' '));
      assert.deepEqual(Buffer.from(actual.stdout), Buffer.from(expected.stdout), expected.args.join(' '));
    }
  });
}
