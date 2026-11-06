# 参与贡献

[English](CONTRIBUTING.en.md) · [项目首页](README.md)

## 暂不接受外部 Pull Request

本仓库目前**不接受任何外部 Pull Request**（代码、文档、配置、模板都不接收）。

- 外部 PR 会被入口检查自动关闭，见 `.github/workflows/pr-gate.yml`。
- 想提功能建议、改进想法或反馈问题：请[开 Issue](https://github.com/ccch1mneyyy/dsh-Go/issues/new/choose)，写清使用场景和期望的行为。
- 维护者自己（及其代理）的内部 PR 不受影响。

这是暂时限制，恢复接收外部 PR 时会更新本页。

## 欢迎参与

欢迎通过 Issue 反馈问题、改善文档和翻译、补充测试，或开发插件。影响协议、数据格式或权限行为的较大改动，先说明问题和方案，便于协调。

## 提交问题

使用仓库的 Bug 或功能建议模板。说明 App 版本、Android 版本、主机连接方式，以及可以重复的最小步骤。界面问题附截图或短视频；提交前检查并遮盖隐私信息。

涉及凭据泄漏、越权访问、未授权操作或其他安全问题，请按 [SECURITY.md](SECURITY.md) 私密报告。

## 准备开发环境

按 [README](README.md) 完成工具链与运行时准备。普通 App 开发不需要维护者的签名密钥、内测通道令牌或生产部署凭据。

- Flutter/Dart：使用仓库对应的 Flutter 版本和 App 的 Dart SDK 要求。
- Android：JDK 17，运行时 ABI 与 APK flavor 匹配。
- 插件 SDK：Node.js 22.19 或更新版本。SDK 在 `sdk/plugin-kit/` 内使用，尚未发布到 npm。

## 修改范围

让一个 PR 解决一个可以单独审阅的问题。修复时说明原来的行为、触发条件和改后的行为；避免夹带无关重命名、格式化和目录调整。

- UI 文案按现有中英文结构维护，优先使用项目已有组件和图标。
- 对行为改动补充能覆盖问题的测试；仅改文字或布局时，给出相应检查或截图即可。
- 修改客户端、桥接或插件协议时，同时检查兼容性和另一端的调用方。
- 不手工编辑生成文件；修改其源文件并运行对应生成器。
- 新增或移植第三方内容时，说明项目、版本或提交、源文件和许可证，并保留必要的署名、许可及修改说明。确认来源条款与目标目录许可兼容；移动文件不会自动改变许可。

## PR 自动测试与文档豁免

手机开发时优先跑相关回归；合并前由 [PR Tests](.github/workflows/pr-tests.yml) 执行标准自动化套件，不要求手机重复承担全量测试。

- **代码、配置或混合改动：** 运行完整默认 Flutter 测试（包括已有 golden）、两个 Dart 包、含 TypeScript 的插件 SDK、媒体与全部示例插件、站点/市场离线测试及分享 Worker 构建/类型/单测、隔离且已校验补丁的 DSH 单测与主机桥接集成、Python 工具/资源测试，以及两个 debug flavor 的 Android JVM 单测。任何必需任务失败、取消、意外跳过或缺少结果，汇总门禁都失败。
- **纯文档改动：** 只有 [分类规则](.github/scripts/pr-tests/policy.mjs) 中明确允许的路径及普通非可执行文件才能豁免重测试：根目录的说明/贡献/安全/许可文件、指定 SDK README、PR 模板、`docs/` 下 Markdown 和 PNG/JPEG/WebP，以及对应的内置指南帮助页。仍须通过分类器回归、文案输入校验、指南同步/校验与 SDK 技能同步/加载测试；豁免不等于“全量测试通过”。
- **不豁免：** 界面 ARB、依赖与锁文件、CI/构建配置、运行时补丁、代理指令和技能入口（包括指南 `SKILL.md`）、其他运行时资产，以及未知路径。混入任何这些文件就全量；重命名前后路径都会检查，符号链接或可执行位变化也不能当文档放行。不使用标题、标签或改动行数决定豁免。

默认 npm 测试入口按完整 Git 提交树核对，新增包漏接入 CI 会使策略回归失败；运行时只按仓库锁文件安装，不因本地稀疏检出缺文件而临时改用未锁定依赖。云端 Android 通过 `DSH_MAVEN_MIRRORS=0` 使用官方 Maven 上游，避免跨境镜像失败；本地默认仍使用原镜像，依赖版本声明不变。

完整差异为空或无法读取时不授予豁免。主线 push、手动触发和合并队列始终全量。固定汇总检查名为 **PR test gate**；整个 workflow 不用路径过滤器跳过，因此文档 PR 也会产生同名结果。只编辑 PR 标题或正文不会重启测试。PR 改投 `main` 后若当前提交缺少对应结果，应更新分支或重开 PR 触发检查；缺少结果不等于获豁免。

首次部署时，先合并 workflow 并确认上述检查实际运行，再由管理员在 `main` 的分支保护/规则集中将 **PR test gate** 设为必需检查并要求最新提交通过；仅添加 workflow 不会自动禁止合并。CI 与分类规则的修改仍须维护者审阅，普通同名 required check 不是防止恶意篡改 workflow 的独立信任边界。现有外部 PR 入口门禁仍只运行默认分支代码，不执行 PR 头代码。

“全量”指上述默认自动化套件，不包括需要真实凭据的 live 测试、尚无基线的 opt-in 预览、完整 rootfs/PRoot/direct 发布验收或 Android 真机测试。这些项目的跳过仍须如实记录；涉及触摸、键盘、权限、手机操控、安装和启动方式的改动，不能用 CI 结果代替新包真机确认。

抽屉 golden 的彩色 emoji 使用 [Noto Emoji v2.051](https://github.com/googlefonts/noto-emoji/tree/8998f5dd683424a73e2314a8c1f1e359c19e8742/fonts)（[SIL OFL 1.1](https://github.com/googlefonts/noto-emoji/blob/8998f5dd683424a73e2314a8c1f1e359c19e8742/fonts/LICENSE)），CI 校验固定字体的 SHA-256 后通过 `DSH_TEST_EMOJI_FONT` 加载。本地定点复现时将该变量指向同一字体文件，无需替换系统字体；缺少字体直接报错，不用方框代替。Ubuntu 自带的 2.047 不能当作同一截图基准。CI 先单独跑深浅色文件夹编辑截图，再跑完整 Flutter 套件，比较阈值和已提交基准图不变。

## 常用检查

以下命令从仓库根目录运行，供本地复现和定向回归使用；PR 的 CI 范围按上述规则决定。在 PR 中写明实际执行的命令、CI 链接及结果；缺少设备、资源或依赖时，明确写“未运行”和原因。

[CI](.github/workflows/ci.yml) 会在 PR 和 `main` 上跑这些检查：PR 跑通用检查和改动涉及的部分，合入 `main` 后跑全量，结果看 `CI OK`。CI 不碰真机和真实账号，这部分仍要单独验证。

**Flutter 应用：**

```bash
(cd app && flutter pub get && flutter analyze && flutter test)
```

**真机调界面（热重载）：** `tooling/dev-run.sh` 把 debug 包覆盖安装到手机上已有的 release 版，再挂上 Flutter，按 `r` 几秒内生效。它用 `adb install -r` 加 `flutter attach`，不用 `flutter run`，因为后者安装失败时会先卸载，清掉手机上的数据。debug 模式动画偏卡，只用来看布局、尺寸和颜色，判断流畅度要打 release 包。需要 `app/android/key.properties` 和手机上的包同一把 key。

**Dart 通信包：**

```bash
(cd packages/dsh_client && dart pub get && dart analyze && dart test)
(cd packages/dsh_remote && dart pub get && dart analyze && dart test)
```

**插件 SDK：**

```bash
(cd sdk/plugin-kit && npm install && npm test)
```

SDK 的类型检查需要开发依赖 TypeScript；未安装时，相应测试会跳过。请检查测试输出，不能将跳过写成通过。生成器与同步顺序见 [SDK 维护说明](sdk/plugin-kit/README.md)。

**界面文案：** 修改 `app/lib/l10n/parts/` 的中英文 ARB，再生成并检查：

```bash
python3 app/tool/l10n_merge.py
python3 app/tool/l10n_merge.py --check
```

**用户指南：** 修改 `docs/guide/`，同步 App 内置的教学技能：

```bash
python3 app/tool/guide_sync.py
python3 app/tool/guide_sync.py --check
```

**插件教学技能：** 修改 `sdk/plugin-kit/skill/` 或 SDK 对应输入，再同步：

```bash
node sdk/plugin-kit/scripts/sync-skill.mjs
node sdk/plugin-kit/scripts/sync-skill.mjs --check
```

需要 APK 验证时，使用 README 中的构建入口。涉及 Android 进程、PRoot、直接启动、手机操控或更新安装的改动，应说明测试的 ABI、Android 版本、启动方式和设备；桌面测试结果不能替代真机结果。

配套站点和分享服务的本地测试已纳入上述 CI；市场的在线实扫/构建，以及 `services/`、`infra/` 的线上 smoke、部署和发布脚本不属于普通贡献检查。修改配套服务时，先确认测试目标是自己的本地环境；不要用生产凭据运行示例。

## 提交 PR

填写默认 PR 模板，用中文或英文均可：

1. 问题是什么，为什么需要改，以及改后的行为。
2. 关联 Issue、主要受影响模块与兼容性影响。
3. 实际运行的检查、结果和未验证范围。
4. UI 改动的前后截图或录屏；使用测试数据，遮盖个人内容。
5. 新引入内容的来源、许可证和必须同步的声明。

提交前检查差异，排除密钥、个人配置、真实对话、设备序列号、构建缓存与私有运维资料。诊断包和日志也需要人工检查；不要把自动打码当成保证。

评论请围绕问题、证据和实现，尊重不同使用环境。使用 AI 辅助的改动也需要由提交者读懂、验证并承担维护责任。
