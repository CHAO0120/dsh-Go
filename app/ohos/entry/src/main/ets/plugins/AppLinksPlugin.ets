// 未编译、未在真机核实。公开接口和未实现边界见 app-links-channels.md。
import i18n from '@ohos.i18n';
import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import {
  AbilityAware, AbilityPluginBinding, Any, FlutterPlugin, FlutterPluginBinding,
  MethodCall, MethodCallHandler, MethodChannel, MethodResult, NewWantListener
} from '@ohos/flutter_ohos';

export default class AppLinksPlugin implements FlutterPlugin, AbilityAware, MethodCallHandler, NewWantListener {
  private static launches: WeakSet<UIAbility> = new WeakSet<UIAbility>();
  private static pending: Map<string, Any>[] = [];
  private app?: MethodChannel;
  private links?: MethodChannel;
  private ability?: AbilityPluginBinding;
  private ready: boolean = false;

  getUniqueClassName(): string { return 'DshAppLinksPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    const messenger = binding.getBinaryMessenger();
    this.app = new MethodChannel(messenger, 'dsh/app');
    this.links = new MethodChannel(messenger, 'dsh/links');
    this.app.setMethodCallHandler(this);
    this.links.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        if (call.method !== 'ready') { result.notImplemented(); return; }
        this.ready = true;
        const held = AppLinksPlugin.pending;
        AppLinksPlugin.pending = [];
        result.success(true);
        for (const event of held) this.links?.invokeMethod('link', event);
      }
    });
  }

  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    this.onDetachedFromAbility();
    this.ready = false;
    this.app?.setMethodCallHandler(null);
    this.links?.setMethodCallHandler(null);
    this.app = undefined;
    this.links = undefined;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.onDetachedFromAbility();
    this.ability = binding;
    binding.addOnNewWantListener(this);
    const ability = binding.getAbility();
    if (!AppLinksPlugin.launches.has(ability) && this.take(ability.launchWant)) {
      AppLinksPlugin.launches.add(ability);
    }
  }

  onDetachedFromAbility(): void {
    this.ability?.removeOnNewWantListener(this);
    this.ability = undefined;
  }

  onNewWant(want: Want, _launchParams: AbilityConstant.LaunchParam): void {
    if (this.ability) this.take(want);
  }

  private take(want: Want): boolean {
    if (want.action !== 'ohos.want.action.viewData') return false;
    const uri = want.uri ?? '';
    if (uri.length === 0 || uri.length > 64 * 1024) return false;
    const colon = uri.indexOf(':');
    if (colon < 1) return false;
    const scheme = uri.slice(0, colon).toLowerCase();
    const event = new Map<string, Any>();
    switch (scheme) {
      case 'dshgo': case 'https': case 'http':
        event.set('uri', uri);
        break;
      case 'file': case 'content':
        // 外来文件还没有获得持久可读副本，不把临时授权URI伪装成本地文件。
        event.set('error', 'unreadable');
        event.set('name', null);
        break;
      default: return false;
    }
    if (this.ready) this.links?.invokeMethod('link', event);
    else AppLinksPlugin.pending.push(event);
    return true;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'getTimeZoneId':
        try { result.success(i18n.getTimeZone().getID()); }
        catch (_error) { result.error('ohos_timezone', '无法读取系统时区，请重试。', null); }
        return;
      case 'bringToFront': {
        const ability = this.ability?.getAbility();
        if (!ability) { result.error('no_ability', '应用窗口当前不可用。', null); return; }
        try {
          const info = ability.context.abilityInfo;
          ability.context.startAbility({ bundleName: info.bundleName, abilityName: info.name })
            .then(() => result.success(null))
            .catch(() => result.error('ohos_foreground', '系统未允许回到前台，请从应用图标打开。', null));
        } catch (_error) {
          result.error('ohos_foreground', '系统未允许回到前台，请从应用图标打开。', null);
        }
        return;
      }
      case 'setRefreshRateMode':
        if (call.argument('mode') === 'system') result.success(null);
        else result.error('ohos_unsupported', '当前由鸿蒙与 Flutter 管理刷新率，请选择系统默认。', null);
        return;
      case 'setFrameActive':
        // system 模式不强制帧率，也不新增周期性VSync请求。
        result.success(null);
        return;
      default: result.notImplemented();
    }
  }
}
