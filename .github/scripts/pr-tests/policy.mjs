import { execFileSync } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export const HEAVY_JOBS = Object.freeze(['flutter', 'dart', 'sdk', 'runtime', 'python', 'android']);
const ROOT_DOCS = new Set([
  'README.md', 'README.en.md', 'CONTRIBUTING.md', 'CONTRIBUTING.en.md',
  'SECURITY.md', 'SECURITY.en.md', 'LICENSE', '.github/PULL_REQUEST_TEMPLATE.md',
  'sdk/README.md', 'sdk/plugin-kit/README.md', 'sdk/plugin-kit/README.en.md',
]);

function isDocumentation(path) {
  if (typeof path !== 'string' || /[\\\x00-\x1f\x7f\ufffd]/u.test(path) ||
      path.startsWith('/') || path.split('/').some(part => !part || part === '.' || part === '..')) return false;
  if (ROOT_DOCS.has(path)) return true;
  // These two skill entry points control agent behavior, not just help text.
  if (path === 'docs/guide/SKILL.md' || path === 'app/assets/skills/dsh-go-guide/SKILL.md') return false;
  if (path.startsWith('docs/')) return /\.(md|png|jpe?g|webp)$/.test(path);
  return /^app\/assets\/skills\/dsh-go-guide\/(README|(?:zh|en)-[a-z0-9-]+)\.md$/.test(path);
}

export function classifyChanges(changes) {
  if (!Array.isArray(changes) || changes.length === 0) {
    return { mode: 'full', reason: 'No complete non-empty documentation diff; run all suites.' };
  }
  const docsOnly = changes.every(change =>
    change && isDocumentation(change.path) &&
    ['000000', '100644'].includes(change.oldMode) &&
    ['000000', '100644'].includes(change.newMode) &&
    (change.oldMode === '100644' || change.newMode === '100644'));
  return docsOnly
    ? { mode: 'docs', reason: 'Only allowlisted documentation changed; heavy suites are exempt, lightweight checks remain required.' }
    : { mode: 'full', reason: 'Code, configuration, executable files or unknown paths changed; run all suites.' };
}

export function parseRawDiff(data) {
  const text = new TextDecoder('utf-8', { fatal: true }).decode(data);
  if (text === '') return [];
  const fields = text.split('\0');
  if (fields.pop() !== '' || fields.length % 2 !== 0) throw new Error('Incomplete git diff');
  const changes = [];
  for (let i = 0; i < fields.length; i += 2) {
    const header = /^:(\d{6}) (\d{6}) [a-f0-9]+ [a-f0-9]+ [AMDT]$/.exec(fields[i]);
    if (!header || fields[i + 1] === '') throw new Error('Unsupported git diff record');
    changes.push({ oldMode: header[1], newMode: header[2], path: fields[i + 1] });
  }
  return changes;
}

export function evaluateGate(mode, jobs) {
  if (!['docs', 'full'].includes(mode) || jobs?.plan?.result !== 'success') {
    return { pass: false, reason: 'Test classification failed or its output is missing.' };
  }
  if (jobs.light?.result !== 'success') {
    return { pass: false, reason: 'Lightweight checks did not succeed.' };
  }
  for (const name of HEAVY_JOBS) {
    const result = jobs[name]?.result;
    if (mode === 'full' ? result !== 'success' : !['success', 'skipped'].includes(result)) {
      return { pass: false, reason: `${name} did not satisfy the ${mode} test policy (${result ?? 'missing'}).` };
    }
  }
  return { pass: true, reason: mode === 'docs'
    ? 'Documentation exemption: lightweight checks passed; heavy suites were not required. This is not a full-test result.'
    : 'All required automated test suites passed. Device and release integration checks remain separate.' };
}

function summary(text) {
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${text}\n`);
  console.log(text);
}

function main() {
  if (process.argv[2] === 'gate') {
    const verdict = evaluateGate(process.env.PLAN_MODE, JSON.parse(process.env.JOB_RESULTS ?? 'null'));
    summary(`## PR test gate\n\n${verdict.reason}`);
    if (!verdict.pass) process.exitCode = 1;
    return;
  }
  if (process.argv[2] !== 'plan') throw new Error('Expected plan or gate');
  let plan = { mode: 'full', reason: 'Push, merge queue or manual run: run all suites.' };
  if (process.env.GITHUB_EVENT_NAME === 'pull_request') {
    const { BASE_SHA: base, HEAD_SHA: head } = process.env;
    if (![base, head].every(sha => /^[a-f0-9]{40}$/.test(sha ?? ''))) throw new Error('Invalid PR commit IDs');
    // No rename detection: both the old and new path must qualify for exemption.
    const diff = execFileSync('git', [
      'diff', '--no-ext-diff', '--no-textconv', '--raw', '--no-renames', '-z', `${base}...${head}`, '--',
    ], { maxBuffer: 64 * 1024 * 1024 });
    plan = classifyChanges(parseRawDiff(diff));
  }
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `mode=${plan.mode}\n`);
  summary(`## Test plan: ${plan.mode}\n\n${plan.reason}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { main(); } catch (error) { console.error(error.message); process.exitCode = 1; }
}
