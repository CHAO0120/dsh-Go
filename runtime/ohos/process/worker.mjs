import { parentPort, workerData } from 'node:worker_threads';
import { Bash, defineCommand } from './build/just-bash/index.js';
import { createFilesystem } from './filesystem.mjs';
import { shellCommands, unavailableMessage } from './commands.mjs';
import { executeRg } from './rg.mjs';

const { argv, cwd, roots, stdin, env, policy } = workerData;
const filesystem = createFilesystem(roots, policy);
const bash = new Bash({
  fs: filesystem.fs,
  cwd,
  env,
  commands: [...shellCommands],
  python: false,
  javascript: false,
  defenseInDepth: false,
  customCommands: [defineCommand('rg', executeRg)],
  executionLimits: { maxExecutionTimeMs: Infinity, maxOutputSize: 64 * 1024 * 1024 },
});
filesystem.seal();

try {
  // argv 通过 args 原样传递；脚本仅在 bash/sh -c 的语法位置由解释器解析。
  const result = await bash.exec(argv[0], { args: argv.slice(1), cwd, env, replaceEnv: true, stdin, rawScript: true });
  if (result.exitCode === 127) result.stderr += unavailableMessage + '\n';
  const write = (stream, content, encoding) => new Promise((resolve, reject) => {
    stream.write(content, encoding, error => error ? reject(error) : resolve());
  });
  const encoding = result.stdoutKind === 'bytes' || result.stdoutEncoding === 'binary' ? 'latin1' : 'utf8';
  await Promise.all([write(process.stdout, result.stdout, encoding), write(process.stderr, result.stderr, 'utf8')]);
  parentPort.postMessage({ exitCode: result.exitCode });
} catch (error) {
  parentPort.postMessage({ failure: { name: error.name, message: error.message, code: error.code, stack: error.stack } });
} finally {
  parentPort.close();
}
