# I7 iOS phone 后端与 Swift 草稿（默认未接入）

这是 8ea96a4 的新增 iOS 专用实验模块。Node 协议与真实 rc.4 Cordis/ToolRuntime/MCP 适配已在 Linux 运行；Swift 仅语法解析，**新增 phone 草稿未用 Apple SDK 编译、未真机验证**。文件放在 drafts 下，Xcode 不会自动编译。没有修改 Android/OHOS 或默认引擎配置。

## 复跑

仓库的 `node_modules` 需来自锁定的 DSH 0.2.1-rc.4 npm 树（已有 iOS prepare-engine 的 inputs/dsh/node_modules 可用）；没有新增 npm 依赖。默认 Node 的平台/网络测试和 iOS 条件测试分别为：

```sh
python3 tooling/ios/phone/build-native-check.py --node-include /absolute/node-24.22.1/include/node --out /absolute/phone-check.so
LD_PRELOAD=/absolute/phone-check.so node tooling/ios/phone/native-check.mjs
node --test runtime/ios/phone/bridge.test.mjs
LD_PRELOAD=/absolute/phone-check.so node tooling/ios/phone/registry-check.mjs
node --jitless --import ./tooling/ios/phone/strict-preload.mjs --test runtime/ios/phone/bridge.test.mjs
LD_PRELOAD=/absolute/phone-check.so node --jitless --import ./tooling/ios/phone/strict-preload.mjs tooling/ios/phone/registry-check.mjs
python3 tooling/ios/phone/check-catalog.py --repo . --kotlinc /absolute/path/to/kotlinc
```

最后一条使用仓库同版本 Kotlin 2.4.0/JRE，编译原样 Android PhoneToolCatalog.kt 与 Json.kt，逐字节比较。catalog.json 是有来源的静态协议资产，非运行时构建输出。SHA256 为 `ec04e096af7d632e86f9b0e39a28fbf7f74042e1df7b46db825b5cb7bbfe810e`。

## 函数级接入方案：仍待本机实施

1. iOS compose 阶段把 `runtime/ios/phone/{actions,bridge,plugin}.mjs` 和 `catalog.json` 加入 iOS 自己的 manifest/files。当前 `prepare-engine.sh` 复用 OHOS compose，**不会收录这些文件**；本次未修改共享 compose 或已生成 archive。不能只 git apply 就声称 App 已具备手机工具。
2. EngineChannel 在主线程持有 IOSPhoneBridge，初始化传入 NativeEngine 已加载且持续持有的 DshNodeHost handle。`prepare(in:)` 先 retire 旧 owner，创建每轮独立 0700 endpoint 目录，在 Swift 生成随机 token，再调用 C API `dsh_ios_phone_arm(runId, token)` 只存进内存；返回非秘密的 `(directory, runId)`。没有 bootstrap 文件。主线程维护独立 generation mirror，`runtimeCurrent` 闭包比较捕获的 generation 和 running 状态；不要用 `DispatchQueue.main.sync` ↔ `queue.sync` 相互等待。
3. 私有 Cordis overlay 加入绝对插件路径和 `{directory: ..., runId: ...}` 配置。实际 DSL 的条目形式需与宿主版本 overlay loader 对接；本次真实测试用 `await ctx.plugin(phone, {directory, runId})`，没有假造已可用的宿主参数。插件须在 `tools` 服务之后安装，并在任何 Agent 开始运行前完成注册；安装失败要让启动失败，不能仅记录日志继续。
4. 确认当前 host 的 `additional_patch_path` 是否允许这条 iOS 私有 overlay（不得放宽 OHOS 校验），由 iOS runner/host 边界单独接入。完整 token 禁止落盘，也不放 argv/environment/overlay/log；overlay 只有 endpoint 目录和非秘密 runId。iOS runner 初始化前注册 `dsh_ios_phone` linked binding，插件用 consume(runId) 一次性取走 C 内存副本；C 清零该副本。任意同进程代码仍有同权限，因此它不是抵抗同进程任意 Node 代码的安全隔离；真正动作权在 native 全文确认与系统 UI。
5. `startPolling()` 在启动被接受后调用；stop/restart/Flutter owner detach/引擎异常退出均先在主线程 `retire()`，再释放旧 generation；background 立即 `enteredBackground()`，不等 Node 恢复。绝不能复用旧 bridge 的 runId；retire 调 C clear，失败启动/取消均必须退役。Node Environment 清理也按捕获 generation 清除，旧 Environment 清理不能清掉新槽位。Node 的 Agent.cancel 必须沿真实 execution.signal 取消旧工具调用，禁止用永不 abort 的替身 signal。
6. 将两份 Swift 草稿同时加入 Runner target，链接 UIKit/EventKit/EventKitUI/MessageUI/UserNotifications/Security，iOS 15 起。旧版 iOS 的 calendar 路径须有真实用途的 `NSCalendarsUsageDescription`；iOS 17+ 仅系统编辑器不申请广泛日历读取权限。局域明文 loopback 的 ATS 规则沿现有本机引擎边界验证，不添加全局 `NSAllowsArbitraryLoads`。
7. 通知点击仅导航到 App，没有任何 callback 调用 `/begin` 或执行待办。需主线明确 native presenter 是当前可见 UIViewController，不能强行覆盖其他系统弹窗。

## 协议 v1

Swift 生成小写 runId UUID 和 32 随机字节 token → C 内存槽 → Node linked binding 一次性 consume；token 全程不持久化。Node 绑定 127.0.0.1 随机端口，只写无 token 的 endpoint.json。所有请求 `POST`、`Authorization: Bearer <token>`、JSON body 带 runId；浏览器 Origin 拒绝、redirect 不跟随。token 只防其他普通 loopback 客户端误连，不声称隔离同一 App 任意代码。

