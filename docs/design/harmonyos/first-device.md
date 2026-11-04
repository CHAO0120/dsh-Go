# 第一次上真机

从 Linux 把 HAP 装到鸿蒙手机或平板上，不需要 Mac 和 DevEco Studio。放行条件和完整检查项见[真机验证清单](device-validation.md)，这里只讲怎么装上、怎么把现象带回来。

目前还没有人走通过这一页。走通或卡住后，把实际结果改进来。

## 准备

| 项 | 要求 |
|---|---|
| 设备 | 系统 API 26 或更新，手机或平板。这版 Flutter 引擎的硬要求，低了装不上 |
| 账号 | 华为开发者账号。实名后调试证书 180 天，未实名只有 14 天，都不能续期 |
| 工具 | OpenHarmony SDK 和 JDK 17（见 `tooling/ohos/check-arkts.sh`），里面有 `hdc` 和 `hap-sign-tool` |
| 包 | `tooling/ohos/check-arkts.sh --full` 打出的未签名 HAP |

## 步骤

1. **打开调试。** `设置 > 关于`，连点软件版本 7 次；`设置 > 系统 > 开发者选项` 里打开 USB 调试；连上电脑，在设备上点允许。
2. **看设备。** 确认 API 版本，记下 UDID：

   ```bash
   tooling/ohos/device.sh info
   ```

3. **生成密钥。** 只需一次，换了密钥要重新申请证书：

   ```bash
   tooling/ohos/device.sh keygen
   ```

   密钥和密码在 `~/keys/dsh-ohos/`，不进仓库，也不要发给任何人。

4. **在 AGC 上申请。** 登录 AppGallery Connect：
   1. 创建 HarmonyOS 应用，包名 `io.github.ccch1mneyyy.dsh_app`；
   2. 登记设备 UDID；
   3. 上传 `debug.csr`，申请调试证书，下载存为 `~/keys/dsh-ohos/debug.cer`；
   4. 申请调试 Profile，勾选设备，下载存为 `~/keys/dsh-ohos/debug.p7b`。

   要用受限权限（粘贴、长期后台）时在这一步一起申请。文档说审批前可得一个有效期较短的临时 Profile。

5. **签名并安装。**

   ```bash
   tooling/ohos/device.sh install entry-default-unsigned.hap
   ```

6. **出问题时收日志。** 复现时运行，发给别人前先看一遍，里面可能有对话内容：

   ```bash
   tooling/ohos/device.sh log 120
   ```

## 第一次要看什么

按这个顺序，前一项不过，后面的结果不算数：

| # | 看什么 | 没过说明 |
|---|---|---|
| 1 | 能不能装上 | 公开 SDK 打的包可能被拒（`compileSdkType` 是 OpenHarmony），那就要 HarmonyOS 的 Command Line Tools 和 `tooling/ohos/build-hap.sh` |
| 2 | 能不能打开，首屏出来没有 | 闪退多半是原生库加载，`libnode.so`、`libc++_shared.so` 从没在目标设备上加载过 |
| 3 | 远程主机模式能不能连上、聊天 | 不碰本机引擎，先证明 Flutter 这一层是好的 |
| 4 | 存 API key 重启后还在 | HUKS 和凭据库 |
| 5 | 本机引擎：解包多久、能否启动、第一轮对话 | 运行时安装和 Node，最大的未知 |
| 6 | 回复中切到后台再回来 | 挂起后回合能否续上，决定暂停提示和后台页的说法 |
| 7 | 手感：转场、键盘、振动、边缘返回、中文输入 | 这些只能在设备上调 |
| 8 | 分享、语音、PDF | 只对照占位声明编译过，最可能有问题 |

平板上还要看：WebView 默认多进程（手机是单进程），一个渲染进程崩溃时插件岛和页面的表现；宽屏布局。

## 把设备还回去

```bash
hdc uninstall io.github.ccch1mneyyy.dsh_app
```

然后在开发者选项里关闭开关，设备会重启。
