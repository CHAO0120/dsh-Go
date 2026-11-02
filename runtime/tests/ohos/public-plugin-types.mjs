// TypeScript semantic check against fixed public OH declarations; not an ArkTS compiler.
import { createRequire } from 'node:module';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve, join } from 'node:path';
const [source, sdk, output, processPrefix] = process.argv.slice(2).map(x => resolve(x));
const ts = createRequire(join(processPrefix, 'package.json'))('typescript');
mkdirSync(output, { recursive: true });
const plugin = join(output, 'Plugin.ts');
writeFileSync(plugin, readFileSync(source));
writeFileSync(join(output, 'flutter.d.ts'), `
import common from '@ohos.app.ability.common';
import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
export type Any = any; // Flutter's public ESObject bridge, not a product cast.
export interface BinaryMessenger { setMessageHandler(name: string, handler: null): void; }
export interface FlutterPluginBinding { getApplicationContext(): common.Context; getBinaryMessenger(): BinaryMessenger; }
export interface FlutterPlugin { getUniqueClassName(): string; onAttachedToEngine(binding: FlutterPluginBinding): void; onDetachedFromEngine(binding: FlutterPluginBinding): void; }
export interface AbilityAware { onAttachedToAbility(binding: AbilityPluginBinding): void; onDetachedFromAbility(): void; }
export interface AbilityPluginBinding { getAbility(): UIAbility; addOnNewWantListener(listener: NewWantListener): void; removeOnNewWantListener(listener: NewWantListener): void; }
export interface NewWantListener { onNewWant(want: Want, launch: AbilityConstant.LaunchParam): void; }
export interface MethodCall { method: string; argument(key: string): Any; }
export interface MethodResult { success(value: Any): void; error(code: string, message: string, details: Any): void; notImplemented(): void; }
export interface MethodCallHandler { onMethodCall(call: MethodCall, result: MethodResult): void; }
export class MethodChannel { constructor(messenger: BinaryMessenger, name: string); setMethodCallHandler(handler: MethodCallHandler | null): void; invokeMethod(method: string, args: Any): void; }
export interface EventSink { success(event: Any): void; error(code: string, message: string, details: Any): void; endOfStream(): void; }
export interface StreamHandler { onListen(args: Any, events: EventSink): void; onCancel(args: Any): void; }
export class EventChannel { constructor(messenger: BinaryMessenger, name: string); setStreamHandler(handler: StreamHandler): void; }
`);
writeFileSync(join(output, 'host.d.ts'), 'export function openUserFile(root: string, relative: string): number;\n');
const options = { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS, strict: true, noEmit: true,
  skipLibCheck: true, types: [], baseUrl: output, paths: {
    'libdsh_host.so': [join(output, 'host.d.ts')], '@ohos/flutter_ohos': [join(output, 'flutter.d.ts')], '@ohos.*': [join(sdk, '@ohos.*.d.ts')],
  }, moduleResolution: ts.ModuleResolutionKind.Node10 };
const program = ts.createProgram([plugin], options);
const diagnostics = ts.getPreEmitDiagnostics(program).map(x => ({ code: x.code,
  file: x.file?.fileName, line: x.file && x.start !== undefined ? x.file.getLineAndCharacterOfPosition(x.start).line + 1 : null,
  message: ts.flattenDiagnosticMessageText(x.messageText, '\n') }));
const report = { compiler: ts.version, source, sdk, scope: 'TypeScript+fixed public OH .d.ts+minimal public Flutter signatures; not ArkTS/hvigor', diagnostics };
writeFileSync(join(output, 'report.json'), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2)); process.exitCode = diagnostics.length ? 1 : 0;
