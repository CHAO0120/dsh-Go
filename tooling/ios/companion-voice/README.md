# iOS 伙伴配音

这是现有 `dsh/companion_voice` 的 iOS 实现，最低 iOS 15。Dart 的默认关闭、
用户选择声音源、请求外部语音服务、临时音频文件管理和同一句系统朗读回退沿用原合同。
本增量不增加界面、小组件、录音、网络请求或原生声音缓存。

**验证状态：本次 Linux 环境没有 Swift 编译器、Apple SDK、模拟器或 iPhone。
Swift/XCTest 的 Apple 编译和执行均为 UNRUN；没有声音、权限对话框、PiP 共存、
设备能耗或后台时长的实测结论。** 下列保证分为代码中的状态合同和仍须 Apple 验收的行为。

## 接入

`IOSCompanionVoice` 是 `@MainActor` 对象。由 AppDelegate 在已有主 actor 上创建并保留：

```swift
companionVoice?.dispose()
companionVoice = IOSCompanionVoice(messenger: registrar.messenger(), pipAudioConfigured: {
  IOSPetOverlay.shared.statusSnapshot["audioSessionConfigured"] as? Bool == true
})
```

AppDelegate 的持有属性、Runner / RunnerTests 的 Xcode 注册和现有 iOS compile job
测试条目由同一交付的集成改动负责。再次初始化 Flutter engine 时先 `dispose()` 旧对象，
再绑定新 messenger。该方法返回前结清旧工作，移除通道 handler、通知 observer 和 timer；
迟到的旧读取或 delegate 结果不能发事件或启动新声音。

不需要新增麦克风用途声明或请求麦克风权限。`ready` 路径只查询系统当前可用的 voice，
不创建朗读请求，不调用音频会话 setter、`prepareToPlay` 或 `play`。
这是源码调用范围；首次安装的权限界面仍须实际观察。

## 通道合同

所有方法和回调使用 MethodChannel `dsh/companion_voice`。

| 方法 | 参数 | 结果及行为 |
|---|---|---|
| `ready` | `{language: "zh-CN"}`，缺省同左 | `bool`。成功选择供后续句子使用的系统 voice；不支持的语言返回 false，保留先前成功选择。表示当时可解析，不表示以后一定能发声或所有音质永远离线可用。 |
| `speak` | `{id, text, flush?, pitch?, rate?}` | `bool`。必须先成功 ready。默认排入 TTS 队列；`flush=true` 仅结清 TTS 的正在朗读和排队句子。参数拒绝时不清旧队列。 |
| `play` | `{id, path}` | 异步 `bool`。后台读取、构造解码器和检查时长；实际受控 `AVAudioPlayer.play()` 返回 true 才接受。替换先前 clip，保留 TTS 域。 |
| `stop` | 无 | `null`。结清两个输出域和待加载请求，不自动继续旧内容。 |

保留 Android 的两个独立输出域，所以直接同时调用 `speak` 和 `play` 时可能重叠播放。
正常 Dart 外部声音泵一次只等待一句。不要把本通道解释成自动混排的统一播放列表。

ID 必须是 1–128 个 ASCII 字母、数字、下划线或连字符，保留大小写、不重写 ID。
现调用方使用 `vN` 和 `preview-N`。已被在播、排队或加载工作占用的 ID 不能再次接受；
终态或 `stop` 后可复用。新 utterance / player 对象与各输出域的 UUID generation
共同判定回调归属，同名旧对象不能结束新工作。

回调方法 `event` 的参数为 `{type, id}`，range 另有 `start` / `end`，错误或中断可有
不包含文本、文件路径或系统异常详情的稳定 `code`：

| type | 含义 |
|---|---|
| `start` | TTS 的 didStart（或首个有效 range）；clip 的 play 返回 true。不是扬声器可听性的证明。 |
| `range` | 原始 `speechString` 的 UTF-16 location 与 exclusive end，逐字传递给 Dart。 |
| `done` | 当前对象的完成回调，clip 还要求 successfully=true。 |
| `stopped` | stop / flush / 替换 / dispose / 可观察中断或会话撤销。 |
| `error` | 已接受的工作遇到解码失败或无进展超时等问题。 |

每个**已接受**请求只结清一次终态。未开始朗读的排队项也由本控制器结清，不依赖系统
为它们逐一发 didCancel；Apple 明确该回调不覆盖未朗读项。[1]

