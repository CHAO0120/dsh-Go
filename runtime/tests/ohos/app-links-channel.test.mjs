// Actual product ETS after TypeScript erasure; OS and Flutter are explicit test doubles.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import test from 'node:test';
import vm from 'node:vm';

const prefix = process.env.OHOS_TYPESCRIPT_PREFIX;
assert(prefix, 'Set OHOS_TYPESCRIPT_PREFIX to the locked process npm-ci directory');
const ts = createRequire(resolve(prefix, 'package.json'))('typescript');
const text = readFileSync(new URL('../../../app/ohos/entry/src/main/ets/plugins/AppLinksPlugin.ets', import.meta.url), 'utf8');
const compiled = ts.transpileModule(text, { compilerOptions: {
  target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
} });
const plain = value => value instanceof Map || Object.prototype.toString.call(value) === '[object Map]'
  ? Object.fromEntries(value) : value;
const view = uri => ({ action: 'ohos.want.action.viewData', uri });

function fixture({ start = () => Promise.resolve(), zone = () => 'Asia/Shanghai' } = {}) {
  const channels = [], sent = [], starts = [], listeners = new Set();
  class Channel {
    constructor(_messenger, name) { this.name = name; channels.push(this); }
    setMethodCallHandler(handler) { this.handler = handler; }
    invokeMethod(method, args) { sent.push({ channel: this.name, method, args: plain(args) }); }
  }
  const module = { exports: {} };
  vm.runInNewContext(compiled.outputText, {
    module, exports: module.exports,
    require(name) {
      if (name === '@ohos.i18n') return { default: { getTimeZone: () => ({ getID: zone }) } };
      if (name === '@ohos/flutter_ohos') return { MethodChannel: Channel };
      throw new Error(`Unexpected runtime import ${name}`);
    },
  });
  const engine = { getBinaryMessenger: () => ({}) };
  const ability = {
    launchWant: view('dshgo://forum/auth?payload=cold-secret'),
    context: {
      abilityInfo: { name: 'EntryAbility', bundleName: 'io.github.ccch1mneyyy.dsh_app' },
      startAbility(want) { starts.push(plain(want)); return start(); },
    },
  };
  const binding = {
    getAbility: () => ability,
    addOnNewWantListener: listener => listeners.add(listener),
    removeOnNewWantListener: listener => listeners.delete(listener),
  };
  const make = () => {
    const plugin = new module.exports.default();
    plugin.onAttachedToEngine(engine);
    return plugin;
  };
  const plugin = make();
  function call(channel, method, args = {}) {
    const handler = channels.filter(c => c.name === channel).at(-1).handler;
    return new Promise(resolve => handler.onMethodCall({ method, argument: name => args[name] }, {
      success: value => resolve({ value: plain(value) }),
      error: (code, message) => resolve({ error: code, message }),
      notImplemented: () => resolve({ missing: true }),
    }));
  }
  return { plugin, make, engine, channels, sent, starts, listeners, ability, binding, call };
}

test('exact channel names, IANA timezone and missing methods', async () => {
  const f = fixture();
  assert.deepEqual(f.channels.map(c => c.name), ['dsh/app', 'dsh/links']);
  assert.deepEqual(await f.call('dsh/app', 'getTimeZoneId'), { value: 'Asia/Shanghai' });
  assert.deepEqual(await f.call('dsh/app', 'unknown'), { missing: true });
  assert.deepEqual(await f.call('dsh/links', 'unknown'), { missing: true });
});

test('cold and warm links wait for ready, use the actual Dart map contract and keep arrival order', async () => {
  const f = fixture();
  f.plugin.onAttachedToAbility(f.binding);
  f.plugin.onNewWant(view('dshgo://open/new'), {});
  assert.deepEqual(f.sent, []);
  assert.deepEqual(await f.call('dsh/links', 'ready'), { value: true });
  assert.deepEqual(f.sent.map(v => v.args), [
    { uri: 'dshgo://forum/auth?payload=cold-secret' }, { uri: 'dshgo://open/new' },
  ]);
  assert(f.sent.every(v => v.channel === 'dsh/links' && v.method === 'link'));
  await f.call('dsh/links', 'ready');
  assert.equal(f.sent.length, 2);
});

