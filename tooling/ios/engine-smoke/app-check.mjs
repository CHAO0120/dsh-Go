// Installs a built app on the Simulator and checks it, in one of two ways.
//
//   node app-check.mjs --simulator <udid> --app <Runner.app> --mode engine
//     The bundle built from integration_test/ios_engine_check.dart reports each step here.
//   node app-check.mjs --simulator <udid> --app <Runner.app> --mode launch --shot <file.png>
//     The real app: it has to come up and still be alive a while later.
//
// Failures become annotations, which can be read without signing in to GitHub. So does a
// small copy of the screenshot, since the artifact can't be.
import { execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { existsSync, mkdtempSync, readdirSync, readFileSync, statSync } from 'node:fs';
import http from 'node:http';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseArgs } from 'node:util';

const { values } = parseArgs({ options: Object.fromEntries(
  ['simulator', 'app', 'mode', 'shot'].map((name) => [name, { type: 'string' }])) });
const bundleId = 'io.github.ccch1mneyyy.dshgo';
const clean = (text) => String(text).replace(/([?&]token=)[^\s&]+/g, '$1<redacted>')
  .replace(/%/g, '%25').replace(/\r?\n/g, '%0A');
const notice = (title, text) => console.log(`::notice title=${title}::${clean(text).slice(0, 3500)}`);
const fail = (title, text) => console.log(`::error title=${title}::${clean(text).slice(0, 3500)}`);
const simctl = (...args) => execFileSync('xcrun', ['simctl', ...args], { encoding: 'utf8' });
const quietly = (work) => { try { return work(); } catch (error) { return `(${String(error.message).split('\n')[0]})`; } };

const startedAt = Date.now();
const scratch = mkdtempSync(join(tmpdir(), 'dsh-app-check-'));
const stdoutFile = join(scratch, 'stdout.log');
const stderrFile = join(scratch, 'stderr.log');

function crashes() {
  const directory = join(homedir(), 'Library/Logs/DiagnosticReports');
  let names = [];
  try { names = readdirSync(directory); } catch { return []; }
  return names.filter((name) => /^Runner/.test(name) && statSync(join(directory, name)).mtimeMs >= startedAt)
    .map((name) => {
      const text = readFileSync(join(directory, name), 'utf8');
      const at = text.indexOf('"termination"');
      const frames = [...text.matchAll(/"symbol":"([^"]+)"/g)].slice(0, 14).map((match) => match[1]);
      return `${name}: ${text.slice(at, at + 400)} frames: ${frames.join(' < ')}`;
    });
}

function launch(environment = {}) {
  const printed = execFileSync('xcrun', ['simctl', 'launch', '--terminate-running-process',
    `--stdout=${stdoutFile}`, `--stderr=${stderrFile}`, values.simulator, bundleId],
  { encoding: 'utf8', env: { ...process.env, ...environment } });
  // Prints "<bundle id>: <pid>"; on the Simulator that's an ordinary Mac process.
  return Number(printed.trim().split(': ').pop());
}

