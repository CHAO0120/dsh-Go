# O1/O2：鸿蒙运行时组成、落地资源与测量

本文与 `runtime/ohos/package/composition.json`、`compose-runtime.py` 一起构成可运行的组成定义。基底 c818155。它生成 HAP rawfile 的输入树和供传输/复核的 ZIP；**不编译或签名 HAP，不包含 libnode、runner、Ark host 及目标原生模块的体积**。SDK、目标 N-API 改名 ABI 和设备安装仍未验证。

## 固定输入与补丁边界

本次实际验证和20个性能样本的代码集合是：

| 输入 | 精确标识 |
|---|---|
| 公开源码基底 | c818155；快照 ZIP SHA256 `08a60f2136cffcedf3130d7a9d43cacb63c4cf57d6bea12f1bccf1f0978e39fb` |
| O2-native | `ff0c0efc619a90688368a369566ef7c023690405663e3e36c5f5edc9f2504c1b` |
| O4 流式小包 | `a69e7e2bfdc465133a2bd3bd7b34d4b2d22b2e14b20ed5616c7f789da656c90e` |
| 本组成补丁 | 以随包 patch.diff SHA256 为准；只新增本组成和受影响导入/不可用分支 |
| P2 v5 真 manifest 消费者 | 补丁 `9aa10dcc20235e638f8080609f7fd34ae2429e0f7a3a2e694633b0b22fc9fd12`；RuntimeCore.ets SHA256 `4cf15d7420cdc5d99bdadb4d3099972c488ef71a172816d0284e58fa02136976` |
| DSH | 0.2.1-rc.4；锁文件 SHA256 `9b61c5b60c82a3b64fb252af5c142d40d0c86aff30a17cdd5e1ca9d73df9a25c` |
| Node | 官方 Linux 24.22.1，所有 strict 样本带 `--jitless`，WebAssembly 不存在 |
| process npm 闭包 | 已有 package-lock SHA256 `5a815fc00cafc62fca834fe3e2abf6792bd3263c1a386cb2948d6a4063ed8f30` |
| 私有 RE2 | 固定生成物 SHA256 `80eaea2a9e50a2851e332fa4fccffeb01550584ad3c448a2eadd88b43373d5f1` |

**本次没有装 O6 和后继 O4b，也没有把插件安装拒绝小包混入性能样本。** 所以这些数字不代表全部后续补丁合并后的 App。P1B v2 另用本组成 v1 树验证了新 Host 的原样 profile/默认 cwd；性能样本使用严格仿真 round 与同等工作区配置，未把 Ark 调用耗时计入。

所有补丁仍分别从 c818155 `git apply`。组合重建先按以上包重放，最后应用本包。O4 修改 private Bash 的 changedAfter，组成只改 omitFromPrivateEsm；组成不覆盖 O4 的重写器。pins 只向 ohos 目标增加 diff。最终合并栈仍应由主线单独实测，不能用这份子集报告代替。

## 组成规则及保留行为

| 组件 | 最终运行树 | 启动/使用时行为 |
|---|---|---|
| DSH 核心、Web 资源、会话、工具、纯 JS 网络依赖 | 保留 | 实际五工具/审批回合运行，不只做静态扫描 |
| just-bash 3.6.0 | 排除整个 npm 原包；使用固定私有 ESM 及 Apache-2.0 LICENSE | filesystem 和 worker 都指向同一私有构建；保留既有已批准的 shell 命令 |
| just-bash Python | 原包 vendor/CPython wasm、Python 命令 chunk、worker 均不分发 | python/python3 未注册，明确不可用、可连接电脑执行 |
| just-bash SQLite / sql.js | 排除完整 sql.js 1.15.2 包、SQLite 命令/worker/关联 chunk | sqlite3 未注册；**Node 自带 node:sqlite 与 DSH session-query-sqlite 保留** |
| QuickJS/run 与 TypeScript 编译器 | 排除对应 npm 包和禁用的 js-exec chunk | 已禁用脚本入口保持明确拒绝，不转到缺包异常 |
| isomorphic-git 1.44.9（MIT） | 保留 API 和实际纯 JS 依赖；移除 cli.cjs、minimisted 2.0.1 整包 | init/add/commit/log 实际成功。minimist 若被其他包使用则保留 |
| diff 8.0.4（BSD-3-Clause） | 保留 ESM/CJS API、exports、LICENSE | 虽原为 just-bash 的传递依赖，后继 O4b 的直接导入仍可解析；本次实际验证 ESM diff/patch API |
| LibreOffice kit 与其 wasm 包 | 排除 | office-to-pdf 的启动静态 import 改为使用时动态导入；OH 分支先返回明确 unavailable。Office skill 显示连接电脑/原文档/PDF 替代路径 |
| sharp 与 @img 平台库/wasm | 排除 | 图像解码/重编码返回 OHOS_IMAGE_CODEC_UNAVAILABLE，给出电脑替代路径；不假装已完成像素解码。普通文件与已有 PDF 传递不因此改变 |
| sherpa-onnx 平台推理库 | 排除 | 本地 SenseVoice 在平台检查阶段给出系统输入法/电脑替代提示，不进入原生加载 |
| koffi、Windows FFI、node-pty、外部 ripgrep | 排除 | 对应外部平台/PTY 分支不能在 OH 运行；既有虚拟 rg 保留 |
| flock / require-builtin 的平台 npm 包 | 排除 | 两个固定 HAP libs 经 O2-native 助手加载；不存在数据目录中的 .node/ELF 副本 |
| 类型声明、source map、npm .bin/安装缓存 | 排除 | 保留普通 JS/JSON/资源和非声明 TS 源码；实际包有 source exports，不能把所有 .ts 都当类型声明删去 |