被拒的新 `play` 不发 start 或终态，也不会在稍后的读取、解码或播放器回调中发出它们。
这是 Dart 用**同 ID** 回退 `speak` 所需的边界；早到的播放器结果先缓存在 provisional
请求里，只有 play 成功才进入已接受状态。先前已接受的其他工作仍拥有自己的终态。

### 文本、速率和范围

- 一句最多 4096 UTF-16 code units / 16384 UTF-8 bytes；TTS 域合计最多 32 条、
  32768 UTF-16 code units（包括当前句）。超限整句返回 false，不截断后朗读。
- pitch 范围 0.5–2.0，默认 1；Dart 传 1.12。
- rate 参数范围 0.1–4，默认 1；映射为 `DefaultSpeechRate * rate`，再限制到 Apple
  的 min/max 常量。它是参数映射，不声称跨平台等速或精确线性倍速。[2]
- 每句创建独立 utterance，并在入队前固定 voice、rate、pitch。后来 ready 不改变旧句。
- `A😀é中` 有 6 个 UTF-16 code units、4 个 Swift grapheme clusters。NSRange `(1,2)`
  直接给 Dart `start=1,end=3`；不按 `String.count`、Unicode scalar 或 runes 换算。[3]
- TTS 使用 **5 分钟无有效进展** watchdog，不是 5 分钟总时长。首次 start 或有效 range
  的 UTF-16 终点前进会刷新；重复 start、重复/逆行 range、越界 range 都不刷新。
  超时结清当前及其 TTS 队列为 error，clip 域可继续。

## 本地音频边界

原生只接受系统缓存目录的 canonical anchor 下这一叶子名称：
`companion-voice-<exact-id>.<kind>`。`kind` 为 Dart 现有的小写
`wav / mp3 / m4a / flac / ogg / bin`。通过目录 descriptor 和 `openat` 读取；
拒绝最终叶子符号链接、目录、空文件、超限文件和不符合名称/目录的路径。
原生不从 URL 下载，不复制到新缓存，不持久化，不删除或覆盖 Dart 原文件。

一次输入最多 **16 MiB**，实际播放器时长必须有限、正数且 **≤55 秒**。文件按块读取，
取消在块间检查；前后 fstat 与大小检查拒绝观察到的文件改变。扩展名只用于匹配 Dart
合同，解码器按实际 bytes 初始化：`ogg`、`bin` 或任意容器/编码组合都**不保证支持**，
不能解码则返回 false。Apple 要求输入是 Core Audio 支持的格式。[4]

读取/构造播放器的逻辑等待上限为 5 秒。取消、超时和 dispose 立即使该请求不可接受，
并在可运行的主 actor 上返回 false；这不表示能中断已进入的系统读取或解码调用。
生产 loader 使用跨实例共享的单一物理槽，直到后台工作真实返回才放开；
替换 Flutter engine 也不能趁旧 decoder 未返回而启动第二个物理工作。忙时返回 false。
文件 bytes 有界不等于已测得系统解码器峰值内存或硬实时延迟。

后台阶段不调用 `prepareToPlay()`。Apple 明确它会激活共享音频会话，而 `play()`
会按需隐式调用它；因此 play 必须在请求身份和会话许可有效后执行。[5]
读取、容器解析和播放器构造离开主线程；会话 setter 与实际播放启动留在主 actor。
这些系统启动调用的最坏耗时未在设备测量，不能宣称整个启动绝不阻塞。
已接受 clip 超过其声明 duration + 3 秒仍无有效完成时结清 error；该界限最多 58 秒，
在 Dart 外部音频泵的 1 分钟等待前留余量。

## 音频会话交接

`IOSCompanionAudioLease` 协调两个配音输出域，只有两域都空才释放自有会话。
它不新增全 App 音频仲裁协议，也没有可证明当前 OS active 的公共查询。

| 当前情形 | 配音行为 |
|---|---|
| VoiceChannel 的 record 或 playAndRecord | 新工作拒绝，零会话 setter。 |
| NativeMedia 的 playback / spokenAudio | 新工作拒绝，零会话 setter。 |
| PiP 的真实 owner/configured closure 为 true 且配置匹配 moviePlayback / mixWithOthers | 可撤销借用；本插件零**显式** category/active setter，结束也不释放借来的会话。 |
| 配置像 PiP、但其 owner closure 为 false | 拒绝；不能仅凭相同 tuple 宣称有借用权。 |
| 普通可接管配置 | 配音设置 playback / default / mixWithOthers，成功激活后使用。仅保留自身所有权且配置仍匹配时 deactivate/恢复旧配置。 |

