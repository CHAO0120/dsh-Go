import { stat, readFile, rename, unlink, writeFile } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { createMcpToolDefinition } from '@deepseek-ai/dsh-mcp-client';
import { createPhoneBridge } from './bridge.mjs';

export const name = 'dsh-go-ios-phone';
export const inject = ['tools'];
export const catalogSha256 = 'ec04e096af7d632e86f9b0e39a28fbf7f74042e1df7b46db825b5cb7bbfe810e';

export async function apply(ctx, config) {
  if (!isAbsolute(config.directory) || !/^[a-f0-9-]{36}$/.test(config.runId)) throw new Error('Invalid iOS phone endpoint directory/generation');
  const directory = await stat(config.directory);
  if (!directory.isDirectory() || directory.mode & 0o077 || directory.uid !== process.getuid()) throw new Error('Unsafe iOS phone endpoint directory');
  const bytes = await readFile(new URL('./catalog.json', import.meta.url));
  if (createHash('sha256').update(bytes).digest('hex') !== catalogSha256) throw new Error('iOS phone catalog SHA256 mismatch');
  const catalog = JSON.parse(bytes);
  // Swift arms the C memory slot. This linked binding consumes it once; there is
  // no token file, argv/environment secret, JS setter or serialized bootstrap.
  const token = process._linkedBinding('dsh_ios_phone').consume(config.runId);
  const bridge = await createPhoneBridge({ token, runId: config.runId });
  const disposers = [];
  const endpoint = join(config.directory, 'endpoint.json');
  const temporary = `${endpoint}.${randomUUID()}.tmp`;
  try {
    for (const tool of catalog) {
      disposers.push(ctx.tools.register(createMcpToolDefinition(ctx, {
        name: `mcp__phone__${tool.name}`, rawName: tool.name,
        description: tool.description, inputSchema: tool.inputSchema,
        call: (args, execution) => bridge.call(tool.name, args, execution),
      })));
    }
    await writeFile(temporary, JSON.stringify(bridge.endpoint), { mode: 0o600, flag: 'wx' });
    await rename(temporary, endpoint);
  } catch (error) {
    for (const dispose of disposers) dispose();
    await bridge.close();
    await unlink(temporary).catch(() => {});
    throw error;
  }
  ctx.effect(() => async () => {
    for (const dispose of disposers) dispose();
    await bridge.close();
    // Each launch uses a distinct endpoint directory; an old disposal cannot unlink a new run.
    await unlink(endpoint).catch(() => {});
  }, 'ios.phone');
}