test('ability reattach consumes the launch once but intentional repeated warm URLs remain separate arrivals', async () => {
  const f = fixture();
  await f.call('dsh/links', 'ready');
  f.plugin.onAttachedToAbility(f.binding);
  f.plugin.onDetachedFromAbility();
  f.plugin.onAttachedToAbility(f.binding);
  assert.equal(f.sent.length, 1);
  f.plugin.onNewWant(view('https://go.dshtui.com/c/123'), {});
  f.plugin.onNewWant(view('https://go.dshtui.com/c/123'), {});
  assert.equal(f.sent.length, 3);
  assert.equal(f.listeners.size, 1);
});

test('engine replacement before ready preserves the unconsumed launch without replaying it twice', async () => {
  const f = fixture();
  f.plugin.onAttachedToAbility(f.binding);
  f.plugin.onDetachedFromEngine(f.engine);
  const replacement = f.make();
  replacement.onAttachedToAbility(f.binding);
  await f.call('dsh/links', 'ready');
  assert.deepEqual(f.sent.map(v => v.args), [{ uri: 'dshgo://forum/auth?payload=cold-secret' }]);
  replacement.onDetachedFromEngine(f.engine);
  f.plugin.onAttachedToEngine(f.engine);
  f.plugin.onAttachedToAbility(f.binding);
  await f.call('dsh/links', 'ready');
  assert.equal(f.sent.length, 1);
});

test('detach unregisters listeners and method handlers; retired arrivals cannot reach Dart', async () => {
  const f = fixture();
  f.plugin.onAttachedToAbility(f.binding);
  await f.call('dsh/links', 'ready');
  f.plugin.onDetachedFromEngine(f.engine);
  f.plugin.onNewWant(view('dshgo://ignored'), {});
  assert.equal(f.sent.length, 1);
  assert.equal(f.listeners.size, 0);
  assert(f.channels.every(c => c.handler === null));
});

test('ignores non-view intents, unknown schemes, missing colon and oversize input; external files fail explicitly', async () => {
  const f = fixture();
  f.ability.launchWant = {};
  f.plugin.onAttachedToAbility(f.binding);
  await f.call('dsh/links', 'ready');
  for (const want of [{ uri: 'dshgo://x' }, view('javascript:alert(1)'), view('dshgoX'), view('httpsX'), view('dshgo:' + 'x'.repeat(65536))]) {
    f.plugin.onNewWant(want, {});
  }
  assert.deepEqual(f.sent, []);
  f.plugin.onNewWant(view('file://external/not-owned.dshgo'), {});
  assert.deepEqual(f.sent.map(v => v.args), [{ error: 'unreadable', name: null }]);
});

test('foreground launch targets only the attached own ability and reports platform rejection', async () => {
  const f = fixture();
  assert.equal((await f.call('dsh/app', 'bringToFront')).error, 'no_ability');
  f.plugin.onAttachedToAbility(f.binding);
  assert.deepEqual(await f.call('dsh/app', 'bringToFront', { bundleName: 'attacker' }), { value: null });
  assert.deepEqual(JSON.parse(JSON.stringify(f.starts)), [{ bundleName: 'io.github.ccch1mneyyy.dsh_app', abilityName: 'EntryAbility' }]);
  const denied = fixture({ start: () => Promise.reject(new Error('background start denied')) });
  denied.plugin.onAttachedToAbility(denied.binding);
  assert.equal((await denied.call('dsh/app', 'bringToFront')).error, 'ohos_foreground');
});

test('synchronous platform foreground and timezone exceptions become stable channel errors', async () => {
  const f = fixture({ start: () => { throw new Error('context invalid'); }, zone: () => { throw new Error('service unavailable'); } });
  f.plugin.onAttachedToAbility(f.binding);
  assert.equal((await f.call('dsh/app', 'bringToFront')).error, 'ohos_foreground');
  assert.equal((await f.call('dsh/app', 'getTimeZoneId')).error, 'ohos_timezone');
});

test('system refresh strategy is explicit; unsupported force modes are errors, not fabricated success', async () => {
  const f = fixture();
  assert.deepEqual(await f.call('dsh/app', 'setRefreshRateMode', { mode: 'system' }), { value: null });
  for (const mode of ['auto', 'max', 'bad']) {
    assert.equal((await f.call('dsh/app', 'setRefreshRateMode', { mode })).error, 'ohos_unsupported');
  }
  assert.deepEqual(await f.call('dsh/app', 'setFrameActive', { active: false }), { value: null });
});
