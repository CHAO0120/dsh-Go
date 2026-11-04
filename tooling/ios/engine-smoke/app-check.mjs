// Installs a built app on the Simulator and checks it, in one of two ways.
//
//   node app-check.mjs --simulator <udid> --app <Runner.app> --mode engine
//     The bundle built from integration_test/ios_engine_check.dart reports each step here.
//   node app-check.mjs --simulator <udid> --app <Runner.app> --mode launch --shot <file.png>
//     The real app: it has to come up and still be alive a while later.
//
// Failures become annotations, which can be read without signing in to GitHub.
import { execFile, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import http from 'node:http';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { parseArgs } from 'node:util';

const { values } = parseArgs({ options: Object.fromEntries(
  ['simulator', 'app', 'mode', 'shot'].map((name) => [name, { type: 'string' }])) });
const bundleId = 'io.github.ccch1mneyyy.dshgo';
const clean = (text) => String(text).replace(/%/g, '%25').replace(/\s+/g, ' ');
const notice = (title, text) => console.log(`::notice title=${title}::${clean(text).slice(0, 3000)}`);
const fail = (title, text) => console.log(`::error title=${title}::${clean(text).slice(0, 8000)}`);
const simctl = (...args) => execFileSync('xcrun', ['simctl', ...args], { encoding: 'utf8' });

const startedAt = Date.now();
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

function alive() {
  try { return simctl('spawn', values.simulator, 'launchctl', 'list').includes(`UIKitApplication:${bundleId}`); }
  catch { return false; }
}

simctl('install', values.simulator, values.app);

if (values.mode === 'launch') {
  simctl('launch', '--terminate-running-process', values.simulator, bundleId);
  await new Promise((done) => setTimeout(done, 30000));
  const up = alive();
  if (values.shot) execFileSync('xcrun', ['simctl', 'io', values.simulator, 'screenshot', values.shot], { stdio: 'ignore' });
  for (const crash of crashes()) fail('app crash', crash);
  if (up) notice('app launch', 'The real app is still running 30 seconds after launch.');
  else fail('app launch', 'The real app is not running 30 seconds after launch.');
  process.exit(up ? 0 : 1);
}

const steps = [];
let finish;
const finished = new Promise((done) => { finish = done; });
const server = http.createServer(async (request, response) => {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  response.end('ok');
  const step = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  steps.push(step);
  console.log(JSON.stringify(step));
  if (step.step === 'done' || step.step === 'failed') finish(step);
});
server.listen(0, '127.0.0.1');
await once(server, 'listening');

const launch = execFile('xcrun', ['simctl', 'launch', '--terminate-running-process', values.simulator, bundleId], {
  env: { ...process.env, SIMCTL_CHILD_DSH_APP_CHECK_URL: `http://127.0.0.1:${server.address().port}/` },
});
launch.stdout?.pipe(process.stdout);

const timeout = setTimeout(() => finish({ step: 'failed', error: 'no result from the app within 15 minutes' }), 15 * 60 * 1000);
const last = await finished;
clearTimeout(timeout);
server.close();
try { simctl('terminate', values.simulator, bundleId); } catch { /* It may have crashed. */ }

for (const crash of crashes()) fail('app crash', crash);
const summary = steps.filter((step) => step.step !== 'failed').map((step) => JSON.stringify(step)).join(' ');
if (last.step === 'done') notice('engine in the app', summary);
else {
  fail('engine in the app', `${last.error ?? ''} ${last.stack ?? ''}`);
  notice('engine in the app, up to the failure', summary);
}
process.exit(last.step === 'done' ? 0 : 1);
