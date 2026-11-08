# 930 App → Node Linux 控制合同 v1

状态：930 的 ETS / Dart 与 Node 同步实现合同。依据为 705、829 的单开关/独立实例/事实分离要求，以及 922 中实际 `connection`、917 owner、914 backend 接缝。本文定义 **930 新增协议**，没有声称此前已有 Linux RPC 或 NativeHost 方法。

## 1. 固定入口与可信输入

- HTTP exact route：`/dsh-go/v1/linux`，只允许 `GET`、`POST`，不得带 query。使用已有 NativeHost 提供的 IPv4 loopback baseUrl / launchToken，复用现有 token→cookie 握手和 `connection.requestRejection(req)`；鉴权在解析 body 或作任何操作之前。
- 唯一 host preload 在插件前捕获 `DSH_GO_OHOS_LINUX_DIRECTORY` 和 `DSH_GO_OHOS_NATIVE_LIBRARY_DIR`。前者由 `HostOptions.linuxDirectory = filesDir + '/linux-tools'` 固定发布。缺失/非法路径是不可用，不能读取 config、argv 或后续 env 补值。
- assets 仅从当前模块所在 runtime 的 `runtime/ohos/linux/assets/` 固定目录加载。仅有库或目录存在都不表示已打开 guest。`GET` 不读 manifest、不探测文件、不联网、不导入原生库、不创建 owner。
- Node 的 Linux service 装入实际 OHOS `SubprocessRuntime`，但本期不向 `CommandRouter` 注入 Linux，不改变任何插件命令的默认路由。

## 2. POST 精确字段

三种 body 均为 JSON object，`Content-Type: application/json`，UTF-8 body 最多 65,536 bytes，body 到达限时 10 秒；未知字段、重复语义、类型错误、NUL argv/env 等拒绝。JSON 重复字面键受 JSON.parse 的最终值规则，不另建自定义 JSON parser。

每种 body 必须携带 `v: 1`、`instanceId: string`、`attemptId: string | null`。两种身份必须等于当前 `GET` 的值；否则 `409 ERR_OHOS_LINUX_STALE`，不执行任何动作。`instanceId` 是此 service 在本 Node 生命期生成的 UUID；第一次显式启用创建 `attemptId` UUID，本期不允许静默换新 owner。

### 开关

```json
{"v":1,"instanceId":"<GET返回>","attemptId":null,"action":"setEnabled","enabled":true}
```

成功接受返回 `202` 和完整状态对象。第一次 true 后后台加载固定 manifest / 下载 / 准备 / 安装；`202` 仅表示接受。再次 true 只复用同一个健康 owner/backend。false 立即关闭准入，然后异步 terminate 本 service 持有的未结局 job 并等待真实 `waitForExit`；正常已打开的空闲 VM 保留。false 在安装中取消安装并收尾；本期取消/失败的安装 owner 不重建，再次 true 明确报错并要求重启运行时。请求断连或 HTTP 超时不等于 false。

### 明确的私有 guest 运行

```json
{"v":1,"instanceId":"<GET返回>","attemptId":"<GET返回>","action":"runPrivateGuest","requestId":1,"argv":["python3","-c","print(1)"],"cwd":"/workspace","env":{},"stdin":""}
```

成功接受返回 `202` 和完整状态对象。一时只允许一个未结局 job；忙时 `409`。`requestId` 是正的 safe integer，须精确等于 GET 的 `nextRequestId`。同当前 job.id 的同一规范化请求仅返回原 job；同号异参或比当前号更早的请求返回 `409 ERR_OHOS_LINUX_REQUEST_REUSED`，绝不再次执行。最后一个请求的摘要、最后一个 job 和一个单调计数即可完成去重，无无界任务表。调用方先 GET，固定该 requestId，网络失败后仍用原号查询/重试，不能自行换号重做。

`cwd` 必须显式精确为 `/workspace`，绝不替换宿主 cwd。`argv` 为 1–128 个无 NUL 字符串，首项非空，单项 ≤ 8,192 UTF-8 bytes，合计 ≤ 24,576 bytes。`env` 可省略，最多 64 个键，键须匹配 `[A-Za-z_][A-Za-z0-9_]*` 且 ≤ 128 bytes，值为无 NUL 字符串且单值 ≤ 4,096 bytes，整个 JSON env ≤ 16,384 bytes。`stdin` 可省略，UTF-8 string ≤ 16,384 bytes。

父环境继承仍由 914 backend 的既有 `scrubbedParentEnv()` 删除 `DSH_*` 和凭据形名字；显式 env 按既有 subprocess 契约可显式提供凭据，但不影响已捕获的宿主路径，也不回显/写日志。这里只开放 batch stdin + stdout/stderr 各 16,384 bytes 尾部 collector，没有 pipe/PTY/宿主目录/grant/spill 配置入口。`graceMs` 固定为 10,000，不由 App 自选。取消本期唯一当前 job 使用 `setEnabled(false)`，同时关闭准入；GET 观察 cancelRequested 和真实 settled/unknown。

### 最终停止

```json
{"v":1,"instanceId":"<GET返回>","attemptId":"<GET返回或null>","action":"shutdown"}
```

立即关闭准入并返回 `202` 和完整状态对象，后台取消并等候当前 job，再调用同一 owner 的 dispose。重复调用复用同一 promise，不重启收尾。App 必须 GET 轮询，只有 `shutdownComplete: true` 且 `retirement.resourcesRetired: true` 才能确认可继续 nativeStop；`202` 和请求成功均不表示该屏障已完成。失败后状态中的 UNKNOWN、native 退休证据仍保留。HTTP 超时不取消此过程，绝不可将 socket close / Node exited 当 native joined。

