# iOS 宠物 PiP：接入合同与验证

本实现面向 ios5 W3 / ADDENDUM-01，基底为 `df42181d227549dd313375e0791325fb936a942d`。新增原生文件在 `app/ios/Runner/PetOverlay/`。没有改 Dart UI、l10n、Android 或现有宠物素材。**本研究环境没有 Swift/Apple SDK，尚未编译 Apple 代码、运行模拟器或真机；下面的 Apple 测试入口不能记作已通过。**

## 行为与边界

- 默认关闭。首次开启只能在前台通过原生说明框明确选择；“始终显示”是另一次选择。两个设置独立持久化。
- 默认只在已认证的手机操控任务期间准备可见视频源。结束最后这个任务立即请求关闭 PiP、停止绘制，并释放自己仍持有的音频配置。没有沿用 Android 的五分钟延迟。只有用户另行选择 `alwaysShow` 时，结束任务后继续显示。
- Dart 的 `PetState` 继续是唯一的状态归约结果。原生只读取 `state/tier/packId/size/quiet/reduceMotion/bubble.text/target` 等既有字段，按真实 `pack.json`、PNG 格子与逐帧毫秒呈现。不从 phone 请求推导新 mood，不展示 `ask`、`detail` 或会话正文，不在 PiP 内批准任何操作。
- 暂用一个真正可见、非交互的 160×106 pt 原生预览，位于 safe area 右上、顶栏下方。Auto Layout 随旋转重排。最终 UI 可通过 `attachSource(to:)` 把同一个源放入手机操控状态卡。这个过渡位置仍需在具体页面/横屏上检查是否遮住内容；不能把没有做过的界面检查写成通过。
- 使用标准系统 PiP 控件。点击画面通常先显示系统控件；**通过系统“还原到 App”按钮回到 App**，不承诺任意点击画面直接跳回。没有私有 `controlsStyle`，没有画上去却不能点击的“停止”按钮。
- 系统播放/暂停键先请求暂停该 task id 的手机准入；不会取消任务所有权，也不会自行批准、停止或恢复。返回 App 后，原生框提供“保持暂停 / 继续 / 停止任务”。只有真正在前台选“继续/停止”，且当前对话框身份及 task id 都仍匹配，才调用相应 owner 回调；被撤销或替换的旧框不能对同一任务补发确认。
- 系统关闭 PiP 会 snooze 并暂停当前手机任务，不能由后续 `push` 自动重开。新语音/媒体会话接管、音频中断、锁屏、PiP 失败或不可用都不能继续报告 `keepingAlive=true`。后台 phone 准入仍必须由 phone owner 检查 `isKeepingAlive`，不能用 `enabled`、`usable` 或声明了后台模式代替。

## 与 phone owner 的 Swift surface

所有入口和闭包都在主线程 / `@MainActor`。

```swift
let overlay = IOSPetOverlay.shared
overlay.register(registrar: registrar)
overlay.onTaskPauseRequested = { taskID in /* 立即锁住新动作；在途结果未知时不重放 */ }
overlay.onTaskResumeConfirmed = { taskID in /* 新的前台用户选择；只恢复匹配的 task */ }
overlay.onTaskStopConfirmed = { taskID in /* 停止匹配的任务，然后 endPhoneTask */ }
overlay.beginPhoneTask(id: taskID, sessionID: ownerSessionID, line: maskedAppOrStep)
overlay.updatePhoneTask(id: taskID, line: maskedAppOrStep, progress: 0.4)
overlay.endPhoneTask(id: taskID)
```

`taskID` 必须来自 `IOSPhoneControl` 的单调任务编号。相同 id 不能换 session；结束后的旧 begin、旧 end、旧进度或旧确认都不能重开/停止新任务。`line` 应只含应用名称或已经脱敏的短步骤，不传 clipboard、输入正文或凭据。`progress` 可为 nil，有限数会约束到 0…1。

| Surface | 含义 |
|---|---|
| `isUsable` | 用户已启用、设备支持、选择的宠物包有效、未 snooze/失败；是配置与素材就绪状态 |
| `isKeepingAlive` | 上述要求、实际 PiP active 且未 suspended、仍持有匹配音频配置、protected data 可用、当前仍有显示需求；是准入所需的实时观察，不是保证未来一直运行 |
| `statusSnapshot` | 下表同一份状态 |
| `sourceView` / `attachSource(to:)` | 将真正可见的同一 `AVSampleBufferDisplayLayer` 源嵌入主线卡片；不要缩成 1 px、隐藏、透明或放到屏幕外 |