function isAlive(pid) {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

/** The path each thread is waiting in, deepest frame first. */
function threads(pid) {
  const file = join(scratch, 'sample.txt');
  execFileSync('/usr/bin/sample', [String(pid), '2', '-file', file], { stdio: 'ignore', timeout: 90000 });
  const lines = readFileSync(file, 'utf8').split('\n');
  const start = lines.findIndex((line) => line.startsWith('Call graph:'));
  const found = [];
  let thread = null;
  for (const line of lines.slice(start + 1)) {
    if (!line.trim()) break;
    const label = line.match(/^\s*\d+\s+(Thread_\d+.*)$/);
    if (label) {
      thread = { label: label[1].trim(), frames: [], indent: -1, done: false };
      found.push(thread);
      continue;
    }
    const frame = line.match(/^([\s+!:|]*)\d+\s+(.*)$/);
    if (!frame || !thread || thread.done) continue;
    // The first way down the tree is the heaviest path; a shallower line starts another.
    if (frame[1].length <= thread.indent) { thread.done = true; continue; }
    thread.indent = frame[1].length;
    thread.frames.push(frame[2].replace(/\s+\+ \d+.*$/, '').replace(/\s+\[0x.*$/, '').trim());
  }
  return found.map((item) => `${item.label}: ${item.frames.slice(-7).reverse().join(' < ')}`);
}

function annotateChunks(title, lines, report = notice, limit = 4) {
  let chunk = '';
  let sent = 0;
  for (const line of lines) {
    if (chunk && chunk.length + line.length > 3300) {
      if (++sent > limit) return;
      report(title, chunk);
      chunk = '';
    }
    chunk += `${line}\n`;
  }
  if (chunk && sent < limit) report(title, chunk);
}

/** Everything that says why the app stopped answering. */
function explain(pid) {
  for (const crash of crashes()) fail('app crash', crash);
  notice('app process', `pid ${pid}, ${isAlive(pid) ? 'still running' : 'gone'}`);
  if (isAlive(pid)) annotateChunks('app threads', [].concat(quietly(() => threads(pid))));
  for (const [name, file] of [['stdout', stdoutFile], ['stderr', stderrFile]]) {
    if (existsSync(file)) notice(`app ${name}`, readFileSync(file, 'utf8').slice(-3000) || '(empty)');
  }
  const log = quietly(() => simctl('spawn', values.simulator, 'log', 'show', '--last', '20m', '--style', 'compact',
    '--predicate', 'process == "Runner"'));
  notice('app log', log.split('\n').slice(-45).map((line) => line.slice(0, 220)).join('\n'));
}

function screenshot(file) {
  execFileSync('xcrun', ['simctl', 'io', values.simulator, 'screenshot', file], { stdio: 'ignore' });
  const small = join(scratch, 'small.jpg');
  execFileSync('sips', ['-s', 'format', 'jpeg', '-s', 'formatOptions', '30', '-Z', '220', file, '--out', small], { stdio: 'ignore' });
  const encoded = readFileSync(small).toString('base64');
  for (let at = 0, part = 1; at < encoded.length; at += 3000, part++) {
    notice(`screenshot ${part} of ${Math.ceil(encoded.length / 3000)}`, encoded.slice(at, at + 3000));
  }
}

simctl('install', values.simulator, values.app);

if (values.mode === 'launch') {
  const pid = launch();
  await new Promise((done) => setTimeout(done, 30000));
  const up = isAlive(pid);
  if (values.shot) quietly(() => screenshot(values.shot));
  if (up) {
    notice('app launch', 'The real app is still running 30 seconds after launch.');
    annotateChunks('app threads', [].concat(quietly(() => threads(pid))).slice(0, 3), notice, 1);
    for (const crash of crashes()) fail('app crash', crash);
  } else {
    fail('app launch', 'The real app is not running 30 seconds after launch.');
    explain(pid);
  }
  quietly(() => simctl('terminate', values.simulator, bundleId));
  process.exit(up ? 0 : 1);
}

const steps = [];
let lastStepAt = Date.now();
let finish;
const finished = new Promise((done) => { finish = done; });
const server = http.createServer(async (request, response) => {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  response.end('ok');
  const step = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  steps.push(step);
  lastStepAt = Date.now();
  console.log(JSON.stringify(step));
  if (step.step === 'done' || step.step === 'failed') finish(step);
});
server.listen(0, '127.0.0.1');
await once(server, 'listening');

const pid = launch({ SIMCTL_CHILD_DSH_APP_CHECK_URL: `http://127.0.0.1:${server.address().port}/` });
console.log(`launched as ${pid}`);

// The app's own limits are shorter, so this only ends a check that nothing else will.
const watchdog = setInterval(() => {
  const quiet = Date.now() - lastStepAt;
  if (steps.length === 0 && quiet > 3 * 60 * 1000) finish({ step: 'failed', error: 'the app reported nothing within 3 minutes' });
  if (quiet > 12 * 60 * 1000) finish({ step: 'failed', error: 'no further result from the app within 12 minutes' });
}, 5000);
const last = await finished;
clearInterval(watchdog);
server.close();

const summary = steps.filter((step) => step.step !== 'failed').map((step) => JSON.stringify(step)).join('\n');
if (last.step === 'done') {
  notice('engine in the app', summary);
  for (const crash of crashes()) fail('app crash', crash);
} else {
  fail('engine in the app', `${last.error ?? ''} ${last.stack ?? ''}`);
  if (summary) notice('engine in the app, up to the failure', summary);
  explain(pid);
}
quietly(() => simctl('terminate', values.simulator, bundleId));
process.exit(last.step === 'done' ? 0 : 1);
