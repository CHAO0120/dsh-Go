// Runs the phone runner on the Simulator and drives Settings with it, through the same RPC the app
// uses. A Simulator build has no signing and so no App Group; it's told where to publish instead.
//
//   node phone-runner-check.mjs --simulator <udid> --work <new dir>
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, openSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';

const { values } = parseArgs({ options: { simulator: { type: 'string' }, work: { type: 'string' } } });
const work = resolve(values.work);
mkdirSync(work, { recursive: true });
const clean = (text) => String(text).replace(/%/g, '%25').replace(/\r?\n/g, '%0A');
const notice = (title, text) => console.log(`::notice title=${title}::${clean(text).slice(0, 3500)}`);
const fail = (title, text) => console.log(`::error title=${title}::${clean(text).slice(0, 3500)}`);

const logFile = join(work, 'xcodebuild.log');
const log = openSync(logFile, 'a');
const runner = spawn('xcodebuild', ['test', '-project', 'ios/Runner.xcodeproj', '-scheme', 'PhoneRunner',
  '-destination', `id=${values.simulator}`, 'CODE_SIGNING_ALLOWED=NO'], {
  // xcodebuild passes these on to the test with the prefix removed. It only looks in its environment.
  cwd: 'app', stdio: ['ignore', log, log], env: { ...process.env, TEST_RUNNER_DSH_PHONE_RUNNER_DIR: work },
});
let exited = null;
runner.on('exit', (code, signal) => { exited = code ?? signal; });

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
const endpointFile = join(work, 'endpoint.json');
const steps = [];

function finish(problem) {
  runner.kill('SIGTERM');
  if (problem) {
    fail('phone runner', `${problem}\n${steps.join('\n')}`);
    const lines = existsSync(logFile) ? readFileSync(logFile, 'utf8').split('\n') : [];
    const errors = lines.filter((line) => /error:|Failed|failed to|BUILD FAILED|TEST FAILED/.test(line));
    notice('phone runner build', [...new Set(errors)].slice(0, 14).join('\n') || lines.slice(-25).join('\n'));
    process.exit(1);
  }
  notice('phone runner', steps.join('\n'));
  process.exit(0);
}

const deadline = Date.now() + 25 * 60 * 1000;
while (!existsSync(endpointFile)) {
  if (exited !== null) finish(`xcodebuild ended with ${exited} before the runner started`);
  if (Date.now() > deadline) finish('the runner never published its endpoint');
  await sleep(1000);
}
const endpoint = JSON.parse(readFileSync(endpointFile, 'utf8'));
const url = `http://127.0.0.1:${endpoint.port}/rpc`;
const started = Date.now();
steps.push(`up, ${endpoint.port}`);

async function rpc(method, params = {}, headers = { authorization: `Bearer ${endpoint.token}` }) {
  const at = Date.now();
  const response = await fetch(url, {
    method: 'POST', headers: { 'content-type': 'application/json', ...headers },
    body: JSON.stringify({ method, params }),
  });
  const body = await response.json();
  steps.push(`${method} ${JSON.stringify(params)} ${response.status} ${Date.now() - at}ms ${body.ok ? 'ok' : `error: ${body.error}`}`);
  return { status: response.status, ...body };
}

const must = (condition, problem) => { if (!condition) finish(problem); };
const idOf = (text, pattern) => {
  const line = text.split('\n').find((row) => pattern.test(row));
  return line ? Number(line.match(/^\[(\d+)\]/)?.[1]) : undefined;
};

try {
  // Who can call it.
  must((await rpc('screen', {}, {})).status === 401, 'answered with no token');
  must((await rpc('screen', {}, { authorization: 'Bearer wrong' })).status === 401, 'answered with a wrong token');
  must((await rpc('screen', {}, { authorization: `Bearer ${endpoint.token}`, origin: 'https://example.com' })).status === 401,
    'answered a web page');

  // Reading and driving another app.
  const opened = await rpc('open', { app: 'com.apple.Preferences' });
  must(opened.ok, 'could not open Settings');
  await sleep(1500);
  let screen = await rpc('screen', { image: true });
  must(screen.ok && /屏幕 s\d+/.test(screen.text), 'no screen');
  must(typeof screen.image === 'string' && screen.image.length > 1000, 'no screenshot');
  notice('settings on screen', screen.text.slice(0, 1500));
  const general = idOf(screen.text, /General|通用/);
  must(general !== undefined, 'Settings has no General row in the tree');
  must(!(await rpc('tap', { screen: 's0', id: general })).ok, 'a stale screen number was accepted');
  const tapped = await rpc('tap', { screen: screen.screen, id: general });
  must(tapped.ok && /About|关于/.test(tapped.text), `tapping General didn't open it: ${tapped.text?.slice(0, 400)}`);

  const scrolled = await rpc('scroll', { direction: 'down' });
  must(scrolled.ok, 'could not scroll');
  const back = await rpc('key', { key: 'back' });
  must(back.ok && /General|通用/.test(back.text), `back didn't return: ${back.text?.slice(0, 400)}`);

  // Typing, in the search field.
  screen = back;
  const search = idOf(screen.text, /搜索框|Search/);
  must(search !== undefined, 'Settings has no search field in the tree');
  const typed = await rpc('type', { screen: screen.screen, id: search, text: 'wifi' });
  must(typed.ok && /wifi/i.test(typed.text), `typing didn't reach the field: ${typed.text?.slice(0, 400)}`);

  // Tools that have no real target here still have to answer.
  must((await rpc('key', { key: 'home' })).ok, 'home failed');
  must((await rpc('apps')).ok, 'apps failed');
  must(!(await rpc('nonsense')).ok, 'an unknown tool succeeded');
  steps.push(`done in ${Date.now() - started} ms`);
  finish();
} catch (error) {
  finish(String(error?.stack ?? error));
}
