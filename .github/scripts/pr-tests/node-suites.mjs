import { execFileSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { join } from 'node:path';
import { existsSync } from 'node:fs';

const ROOT = fileURLToPath(new URL('../../../', import.meta.url));
const examples = ['album', 'files', 'quick', 'readaloud', 'styles', 'usage', 'weather', 'workbench'];

// Every tracked package with a default test script must be assigned here.
// Online market scans, publishing, live credentials and opt-in probes are separate.
export const NODE_SUITES = {
  sdk: [{ directory: 'sdk/plugin-kit', install: 'install', typescript: true, scripts: ['test'] }],
  runtime: [
    { directory: 'runtime/media/dsh-media', install: 'install', scripts: ['test'] },
    ...examples.map(name => ({ directory: `examples/plugins/dsh-go-example-${name}`, scripts: ['test', 'check'] })),
  ],
  web: [
    { directory: 'market', install: 'ci', scripts: ['test'] },
    { directory: 'site/home', scripts: ['check', 'check:content', 'test'] },
    { directory: 'services/share-worker', install: 'ci', scripts: ['build', 'typecheck', 'test'] },
  ],
};

export function commandsFor(suite) {
  const commands = [];
  if (suite.install) commands.push({ command: 'npm', args: [suite.install, '--include=dev', '--ignore-scripts', '--no-audit', '--no-fund',
    ...(suite.install === 'install' ? ['--no-package-lock'] : [])] });
  if (suite.typescript) commands.push({ command: './node_modules/.bin/tsc', args: ['--version'] });
  for (const script of suite.scripts) commands.push({ command: 'npm', args: ['run', script] });
  return commands;
}

export function runSuites(group, execute = execFileSync) {
  const suites = NODE_SUITES[group];
  if (!suites) throw new Error(`Unknown Node test group: ${group}`);
  const env = { ...process.env };
  if (group === 'runtime') {
    if (!env.DSH_PREFIX) throw new Error('Runtime Node suites require an isolated DSH_PREFIX');
    env.DSH_TOOLS_DIR = join(env.DSH_PREFIX, 'node_modules/@deepseek-ai/dsh-tools');
    if (!existsSync(join(env.DSH_TOOLS_DIR, 'lib/index.js'))) throw new Error('Real DSH tools are missing; do not use a test stub');
  }
  for (const suite of suites) {
    console.log(`\n## ${suite.directory}`);
    for (const { command, args } of commandsFor(suite)) {
      execute(command, args, { cwd: join(ROOT, suite.directory), env, stdio: 'inherit' });
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { runSuites(process.argv[2]); } catch (error) { console.error(error.message); process.exitCode = 1; }
}
