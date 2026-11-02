# HarmonyOS 工程

用 [oh-flutter](https://atomgit.com/oh-flutter/flutter_flutter) 3.47.9-ohos 构建，最低 API 26（模板的 `compatibleSdkVersion`，也是这一版 Flutter 引擎的要求）。安卓不读这个目录。

```sh
FLUTTER_OHOS=/path/to/flutter-ohos/bin/flutter tooling/ohos/build-hap.sh
```

## 现状

- 第一阶段只有远程主机：没有 `dsh/runtime` 原生宿主时，App 的「本机」入口全部转去远程（`LocalRuntimeState.available`）。本机引擎见 `docs/design/harmonyos/`。
- 权限只有联网和读网络状态。文件走系统选择器，不申请 `READ_MEDIA`。
- 图标暂用安卓 192px 的 `ic_launcher.png`；上架前要换成 1024px 的分层图标。

## 依赖

插件的鸿蒙实现在 `pubspec_overrides.ohos.yaml`，按 tag 锁定，只在构建 HAP 时生效。`material_ui`、`cupertino_ui`、`xterm`、`gpt_markdown` 没有鸿蒙 fork，它们的 `switch (defaultTargetPlatform)` 因为多出 `TargetPlatform.ohos` 而编不过，构建时由 `tooling/ohos/vendor_platform_switches.py` 复制到 `.vendor` 并让 `ohos` 走 android 分支。`flutter_webrtc` 没有鸿蒙实现，远程连接会自动退回中继。`share_plus`、`connectivity_plus` 没有可用的公开 fork，由 ArkTS 侧实现它们的通道（待做）。

## 宿主

| 步骤 | Linux | macOS arm64 |
|---|---|---|
| `flutter create` / `pub get` / `analyze` / `test` | 可以（要先去掉 pub 缓存里 `fluttertpc_dart_native` 对 `Abi.ohos*` 的引用：官方 Dart 没有这些成员，定制 Dart 没发 Linux 版） | 可以 |
| `flutter build hap` | 不行：3.47 配套的 `gen_snapshot`、`frontend_server` 只发布了 macOS 版，OBS 上的 Linux 版还是 Dart 3.12.2，快照格式对不上 | 可以 |
| `hdc install`、真机调试 | 可以 | 可以 |

`hvigor`、`ohpm` 来自 HarmonyOS Command Line Tools（要登录华为账号下载），版本跟 DevEco 26.0.0。OpenHarmony 公开 SDK 只够编原生库，打不了能装到华为手机的 HAP。
