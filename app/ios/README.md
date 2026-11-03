# iOS 工程

Flutter 3.47.7，Xcode 26（CI 用 26.6），最低 iOS 15。插件走 Swift Package Manager，这个工程没有 CocoaPods 的 `Podfile`。

## 在 Mac 上编译

```sh
cd app
flutter pub get
open ios/Runner.xcworkspace
```

第一次要在 Xcode 里给 `Runner` 和 `ShareExtension` 两个 target 都选上 Team（Signing & Capabilities）。两个 target 都用 App Group，开了自动签名时 Xcode 会自己注册。

Bundle ID 如果被占用，要一起改三处：两个 target 的 `PRODUCT_BUNDLE_IDENTIFIER`，两份 `.entitlements` 里的 App Group，`ShareExtension/ShareInbox.swift` 的 `group`。扩展的 ID 必须以主应用的 ID 开头。

然后插上手机：

```sh
flutter run --release -d <设备>
```

不签名只看能不能编过，和 CI 一样：

```sh
flutter build ios --simulator --debug
flutter build ios --release --no-codesign
```

## 现状

- 代码只经过 CI 编译，还没有在设备上跑过，下面的验收项都没做。
- 没有本机引擎，只能连远程主机。`dsh/runtime` 没有原生实现，Dart 按“这个平台没有”处理。
- 已接的通道：`dsh/app`、`dsh/links`、`dsh/files`、`dsh/media`、`dsh/notify`、`dsh/voice`、`dsh/shortcuts`、`dsh/share`。
- 没接的通道，Dart 都按不支持处理：`dsh/native-files`、`dsh/native-media`（原生插件的文件和媒体能力）、`dsh/performance`（设备档位固定中档，不响应发热）、`dsh/launcher_icon`（换图标）、`dsh/diagnostics`、`dsh/usage`、`dsh/launch`、`dsh/dynamic_color`、`dsh/picture_shortcut`。
- `dsh/islands` 在 Dart 侧只对 Android 开放，所以 WebView 不跟随应用的深色设置和文字缩放，跟随系统。
- 通知只在应用运行时发得出去。锁屏和离开应用后的提醒要 APNs，还没做。
- 分享扩展靠响应链唤起主应用，这是非公开用法，上架时要重新评估。唤起失败时，内容留在收件箱，下次回到应用时送达。

## 真机验收

装好后逐项过一遍，失败的记下系统版本和现象：

| 项 | 怎么测 | 应该看到 |
|---|---|---|
| 首次引导 | 全新安装 | 只出现通知和语音两项权限，没有存储、电池、无障碍；通知和麦克风各弹一次系统对话框 |
| 远程连接 | 配对一台主机，发一轮消息 | 回复流式出现；局域网直连时系统问一次本地网络权限 |
| 系统识别 | 输入框点语音，说中文和英文 | 边说边出字；结束后文字留在输入框；飞行模式下，支持本机识别的语言仍可用 |
| 语音被打断 | 听写时来电或定闹钟 | 听写结束并提示，之后应用里的声音正常 |
| 通知 | 应用在前台，后台跑完一轮 | 收到提醒，点开进入对应对话 |
| 通知被拒 | 系统对话框选不允许，再到后台运行页点通知 | 跳到系统设置的通知页 |
| 快捷操作 | 长按桌面图标 | 有新对话、语音输入和最近的对话，点开各自进入 |
| 冷启动快捷操作 | 划掉应用后再用快捷操作 | 同样能进入，不丢 |
| 分享文字和链接 | Safari 分享一个网页 | 应用被唤起，新对话输入框里有链接和标题 |
| 分享照片 | 相册选 3 张（含一张 HEIC），分享 | 都在附件里，HEIC 变成 JPEG，长边不超过 2560 |
| 分享过多 | 一次分享超过 9 项 | 系统不提供 DSH Go，或多出的提示被跳过 |
| 唤起失败 | 分享后没有回到应用时，手动打开应用 | 内容仍然送达，只送一次 |
| `.dshgo` | 文件 App 里打开或分享一个 `.dshgo` | 进入分享码导入，不会变成聊天附件 |
| 链接 | Safari 打开 `dshgo://` 链接 | 进入对应页面 |
| 文件 | 打开和保存对话产生的文件、PDF 预览 | 预览正常，保存后在文件 App 的 DSH Go 目录里 |
| 相册 | 保存生成的图片 | 系统只要求“添加照片”权限，图片进相册 |
| WebView | 打开网页模式，切后台久一点再回来 | 被系统回收时显示错误页，重试后恢复 |
| 深色模式 | 系统切深色后启动 | 启动屏不闪白 |
| 中文 | 系统语言切中文和英文 | 权限说明和快捷操作跟随系统语言 |
| 图标 | 桌面、设置页 | 显示品牌图标，不是 Flutter 默认图标 |