借用只表示本地协作许可；`audioSessionConfigured`、一次 setActive 成功、category/mode/options
相同都不是 OS 此刻 active 的证明。借用路径也不能宣称框架零隐式激活，因为 player.play()
仍有上面的 prepare 行为。[5][6]

AVSpeechSynthesizer 显式使用 `usesApplicationAudioSession=true`，避免创建另一套由系统
独立管理的朗读会话。[7] 每个启动、有效事件和活动期间每 250ms 检查当前租用状态。
PiP 即使 tuple 未变，只要 owner closure 撤销也停止两个域，不擅自 deactivate。
自身 setCategory 的通知在配置仍匹配时不会把新请求误停。

来电等 interruption began、旧输出设备消失、媒体服务 reset，或者可观察的会话接管，
会结清工作，不在 interruption ended 时自动重播。周期检查补充 mode/options-only
变化没有 categoryChange 通知的情况。系统暂停 App 时 timer 无实时保证，重新可运行时
先检查跨睡眠的单调期限与租用状态。MainActor 串行化是应用内调用顺序，不是 OS 全局事务。

## 回归与 Apple 验收

`IOSCompanionVoiceTests` 调用生产 engine、audio lease、file loader，不复制另一套队列实现。
记录适配器覆盖两个域的独立生命周期、FIFO/flush/stop、准确 ID、同 ID 旧对象、
UTF-16 范围、false play 的 inline/late 回调、读取取消/超时、dispose、双域最后释放、
PiP owner 撤销且 tuple 不变、自己通知不误停、后继配置不被覆盖、队列预算和无进展期限。
实际文件读取测试只生成自己的合成缓存文件；两个播放器构造测试只用合成无效 bytes
或 50ms 静音 PCM，不调用 play。跨实例 loader 测试用受控队列验证实际物理槽释放时机。

Apple CI 接入既有 RunnerTests，选择 `-only-testing:RunnerTests/IOSCompanionVoiceTests`。
本机无 Apple 工具链，全部是**已编写、尚未执行**的 XCTest；静态源码/补丁适用性检查
不转写为 XCTest PASS，也不把录制适配器行为说成真实音频输出。

首次 Apple 验收还须记录：

1. 新装默认静音；ready 中文/英文不发声、不出现麦克风提示；不存在的语言明确 false。
2. 用户开启后，实际可听的中英文 FIFO、flush、stop；emoji/组合字符 range 与 Dart 嘴型对齐。
3. Dart 真实本地 WAV/MP3/M4A 与实际不支持的样本；失败后同 ID TTS 回退只有自身终态。
   不把一次成功扩大成全部后缀/编码支持。
4. 录音、NativeMedia、PiP 分别先开始/后开始；旧会话停止后不覆盖新 owner；PiP 关闭后
   借用配音结束。对同一时刻的系统音频行为保持结果记录，不能由 tuple 替代。
5. 来电、拔耳机、后台/锁屏、媒体 reset 后无自动重播；重新前台后新的显式请求可恢复。
6. 连续读取期间 stop、同 ID 复用和 messenger 更换；测实际加载/启动延迟与内存。
   记录失败和未知，不把停止请求等同于 OS 立即物理静音。

## 公开 API 依据

以下只用于设计与声明核对，不是本次执行证据：

1. [Apple didCancel](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizerdelegate/speechsynthesizer(_:didcancel:))。
2. [Apple rate](https://developer.apple.com/documentation/avfaudio/avspeechutterance/rate)、
   [pitchMultiplier](https://developer.apple.com/documentation/avfaudio/avspeechutterance/pitchmultiplier)。
3. [Apple range delegate](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizerdelegate/speechsynthesizer(_:willspeakrangeofspeechstring:utterance:))、
   [NSString UTF-16](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Strings/Articles/stringsClusters.html)、
   [Dart String](https://api.dart.dev/dart-core/String-class.html)。
4. [Apple AVAudioPlayer(data:)](https://developer.apple.com/documentation/avfaudio/avaudioplayer/init(data:))。
5. [Apple prepareToPlay](https://developer.apple.com/documentation/avfaudio/avaudioplayer/preparetoplay())、
   [play](https://developer.apple.com/documentation/avfaudio/avaudioplayer/play())。
6. [Apple AVAudioSession](https://developer.apple.com/documentation/avfaudio/avaudiosession)、
   [setActive](https://developer.apple.com/documentation/avfaudio/avaudiosession/setactive(_:options:))。
7. [Apple usesApplicationAudioSession](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/usesapplicationaudiosession)、
   [speechVoices](https://developer.apple.com/documentation/avfaudio/avspeechsynthesisvoice/speechvoices())。