`shutdownComplete` 仅表示没有 native owner，或 native joined=true 且 retirementError=false、相关资源退役已确认；它不把历史 job UNKNOWN 改成成功。已发布的可写 instance 保留，因此 `filesRemoved:false` 可与 `resourcesRetired:true` 同时成立。App 在 nativeStop 前必须取得该确认；若状态仍 unknown，须保留结果并明确呈现，不可写成任务成功。

## 3. GET / 成功 POST 的状态对象

固定返回以下键，不返回宿主路径、原始错误 message/cause、环境、argv 或凭据：

```json
{
  "v":1,
  "instanceId":"UUID",
  "attemptId":null,
  "state":"disabled",
  "enabled":false,
  "admission":false,
  "guestOpened":false,
  "ownerRetained":false,
  "workspaceLease":false,
  "restartRequired":false,
  "shutdownComplete":false,
  "nextRequestId":1,
  "ownerState":null,
  "backendState":null,
  "progress":null,
  "lastErrorCode":null,
  "job":null,
  "retirement":null
}
```

- `state` 为 `disabled | installing | enabled | disabling | stopping | stopped | unavailable | failed | unknown`。后端真实 `quarantined` / closed fault 和 job UNKNOWN 优先派生 unknown，不能只读可能陈旧的 owner.state=active。`enabled` 是用户请求的开关值；`admission` 仅在同一实际 opened backend 健康且不在关闭过程中时为 true。
- `guestOpened` 来自当前 backend 的实际状态，关闭开关但保留 VM 时仍可 true；不代表生产每任务授权、宿主 workspace、PTY 或所有插件命令就绪。
- `ownerRetained` 只表示 service 仍持有同一 owner 对象；不是“完整 VM 内存已释放”的反义测量。`ownerState`、`backendState` 是既有状态字符串或 null，状态源必须真实。
- `progress` 为 `null` 或 `{stage:string,done:number|null,total:number|null,step:string|null}`，只有固定/有界阶段与计数，不含文件名/URL。观察回调异常不得改变安装成败。
- `job` 为最近一个 job，接受新 job 才替换已结局记录；UNKNOWN 不允许被新 job 覆盖。最多一个 active job，不维护无界历史。

```json
{
  "id":1,"state":"queued","started":false,"cancelRequested":false,
  "outcome":null,"errorCode":null,
  "stdout":{"encoding":"base64","data":"","totalBytes":0,"retainedBytes":0,"truncated":false},
  "stderr":{"encoding":"base64","data":"","totalBytes":0,"retainedBytes":0,"truncated":false}
}
```

`job.state = queued | running | settled | unknown`；started 仅在 backend handle.started fulfilled 后 true。`outcome` 是 914 的真实 `{exitCode,signal,cancelled}`，必要时带 `notStarted:true`、`requestedSignal:'SIGTERM'`，没有预测性补零。UNKNOWN 保持 outcome=null。流数据是复制出的已收到 raw bytes 的 base64 尾部，totalBytes 与 retainedBytes 分开；上限固定，GET 不消费数据，也不把 UI 接收作为 guest sink ACK。

`retirement` 为 null 或 `{resourcesRetired:boolean,filesRemoved:boolean,dataRetained:boolean,ownerQuarantined:boolean,native:null|{joined:boolean,retirementError:boolean|null,apiResult:number|null},releaseErrorCode:string|null}`。真实未 join 可为 `{joined:false,retirementError:null,apiResult:null}`，不得因 `!null` 或默认 `0` 而升级为已退休；有 native 时仅 `joined === true && retirementError === false` 可确认退休。只输出已观测字段，native 缺失时为 null，不补造 joined。将同 owner 资源退休与 job 结局分离。

## 4. 错误与并发

错误体为 `{"v":1,"error":{"code":"ERR_...","message":"HTTP标准短语"},"status":<当前完整状态>}`；鉴权拒绝不附 status。400/413/415 为请求问题；409 为 stale/busy/disabled/failed/unknown 等拒绝；shutdown 已受理但未确认只在 GET 状态中报告，不能把 202 当完成；503 为缺 connection 或可信 host path。仅在首次显式启用后才可能发现 assets 缺失，此时后台状态 `unavailable`。

setEnabled(true) 在 installing 时为幂等保持；setEnabled(false) 在 disabling 时同样保持，不重发 cancel；在 disabling 完成前 true 拒绝 busy。shutdown 一旦开始不可重新开启。不存在自动重试、后台重建、跨 App 恢复或每任务 grant 已完成的声明。已发布数据不得被 shutdown 或下次安装覆盖/自动清理；若下次启动发现已保留 instance 但无恢复实现，明确拒绝并保留它。

## 5. 需要联测的实际边界

1. 真实现有 BrowserAuth + HTTP route，鉴权前无操作，GET 无 owner/native/下载调用；runtime / attempt stale 不运行。
2. 通过真实 SubprocessRuntime 注册 route；唯一 preload 在插件前捕获可信路径，插件修改 env 后不能重定向目录/库；worker 不注册第二 owner。
3. 实际 914 socket protocol：opened→执行→双 EOF/ACK→完成；active 后真实 socket 断流→GET unknown，后续 run 拒绝，shutdown 后不改写 job UNKNOWN。
4. off→terminate 请求→真实 waitForExit→disabled→on，同一 owner/session 创建计数仍 1。
5. 安装 progress observer throw 不破坏安装；安装 cancel 的真实边界与已发布 dataRetained / native joined / filesRemoved 区分。
6. 真实 RuntimeController stop/reset 必须等上述 shutdownComplete，HTTP 失败或 UNKNOWN 未确认不能先 nativeStop/reset。此项由 root / 独审实现验证。
