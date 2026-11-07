// Run with the pinned private just-bash entry from a composed iOS runtime.
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { shellCommands } from '../../../runtime/ohos/process/commands.mjs';
import { routingTransform } from '../../../runtime/ios/guest/route.mjs';
import { installSuspendedGuestOwner } from '../../../runtime/ios/guest/suspended.mjs';

if (!process.argv[2]) throw new Error('Expected the pinned private just-bash index.js path');
const { Bash, InMemoryFs, parse } = await import(pathToFileURL(resolve(process.argv[2])).href);
const owner = installSuspendedGuestOwner({ readMetadata: () => ({
  v: 1, source: 'ios-native-owner', state: 'suspended', installed: 'present',
  available: false, enforcement: 'partial', python: 'unknown',
}) });
try {
  for (const needsLinux of [false, true]) {
    const fs = new InMemoryFs({ '/workspace/marker': 'original' });
    const script = needsLinux ? 'echo changed > /workspace/marker; python3 -V' :
      'echo virtual-ok > /workspace/marker; cat /workspace/marker';
    const argv = ['sh', '-c', script];
    const bash = new Bash({ fs, cwd: '/workspace', python: false, javascript: false, defenseInDepth: false });
    const routing = routingTransform(argv, { shellCommands, parse });
    bash.registerTransformPlugin(routing.plugin);
    const result = await bash.exec(argv[0], { args: argv.slice(1), rawScript: true });
    assert.equal(routing.decision.route, needsLinux ? 'guest' : 'virtual');
    assert.equal(await fs.readFile('/workspace/marker'), needsLinux ? 'original' : 'virtual-ok\n');
    if (needsLinux) {
      assert.equal(result.stdout, '');
      let diagnostic = '';
      const rejected = await owner.provider.execute({ decision: routing.decision, argv,
        output: async (_, bytes) => { diagnostic += bytes; } });
      assert.equal(rejected.exitCode, 126);
      assert.match(diagnostic, /ERR_IOS_GUEST_SUSPENDED/);
    } else {
      assert.equal(result.exitCode, 0);
      assert.equal(result.stdout, 'virtual-ok\n');
    }
  }
  console.log('PASS: suspended engine still executes virtual shell; Linux script has no partial effects and is rejected');
} finally { await owner.dispose(); }