| 路径 | 状态变化 | 数据与限制 |
|---|---|---|
| /claim | pending → claimed | 一次最多一个 native request；返回 v/runId/id/owner(sessionId,callId)/action/expiresAt；claim 不批准 |
| /status | 无 | 已取消/超时/旧 run 返回 410 |
| /begin | claimed → executing | 真实 native「允许一次」后才发；新鲜 exact UUID，重复 409、旧 UUID 410 |
| /result | claimed 或 executing → 删除 | claimed 只能拒绝/error；success 必须 begin；字符串结果及 isError |

C `arm` 拒绝覆盖尚未退役的槽；错误 runId 不消耗 secret，consume 仅一次，clear 只影响匹配 generation。Native 测试使用额外测试 linked binding 调 C API，产品构建不编译这个测试入口。没有 `/approve`。每次调用生成不同 UUID，payload 深拷贝，不以 callId 字符串相等复用授权。rc.4 实际输入使用 `execution.agent.session.id` 与 `execution.callId`；真实 AgentLoop 把 step signal 传给每个调用。该 signal abort 同步删除等待项，迟到真实点击无法 begin。原生 runId/active id/runtime generation 二次校验避免旧 UI 穿越重启。操作开始后取消不能承诺撤销，结果 UNKNOWN 不自动重试。

队列上限 8、总时限 120 秒、确认界面 30 秒、HTTP 请求 4–5 秒均为此次设计预算，不是实测性能指标。原生轮询每 500 ms 仅用于撤下旧界面；授权正确性不依赖轮询及时性，真实点击后的 begin 才能验证 Node 当前 owner。系统权限对话框返回后，notify/calendar 必须重新 await `/status`，确认 Node 仍为 executing，并在前后复核 native requestId/generation/前后台；不能仅依赖本地镜像或 500 ms 轮询。begin 后的 OS 动作和并发取消不可做跨进程原子提交，已经发给系统的动作只报告结果未知。

## 工具语义

完整 Android 13 工具名称、描述、输入 schema 均原样，包括 Android 专用内容，保持模型工具目录缓存；执行集按下表显式限制，不悄悄改坐标或假装成功。

| 原工具 | iOS 行为 |
|---|---|
| open | 无凭据 HTTP/HTTPS URL，前台系统打开；拒绝 Android app、background |
| clipboard | 原生确认后 set/get；get 明示把剪贴板发给本次会话，8 KiB UTF-8 上限 |
| notify | 原生确认 + 系统通知权限，泛用本地通知；点击不批准其他动作 |
| intent calendar | EventKitUI 编辑器，用户自己 Save；没有后台直接 save |
| intent dial / sms_draft | tel 打开系统呼叫确认 / MessageUI 草稿用户发送；号码拒绝服务码 |
| intent share | 系统分享面板用户选择目标，不按 Android 包名指定 |
| intent navigate | 只接受 destination 名称/地址；Apple Maps 用户核对路线；GCJ-02 lat/lng、amap/baidu 与 ride 明确拒绝 |
| intent settings | 仅 page:home、无 app，映射 DSH Go 自身设置；其他页拒绝 |
| apps/screen/collect/tap/type/scroll/key/tap_xy/handoff | 同名注册，返回 iOS 不支持说明；不打开批准旁路 |
| intent alarm/timer | 返回不支持；不声称全平台做不到，仅本实现不提供 |

SafetyGate.kt 对照：Android 在危险动作前先硬拒绝，并将确认绑定捕获的 task owner，确认后重新检查。iOS 没有跨 App 自动化，所有支持动作均要求 native「允许一次」，无 TASK/ALWAYS 豁免，比 Android clipboard/notify 等默认路径更严格；同样要求等待中任务替换后旧点击无效。系统编辑器/分享/短信的最后一步仍由用户完成。目录字节一致不表示每个平台支持能力相同。

## 仍需 Mac / 真机覆盖

新增 phone Swift SDK 类型检查、Swift 并发隔离诊断、iOS 15/17+ 日历权限、两种短信结果、真实剪贴板提示、分享 popover、锁屏和后台跳转、通知点击、地图 URL 兼容性、ATS loopback，以及 EngineChannel 完整接线均未验证。现用 Maps 旧 `daddr`/`dirflg` URL，官方旧页面现重定向到 iOS 18.4+ unified Maps URL 文档，旧系统兼容性需真机核实；未宣称该部分可直接上线。不要把 Linux parser 成功写成 Swift 编译通过。

## v3 修正与原有主线验证的区别

旧版把 token 写入0600 bootstrap，仍违反 AGENTS 禁持久化完整 token 的契约，v3删除整条路径；不是通过文件权限或报告措辞豁免。v3新增03 native补丁（phone_binding、runner注册、iOS构建源列表）。01/02/03都从8ea96a4可应用，须共同使用；旧01/02不应混用。所有修改仅iOS专用路径；CRLF的两个既有文件在生成diff前归一LF，未把换行作为产品改动。

Linux测试实际编译了产品 phone_binding.cc，通过C API arm/clear和真实Node linkedBinding，验证一次性消费/错误generation/覆盖拒绝，以及旧Worker Environment清理不清除新generation。实际registry测试目录只有endpoint.json，检查它不含测试token。没有用JS假consume替代native。Swift仍只parser；ADDENDUM-03所述既有全部Swift/native通过Xcode26.6，不涵盖此次新phone代码，不挪作本稿编译证据。