`attachSource(to:)` 的调用方还须保证宿主及祖先的 transform 不缩小/移出内容，裁剪区域容得下整个源。当前默认预览没有变换；`sourceVisible` 只执行下列局部几何检查，不是完整的有效可见面积或遮挡检测。

Root 的注册、project Sources、`Info.plist` 和 phone 生命周期接入由组合补丁负责；本目录的组件补丁不能单独视为功能已上线。

## `dsh/pet_overlay` 合同

原有 Dart 方法保持名称和返回类型：

| Dart → native | 参数 | 返回 / iOS 行为 |
|---|---|---|
| `push` | 原 `PetState.toMap()` | null；渲染已归约状态 |
| `status` / `permissionStatus` | 无 | status map；iOS 不执行 Android 的试加悬浮窗口探针 |
| `setEnabled` | `{enabled: bool}` | status；开启需前台说明确认，关闭即时生效 |
| `setAlwaysShow` | `{on: bool}` | status；首次开启需已 enabled，并单独前台确认 |
| `unsnooze` | 无 | status；只允许前台恢复准备，不恢复 phone 执行权限 |
| `requestPermission` | 无 | bool，报告设备是否支持；没有虚构系统授权弹窗 |
| `openAppDetails` | 无 | false；iOS 没有对应 Android 的应用悬浮权限页 |
| `startPictureInPicture`（新增 iOS） | 无 | bool；仅主线明确的前台用户按钮调用，不能作为模型工具 |
| `reviewPausedTask`（新增 iOS） | 无 | status；仅前台显示当前 task 的继续/停止确认 |

native → Dart 仍用同通道的 `status` 事件。标准还原使用现有 `SystemEntries` 导航，不额外发送 `answer`、`stop`、`voiceFallback`，也不把返回 App 当作批准。

既有字段：`enabled/alwaysShow/snoozed/showing` 为 bool；`permission` 在硬件支持时为 `granted`、不支持为 `denied`；`canDraw` 表示支持，`accessibility=false`；`sdk` 是 iOS 主版本号，`manufacturer="Apple"`。这让旧 `PetOverlayStatus.fromMap` 可以读取，但 `working` 仍只是旧版的开关/权限组合，**不等于保活成功**。

新增字段均为加法，主线 UI 可据此显示“就绪 / 系统不可用 / 已暂停 / 需返回确认”：

| 字段 | 类型与含义 |
|---|---|
| `platform`, `backend` | `"ios"`, `"pictureInPicture"` |
| `supported`, `possible` | 设备支持；AVKit 此刻能否开始 |
| `active`, `suspended` | AVKit 当前实际 PiP 状态 |
| `sourceAttached`, `sourceVisible` | 源连到 window；当前前台、source bounds 至少 80×50 pt、转换后矩形与 window 相交、源及祖先未 hidden 且 alpha≥0.99。未计算祖先裁剪后的可见面积，也不能检测被其他 view 遮挡 |
| `audioSessionConfigured` | 自己的 `setActive(true)` 曾成功且配置仍匹配；**不是系统提供的实时 audio active 查询** |
| `usable`, `keepingAlive` | 上述两个 Swift 属性 |
| `phoneTaskActive`, `taskId` | 是否有当前 owner；int 或 null |
| `paused`, `needsStopConfirmation` | phone owner 已收到暂停请求；需要新的前台选择 |
| `requiresForegroundConfirmation` | true |
| `errorCode` | 稳定错误码或 null；无原始异常、路径、会话标题或凭据 |

参数错误返回 `FlutterError("overlay_arguments")`，后台请求确认返回 `overlay_foreground_required`，已有前台对话框返回 `overlay_busy`，未启用却选择 alwaysShow 返回 `overlay_disabled`，旧引擎 handler 返回 `overlay_detached`。

状态中的错误包括 `overlay_unsupported`、`overlay_pet_not_selected`、`overlay_pack_missing/invalid`、`overlay_sheet_invalid`、`overlay_source_missing`、`overlay_audio_busy/failed/replaced/interrupted`、`overlay_media_reset`、`overlay_device_locked`、`overlay_pip_start_failed`、`overlay_buffer_failed`、`overlay_display_stalled`、`overlay_render_invalid/too_small/failed`。不应把这些错误展示为 Android 的权限说明。

## 音频与系统依据