规则按 package 名及具体文件路径定义，不用“文件名含 python/sqlite”一刀切。最终仍有 Python 语法高亮 JS、node:sqlite 使用方、Inspector 的 wasm 图标/解析工具和 Undici 原有 llhttp-wasm.js 加载源；它们不是 just-bash 的 Python/SQLite 解释器。本包没有声称任意名字带 wasm 的源码都被删除。strict 环境实际没有 WebAssembly，真实 DSH 使用既有 OH 网络后端。

构建器逐文件检查路径、哈希和文件类型，拒绝 rawfile 中未归类的 `.node`、`.so`/数字版本后缀以及 ELF、wasm、PE、Mach-O 文件头；真实最终资源的文件集合在输出 ZIP 解压后逐项核对。`.node.js` 是合法 JS，不能按原先过宽的扩展规则误拒绝；这个实际问题已由 P2 v5 修正，构建器还执行**真实 RuntimeCore.validateManifest**，不是另写一个假消费者。

## 可追溯性与许可范围

生成目录保留 input-files.json（每个输入的路径、大小、SHA256、保留/排除理由）、input-packages.json（锁定版本、完整性元数据、package.json hash、license）、payload-files.json、private Bash 的 PROVENANCE.json、真实 P2 校验日志和 composition-report.json。最终归档 hash 和 runtimeVersion 来自实际 payload 文件集合。

Python 许可缺口通过不分发其运行时关闭；minimisted 通过同时排除唯一 isomorphic-git CLI 调用入口及整包实现关闭，且实际 Git API 无它仍运行。这里只是这两个固定组成范围的判断，不是对全部第三方许可的法律结论。原 licenses/texts 中 sql.js、minimisted 的声明/许可材料作为输入证据保留，`licenses/input-manifest.json` 明确是原输入清单，不应再误当最终运行时安装清单。

无新增外部运行时依赖、无锁文件升级。私有 RE2、Git 和 Bash 的输入许可、来源仍由原锁和已有 licenses 管理。

## rawfile、libs 与编译缓存

将生成的 `rawfile/dsh-runtime/` 放到 entry 的 `src/main/resources/rawfile/` 下。传输 ZIP 不是 App 启动时全量解压的对象：P2 按 manifest 核对资源，保留内容相同的文件，仅对变更文件写临时文件并 rename。安装中断标记阻止半成品启动；已有 Node 消耗实例时不更新活动树。

`libdsh_flock.so`、`libdsh_require_builtin.so` 与 libnode/runner/Ark host 留在 HAP libs。P1B v2 + P2 v5 将可信 Context 的安装目录传至固定映射；目标构建须使用主线 N-API 改名配方，不能把本测量的 Linux .so 当作 OH 产物。

Host 把 `NODE_COMPILE_CACHE` 放在 `cacheDir/node-compile-cache`，属于应用数据目录，不进入 immutable rawfile。缓存可删除重建，不是运行所需资产；库符号隔离和缓存是独立检查。

## 实测体积

下表“之前”是可重建的未裁剪参考布局：同一固定 npm 输入、同一 O4 源码修复和新原生映射，恢复组成前的四个 DSH 文件及原 private Bash omission list，并使用原 filesystem import。它包含桌面/native/wasm 输入，不能安装成合格 P2 rawfile。之后是实际组成输出。

