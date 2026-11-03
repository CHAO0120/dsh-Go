import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { commandsFor, NODE_SUITES, runSuites } from './node-suites.mjs';
import { HEAVY_JOBS } from './policy.mjs';

const root = fileURLToPath(new URL('../../../', import.meta.url));

test('every tracked default npm test entry is included in a required suite', () => {
  const files = execFileSync('git', ['ls-files', '-z', '--', '**/package.json'], { cwd: root, encoding: 'utf8' })
    .split('\0').filter(Boolean);
  const entries = [];
  for (const file of files) {
    // Read the commit, not a potentially sparse working tree or installed node_modules.
    const pkg = JSON.parse(execFileSync('git', ['show', `HEAD:${file}`], { cwd: root, encoding: 'utf8' }));
    if (pkg.scripts?.test) entries.push(file.slice(0, -'/package.json'.length));
  }
  const covered = Object.values(NODE_SUITES).flat().map(suite => suite.directory);
  assert.ok(entries.length > 10, 'do not silently accept a partial or empty inventory');
  assert.deepEqual([...new Set(covered)].sort(), entries.sort());
  assert.equal(covered.length, new Set(covered).size);
  const workflow = readFileSync(new URL('../../workflows/pr-tests.yml', import.meta.url), 'utf8');
  assert.match(workflow, /node --test \.github\/scripts\/pr-tests\/\*\.test\.mjs/);
  const jobs = [...workflow.split('\njobs:')[1].matchAll(/^  ([A-Za-z_][A-Za-z0-9_-]*):/gm)].map(match => match[1]);
  assert.deepEqual(jobs.sort(), ['plan', 'light', 'gate', ...HEAVY_JOBS].sort());
  const gateNeeds = workflow.split('\n  gate:')[1].match(/needs: \[([^\]]+)\]/)[1].split(',').map(job => job.trim());
  assert.deepEqual(gateNeeds.sort(), ['plan', 'light', ...HEAVY_JOBS].sort());
  for (const group of Object.keys(NODE_SUITES)) {
    assert.ok(HEAVY_JOBS.includes(group), group);
    assert.ok(workflow.includes(`node .github/scripts/pr-tests/node-suites.mjs ${group}`), group);
  }
});

test('package dependencies include dev tools but never run install lifecycle scripts', () => {
  for (const suite of Object.values(NODE_SUITES).flat()) {
    const commands = commandsFor(suite);
    assert.ok(commands.some(({ command, args }) => command === 'npm' && args.join(' ') === 'run test'), suite.directory);
    if (suite.install) {
      assert.ok(commands[0].args.includes('--include=dev'));
      assert.ok(commands[0].args.includes('--ignore-scripts'));
    }
    for (const { args } of commands) {
      assert.ok(!args.includes('--if-present'), 'missing scripts must fail, not silently skip');
      assert.ok(!args.some(arg => /^(dev|deploy|publish|smoke|watch)(:|$)/.test(arg)));
    }
  }
});

test('a failing package stops its group and cannot look like a successful test', () => {
  let calls = 0;
  assert.throws(() => runSuites('web', () => { calls++; throw new Error('synthetic package failure'); }), /synthetic package failure/);
  assert.equal(calls, 1);
  assert.throws(() => runSuites('missing', () => {}), /Unknown Node test group/);
});