主线只需在 `UIBackgroundModes` 数组加入 `audio`（保留原来项），即 Xcode 的 Audio, AirPlay, and Picture in Picture 背景能力。实现使用 `.playback` / `.moviePlayback` / `.mixWithOthers`，到有显示需求、可见 source 已建立时才激活。关闭时只在当前配置仍与自己设置的 tuple 完全相同的情况下 deactivate 并恢复旧 tuple；Voice/Media 已接手时不覆盖它。它不播放静音循环、不占用定位、不访问麦克风。

Apple 的 [媒体播放配置](https://developer.apple.com/documentation/avfoundation/configuring-your-app-for-media-playback) 说明了 PiP 所需音频/后台配置；[WWDC21 AVKit](https://developer.apple.com/videos/play/wwdc2021/10290/) 说明 sample-buffer content source、五个播放 delegate 和 live content 的无限时长范围；[自动 inline PiP](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/canstartpictureinpictureautomaticallyfrominline) 仅应为用户当前关注内容开启。这里用这些 API 表达任务宠物视频，不把后台模式当作永久执行许可证。

[mixWithOthers](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/mixwithothers) 允许与其他 App 音频混合；[notifyOthersOnDeactivation](https://developer.apple.com/documentation/avfaudio/avaudiosession/setactiveoptions/notifyothersondeactivation) 只用于关闭会话。这些是配置语义，不证明在某台手机上不会影响录音/扬声器路由；Voice、NativeMedia、电话/闹钟/耳机等交互仍需实测。

没有找到可据以承诺固定运行时长或能耗数字的依据。本实现不会报告“保证后台持续 N 分钟”。`isPictureInPicturePossible/Active/Suspended` 可能变化，系统、用户或别的媒体可以中断。设备测量至少要记录机型、iOS/build、前台/后台、网络/推理负载、温度/电池、PiP 状态及任务完成时间；分别比较关闭、任务模式、alwaysShow。普通模拟器结果不能替代这组真机结果。

## 可复现验证

### Linux：资产与脚本

```bash
python3 -B tooling/ios/pet-overlay-tests/audit-assets.py --output /tmp/pet-asset-audit
bash -n tooling/ios/pet-overlay-tests/contract.sh
bash -n tooling/ios/pet-overlay-tests/capture-simulator.sh
```

资产审计对真实两个包的 44 个文件检查 PNG 尺寸、格子范围、box×scale 与逐帧引用，共 1162 个时间帧引用 / 1075 个唯一格，并保存逐文件 SHA。`asset-reference-montage.png` 是源素材参考拼图，标签明确为 reference；**它不是 Swift / UIKit / PiP 截帧**。

### Swift host：实际生产状态/帧规则

```bash
bash tooling/ios/pet-overlay-tests/contract.sh
```

编译真实 `PetOverlayState.swift` 和 `PetOverlayPack.swift`，覆盖默认关、独立 alwaysShow、同 owner 暂停/继续/结束、旧回调、路径校验、bubble 到期/quiet、真实包所有帧边界、重复格、循环/一次性、三档尺寸、隐藏时钟冻结、reduced motion、sleeping 不偷换成其他 mood 等。没有 Swift 编译器时明确 exit 77 / SKIP，不可算 PASS。

### Apple Simulator：全组件编译与真实 UIKit 截帧

```bash
bash tooling/ios/pet-overlay-tests/capture-simulator.sh booted /tmp/pet-native-capture
```

需要本机 Xcode 和已存在的 iOS Simulator。脚本在独立 test bundle 中编译全部五个生产文件，UIKit/AVKit/CoreMedia/CoreVideo 都来自真正 Apple SDK，只有 Flutter 与 `SystemEntries` 是标明的 fixture shim；正常 Runner 的真实 Flutter 编译仍是单独 gate。自动执行只渲染 synthetic 内容，检查 BGRA sample buffer 的四角/方向，输出 66 张生产 renderer 的 PNG、source SHA 与带本次唯一 run id 的 receipt。它验证初始 enabled/alwaysShow/keepingAlive 都为 false；不会自动点击同意、开启 PiP 或执行手机动作。

App 留在模拟器供手动测试：开启并读说明→begin synthetic task→明确点击 Start PiP 或返回主屏→系统暂停→系统还原→保持暂停/继续/停止→核对 task id 与状态。还要检查关闭、音频被接手、系统中断、任务期间换宠物、横屏位置、无宠物/错误资产等；fixture 的 phone 回调只记录 synthetic 动作，没有真实手机准入锁，所以真实 phone 集成须再验。

**本机已执行**：Linux 资产审计与 shell/Python 语法；Swift host 和 simulator 均因工具链缺失未执行。正式包必须保留这个验证边界，等 CI/维护者的 Apple 构建与设备结果再更新。