独审补充：作者该参考前缀还包含不来自 npm 锁的 `node-addon-require-builtin-openharmony-x64` 五个测量夹具文件，共 112,374 字节（含 110,672 字节 Linux `.node`）。所以下表与原 20 样本中的 before 专指带夹具的 31,394 普通文件、587,126,907 字节参考；独审仅从 fresh npm 锁重建得到 31,389 普通文件、587,014,533 字节，另有相同的 30 个链接。两套 before 不能当成同字节输入或混用计时。共同 31,419 文件/链接完全一致，最终组成器排除这整个平台包，独审最终 ZIP 与作者逐字相同。

| 项目 | 之前 | 之后 |
|---|---:|---:|
| 普通文件数 | 31,394（另30链接） | 16,521（无链接） |
| 普通文件字节数 | 587,126,907 | 167,855,292 |
| ZIP 字节数（deflate9） | 179,007,585 | 49,042,775 |

普通文件体积减少 71.41%；对应传输 ZIP 减少 72.60%。前后 ZIP 都实际读回每个文件核对哈希；之后 ZIP 还包含 P2 manifest，之前保存 npm 链接元数据。它们不是 signed HAP 大小，目标 libnode/native/Flutter 体积没有估算。

最终 rawfile ZIP SHA256：`3f295a96f390d83cc4030e4fadde375771e7dfe6dee12a472d65626b353917a5`；runtimeVersion：`ohos-d14c9042340af480d175241b`。

## 真实冷热启动测量

每个 variant 5组，每组 cold→warm，variant 首发顺序交替，共20次。每次新进程、新 home、新 workspace，且要求真实 write/edit/read/grep/bash 五工具和两次审批完成；失败样本不会偷偷进入统计。cold 表示空 V8 compile-cache；warm 表示复用同组前一轮产生的缓存。**没有清 OS 页缓存、没有独占 CPU，也不是手机测量。** 输入是本地脚本模型响应，网络模型延迟没有混入。

单位 ms，括号为最小–最大：

| 运行树 / cache | URL ready 中位数 | Host ready 中位数 | 首完整工具回合中位数 |
|---|---:|---:|---:|
| before / cold | 6644.5（4298.8–15179.5） | 7637.6（4730.2–16482.3） | 2475.8（2146.4–4920.6） |
| before / warm | 5032.8（4324.8–7853.9） | 6006.3（5006.4–8804.6） | 2887.5（2084.6–3086.9） |
| after / cold | 4729.1（4097.3–7824.2） | 5397.7（4562.7–8714.9） | 3198.4（1945.6–3868.2） |
| after / warm | 5563.7（4651.9–6530.7） | 6278.1（5701.2–7349.0） | 3036.8（2140.9–3580.1） |

之前缓存实际1771文件、约10.69 MB；之后1707文件、约8.71 MB。每次记录缓存前后文件数/字节和宿主 load average，全部原始样本及每轮报告随包保留。cold URL 中位数在本轮降低，但 warm 的之后中位数没有降低，部分 warm 还慢于相应 cold；共享机器波动与样本范围使这些数字**不足以证明启动加速或编译缓存的普遍收益**。要定论，需要安静宿主上的更多配对样本、缓存读取命中证据，最后在目标设备/HAP上重复相同条件测量。

## 已执行的回归与剩余门

- 最终 payload 专项8项：真实 node:sqlite SQL；Git API；diff ESM/LICENSE；私有 Bash 中文读写；Python/SQLite/QuickJS明确127；Office/image/speech明确拒绝与替代路径。
- 既有5套进程测试只把 import 定位至最终 payload，断言不改：JIT85/85、strict85/85。覆盖边界、取消、流式和真实 Cordis 工具；没有使用开发 node_modules 顶替运行依赖。
- 构建边界6项：普通 client.node.js 可入包，native 后缀/隐藏 ELF/隐藏 wasm 拒绝，已有输出原样保留。
- 新鲜真实 Android 目标与 c818155 真实目标逐文件/目录/链接、mode、内容一致；Android recipe 输入3789字节、SHA256 `67a8c2a119a9d254ba27f6e657f11fca73ee30de499a723f2084f57f213f5f39` 不变。实际完整 shell recipe 对两 ABI 使用相同外部输入夹具时，输入流与版本后缀也相同；没有改构建器或伪造版本串。
- 最终合并栈（O6/O4b/市场拒绝等）重建、OH SDK、HAP 安装路径/提取、改名 ABI、设备冷启动/后台行为仍是独立验收项。作者的测量结果不代替专职 reviewer 对精确补丁 hash 的结论。
