// Runs app/test/ios_tour/tour_main.dart on the Simulator: a screenshot at each stop the app asks for,
// and a video of the whole run. A stop that fails is reported and the tour goes on.
//
//   node ui-tour.mjs --simulator <udid> --app <Runner.app> --out <new dir>
import { execFileSync, spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { parseArgs } from 'node:util';

const { values } = parseArgs({ options: Object.fromEntries(['simulator', 'app', 'out'].map(name => [name, { type: 'string' }])) });
for (const key of ['simulator', 'app', 'out']) if (!values[key]) throw new Error(`--${key} required`);

const bundleId = 'io.github.ccch1mneyyy.dshgo';
const out = resolve(values.out);
mkdirSync(out, { recursive: true });
const simctl = (...args) => execFileSync('xcrun', ['simctl', ...args], { encoding: 'utf8' });
const notice = (kind, title, text) => console.log(`::${kind} title=${title}::${String(text).replace(/%/g, '%25').replace(/\s+/g, ' ').slice(0, 900)}`);

// The same clean status bar on every shot.
simctl('status_bar', values.simulator, 'override', '--time', '9:41', '--batteryState', 'charged', '--batteryLevel', '100', '--cellularBars', '4', '--wifiBars', '3');
simctl('install', values.simulator, values.app);
const tmp = join(simctl('get_app_container', values.simulator, bundleId, 'data').trim(), 'tmp');
mkdirSync(tmp, { recursive: true });
const log = join(tmp, 'dsh-ui-tour.log');
for (const stale of [log]) if (existsSync(stale)) writeFileSync(stale, '');

const video = spawn('xcrun', ['simctl', 'io', values.simulator, 'recordVideo', '--codec=h264', '--force', join(out, 'tour.mp4')], { stdio: 'ignore' });
await delay(1500);
const stdoutFile = join(out, 'app.out.log');
simctl('launch', '--terminate-running-process', `--stdout=${stdoutFile}`, `--stderr=${stdoutFile}`, values.simulator, bundleId);

let seen = 0;
let finished = false;
let errors = 0;
const deadline = Date.now() + 8 * 60 * 1000;
while (Date.now() < deadline && !finished) {
  const lines = existsSync(log) ? readFileSync(log, 'utf8').split('\n').filter(Boolean) : [];
  for (const line of lines.slice(seen)) {
    seen++;
    const [kind, ...rest] = line.split(' ');
    if (kind === 'SHOT') {
      const [number, name] = rest;
      simctl('io', values.simulator, 'screenshot', join(out, `${number.padStart(2, '0')}-${name}.png`));
      writeFileSync(join(tmp, `dsh-ui-tour-ack-${number}`), '');
      console.log(`shot ${number} ${name}`);
    } else if (kind === 'DONE') {
      finished = true;
    } else if (errors++ < 8) {
      notice('warning', 'ui tour', line);
    }
  }
  await delay(100);
}
await delay(500);
video.kill('SIGINT');
await new Promise(done => video.once('close', done));
simctl('terminate', values.simulator, bundleId);
notice(finished ? 'notice' : 'error', 'ui tour', `${seen} lines, ${errors} errors${finished ? '' : ', did not finish'}`);
process.exitCode = finished ? 0 : 1;
