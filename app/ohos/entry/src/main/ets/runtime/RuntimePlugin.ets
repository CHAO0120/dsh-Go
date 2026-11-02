// 未经 HarmonyOS SDK 编译、未在真机核实；通道签名已核固定 oh-flutter e5f752d。
import { FlutterPlugin, FlutterPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import MethodCall from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodCall';
import MethodChannel, { MethodCallHandler, MethodResult } from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import EventChannel, { StreamHandler, EventSink } from '@ohos/flutter_ohos/src/main/ets/plugin/common/EventChannel';
import Any from '@ohos/flutter_ohos/src/main/ets/plugin/common/Any';
import { RuntimeChannelError } from './RuntimeCore';
import { RuntimeController } from './RuntimeController';

export class RuntimePlugin implements FlutterPlugin, MethodCallHandler, StreamHandler {
  private methods: MethodChannel | null = null;
  private events: EventChannel | null = null;
  private controller: RuntimeController | null = null;
  private sink: ((event: Map<string, Object | null>) => void) | null = null;

  getUniqueClassName(): string { return 'DshRuntimePlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.controller = RuntimeController.get(binding.getApplicationContext());
    this.methods = new MethodChannel(binding.getBinaryMessenger(), 'dsh/runtime');
    this.events = new EventChannel(binding.getBinaryMessenger(), 'dsh/runtime/events');
    this.methods.setMethodCallHandler(this);
    this.events.setStreamHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.onCancel(null);
    this.methods?.setMethodCallHandler(null);
    binding.getBinaryMessenger().setMessageHandler('dsh/runtime/events', null);
    this.methods = null; this.events = null; this.controller = null;
  }

  onListen(_args: Any, events: EventSink): void {
    this.onCancel(null);
    this.sink = (event: Map<string, Object | null>) => events.success(event);
    this.controller?.subscribe(this.sink);
  }

  onCancel(_args: Any): void {
    if (this.sink !== null) this.controller?.unsubscribe(this.sink);
    this.sink = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.handle(call, result).catch((error: Error) => {
      if (error instanceof RuntimeChannelError) result.error(error.code, error.message, null);
      else result.error('ohos_runtime_error', '鸿蒙本机运行时操作失败，请查看状态或重新打开 App。', null);
    });
  }

  private async handle(call: MethodCall, result: MethodResult): Promise<void> {
    if (this.controller === null) throw new RuntimeChannelError('ohos_detached', '运行时通道已解除连接。');
    const controller = this.controller;
    await controller.initialize();
    switch (call.method) {
      case 'getStatus': controller.collect(); result.success(controller.snapshot()); return;
      case 'install': await controller.install(call.argument('dropKept') === true); result.success(null); return;
      case 'start':
        await controller.start((call.argument('env') ?? null) as Map<string, Object> | null,
          call.argument('phoneStorage') === true, (call.argument('mode') ?? null) as string | null,
          call.argument('visualReplies') !== false);
        result.success(null); return;
      case 'stop': controller.stop(); result.success(null); return;
      case 'getLogs': result.success(controller.recentLogs((call.argument('lines') ?? 500) as number)); return;
      case 'getLogSnapshot': result.success(controller.logSnapshot((call.argument('lines') ?? 300) as number)); return;
      case 'clearFailure': controller.clearFailure(); result.success(null); return;
      case 'failureLog': result.success(controller.failureLog()); return;
      case 'lastKnownGood':
        result.success(new Map<string, Object | null>([['available', false], ['at', null], ['disable', []], ['enable', []],
          ['changed', []], ['patchChanged', false], ['empty', true]])); return;
      case 'storageStatus':
        result.success(new Map<string, Object | null>([['granted', false], ['permission', false], ['legacy', false], ['guestPath', '']])); return;
      case 'networkMetered': result.success(await controller.networkMetered()); return;
      case 'publishDiagnostics':
        const markdown: Any = call.argument('markdown');
        if (typeof markdown !== 'string') result.success(null);
        else {
          try { result.success(await controller.publishDiagnostics(markdown)); }
          catch (_) { result.success(null); }
        }
        return;
      case 'reset': case 'restoreLastKnownGood': case 'safePreflight': case 'moveAside': case 'setAutoSafe':
      case 'setDirectEngine': case 'installManagedSkill': case 'cancelManagedSkill': case 'requestStorage':
      case 'openAllFilesAccess': case 'batteryExempt': case 'requestBatteryExempt': case 'backgroundSettings':
      case 'openBackgroundSettings': case 'openVendorSettings': case 'voiceModelLine':
        throw new RuntimeChannelError('ohos_unsupported', `鸿蒙本机尚不支持 ${call.method}；文件请用系统选择器，其他任务可交给已连接的电脑。`);
      default: result.notImplemented();
    }
  }
}
