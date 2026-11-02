# P3b：时区、回前台和深链通道

基底 c818155。**未编译、未在真机核实。** 本包实现的行为以以下表格为边界；不把系统刷新率模式、文件导入或完整 P3 宣称为已完成。

## 协议

| 通道 / 方法 | 鸿蒙行为 |
| --- | --- |
| `dsh/app.getTimeZoneId` | 公开 `i18n.getTimeZone().getID()`，返回系统时区字符串；查询失败返回 `ohos_timezone`。 |
| `dsh/app.bringToFront` | 仅启动当前绑定 UIAbility 自身的 bundle/name；系统拒绝后台拉起或窗口已分离时明确报错，不承诺绕过系统限制。 |
| `dsh/app.setRefreshRateMode` | `system` 表示保留系统与 Flutter 的刷新策略；`auto`、`max` 返回 `ohos_unsupported`，提示选择系统默认。 |
| `dsh/app.setFrameActive` | 在唯一支持的 system 模式下无需应用强制帧率，返回空；没有新增 VSync 循环或帧率计时器。 |
| `dsh/links.ready` | 返回 true，再按收到顺序回放等待中的链接。重复 ready 不重放。 |
| `dsh/links` 原生调用 `link` | 参数必须是 Map `{uri: string}`；外来文件尚无可读副本时为 `{error: 'unreadable', name: null}`。不是裸字符串。 |

精确消费方是 `app/lib/links/app_links.dart` 中的 `AppLinks.parseNativeLink`，以及 `app/lib/performance/refresh_rate.dart`、`app/lib/state/app_foreground.dart`、`app/lib/ui/features/schedule_editor/time_zones.dart`。本包只读取这些文件，没有改 Dart/UI 或 Android。

**时区还有 Dart 接线门：** c818155 的 `detectDeviceTimeZone` 仅在 `Platform.isAndroid` 时转入上述 MethodChannel；OHOS 当前不会走这条分支。主线需让鸿蒙也调用同一原生方法，才有端到端的系统 IANA 时区检测；仅应用本包不能据通道测试宣称该页面已接通。

## 深链与生命周期

EntryAbility 增加 `singleton` 和 `dshgo` scheme 的 viewData/browsable skill，用于已有 `dshgo://forum/auth?...`、分享码和 App 页面入口。仅注册自己的自定义 scheme；没有未经域名配置的 https App Linking 声明。若系统显式送来 http/https viewData，通道按原样交给现有 Dart 路由器决定，原生层不消费登录凭证，不记录 URI。

初始 Want 来自公开 `UIAbility.launchWant`；热启动来自 oh-flutter 的 `NewWantListener`。按 Ability 对象记录已取的冷启动，用弱引用集合避免长期持有旧窗口；有意重复到达的热链接不会按 URL 去重。等待队列在进程内保留，避免冷启动已取走、Dart ready 前引擎重建导致链接消失。队列交给当时已 ready 的 `dsh/links`，不是磁盘持久化；杀进程后的系统重放与多窗口路由仍需设备验证。

卸载插件时移除 Ability listener 和两条 MethodChannel handler；旧回调在没有绑定窗口时被忽略。注册放在固定 oh-flutter 的空 `super.configureFlutterEngine` 前，使用独立的前后文，与 P2、P3a 的注册增量可按普通 `git apply` 叠加。

本包还没有实现外来 file/content URI 的持久缓存复制。遇到这类 viewData 会交给 Dart 的明确 unreadable 占位流程，不把临时授权 URI 误报为可读路径；分享/文件包将接手该能力。这里不声明 file scheme 的系统关联。

## 刷新率的真实边界

公开 `@ohos.window` 声明没有可对任意窗口设置 Android preferredDisplayMode 的等价方法。`UIContext.requireDynamicSyncScene` 返回的是 ArkUI Swiper/Marquee 场景，不能仅凭方法名将它当作 Flutter XComponent 的刷新率控制。

固定 oh-flutter 的 FlutterView 会把当前 display.refreshRate 传给引擎，并在输入活动时调用 `LTPODispatchHighFrameRate()`；`updateRefreshRate` 是向引擎报告当前值，不是改变面板刷新率。本包不拿这两个方法伪装强制最高模式。

主线可先将鸿蒙刷新选项限制到系统默认，并保留明确的待办；当前 Dart refresh controller 会吞 PlatformException，因此若要向用户显示 unsupported，需主线在 UI 层加提示。本包不改该 UI。补齐 auto/max 需要可作用于 Flutter 所有权下 XComponent 的公开 NativeXComponent/VSync 接口及设备帧率、静止功耗和前后台行为证据；不能以持续请求高帧循环替代。

## 固定官方接口来源

- [OpenHarmony interface_sdk-js 固定修订](https://github.com/openharmony/interface_sdk-js/tree/8a86234f0d542e5062e24e948652f5a484d90904/api)：`@ohos.i18n.d.ts` 的 getTimeZone/getID；`@ohos.app.ability.UIAbility.d.ts` 的 launchWant；`application/UIAbilityContext.d.ts` 的 abilityInfo/startAbility 与 viewData/browsable 规则；`@ohos.window.d.ts`、`@ohos.arkui.UIContext.d.ts`。源码归档 SHA256 `772f9db136c163e7b0ad0111230768f547fa9a7acc230c115a88aea8565f1099`。
- [oh-flutter 官方仓库](https://atomgit.com/oh-flutter/flutter_flutter)，固定修订 `e5f752df3e25ec897da3c98a74bcced7c21b0bd3` / `3.47.9-ohos-1.0.0`：AbilityAware、AbilityPluginBinding、MethodChannel、FlutterAbility、FlutterView、FlutterNapi。核对接口和生命周期，没有复制其他移植插件实现。
- 本仓库 Android LinksPlugin 仅用于协议对照；其 Map 形状与 Dart 解析相符。Android 文件字节、recipe、版本串和依赖均未改。

## 验证

Linux 直接将产品 `.ets` 做 TypeScript 语法擦除，运行其方法，OS 与 Flutter messenger 是明确替身。9 项测试覆盖通道名、Map 形状、ready 顺序、冷启动仅消费一次、热链接不误去重、引擎替换、退订、非法 scheme/过长 URI、平台同步异常和异步拒绝、系统刷新模式边界。初稿 6/9；冷队列丢失、缺冒号 URI、同步 startAbility 异常三项先失败，修后 9/9。

```sh
# 在原锁准备的 runtime/ohos/process 中 npm ci，然后从仓库根运行：
OHOS_TYPESCRIPT_PREFIX=/absolute/runtime/ohos/process \
  node --test --test-isolation=none runtime/tests/ohos/app-links-channel.test.mjs
```

尚需主线：API 26 hvigor/ArkTS 编译；真实 StandardMessageCodec Map 往返；浏览器登录回调冷/热启动、onboarding 等待、引擎重建与图标重开不重放；后台 startAbility 被系统拒绝时的提示；系统时区切换；验证没有新增持续高刷或空闲唤醒。
