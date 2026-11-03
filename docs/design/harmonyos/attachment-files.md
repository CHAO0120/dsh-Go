# OH 附件与文本文件选择

`attachmentPickerProvider` 在 `Platform.operatingSystem == 'ohos'` 时使用
`OhosAttachmentPicker`。聊天附件和 SSH 私钥导入沿用各自现有的 provider 调用；
Android 和其它平台继续使用 `DeviceAttachmentPicker`。图片选择和拍照也保留原路径。

固定 `file_picker 13.1.0-ohos.2` 会把系统返回的 `file://docs/...` 交给 Dart
`Uri.toFilePath()`，带 authority 的 URI 不能这样读取。OH 分支通过
`dsh/attachment-files` 调用独立的 `AttachmentFilesPlugin`：

1. `DocumentViewPicker` 提供选择结果 URI。
2. ArkTS 使用公开 `fs.open(uri)` 读取授权内容，每次最多读取 256 KiB，逐项复制到
   应用 `cacheDir` 下由 `mkdtemp` 创建的独立目录。展示名不参与缓存路径构造。
3. 有序返回每项的 `name/path/size/problem`。成功项的 `size` 是实际复制字节数；
   失败项无路径。Dart 读取普通私有路径，继续执行已有的流式预算检查。
4. Dart 在 `finally` 中用本次 `owner` 调用 `release`，释放已读、被拒绝和未消费的
   缓存。原始文档 URI、文件内容和私钥内容不写入日志。

## 预算与失败

文件单件上限 200 MiB，附件总预算 400 MiB，最多 9 项。Dart 把托盘已有字节数和
剩余数量扣除后传给 native，所以连续选择不能每次重新得到 400 MiB。真实 PNG、
JPEG、GIF、WebP 前缀使用 20 MiB 图片上限；扩展名不决定这一限制。

文本导入默认 64 KiB，调用者传入的较小 `maxBytes` 同时约束复制和 Dart 读取。
空文本保留为空字符串，用户取消为 `null`；畸形 UTF-8 仍按原合同使用替换字符。
文本超过预算抛出原有 `FormatException`，读取失败不返回部分私钥。

metadata 只能用于提前拒绝，不能授权后续读取。未知、过期或变化的长度仍由实际
读取计数约束。短写按已写字节同时推进文件偏移和 buffer 切片。一个文件超限或
复制失败会删除它的部分缓存，保留后面的合法文件；Dart 保留选择顺序中的首个问题。
256 KiB 是复制块大小，不是进程 RSS 上限；Dart 的现有附件模型仍会保留附件 bytes。
这里不使用插件桥的 `dsh/native-files` 8 MiB 通道。

## 取消与生命周期

公开 `DocumentViewPicker` 没有可用的关闭操作。`cancel`、Ability/engine 退役会使
结果失效并停止后续复制，但物理选择器未返回时保留 busy 槽；不启动第二个选择器。
复制在每个异步读取/写入边界检查当前 owner，关闭流后删除部分缓存。
尚未交付 token 的缓存由 native 自行释放，不依赖 Dart 收到返回值。

成功交付后保留 busy 槽，直到 Dart 读取结束并 `release`。清理失败时保留所有权和
busy 状态，返回 `ohos_attachment_cleanup`；后续显式 release 或生命周期退役可以
重试剩余清理，不会在文件尚留存时放开该槽。此合同不保证进程被强杀后的即时清理。

## 验证入口

- `tooling/ohos/tests/attachment-files-channel.test.mjs` 用固定 SDK TypeScript 适配器
  执行生产 ETS，使用真实 Linux 文件测试预算、短读写、取消、部分失败及释放；系统
  picker、URI 授权和 Flutter channel 明确是 API 替身。
- `app/test/ohos/attachment_files_test.dart` 用真实 Dart 私有文件流验证两种消费路径、
  默认平台工厂和释放协议。这个目录仅包含非视觉测试，不加载产品字体。
- 原有 `attachment_file_budget_test.dart`、`private_key_file_budget_test.dart` 与相应
  owner/callback 生命周期测试继续验证既有 Device 入口和 UI 消费合同，断言不变。
- SDK 26 编译、真机授权 URI、系统取消/后台切换、文档提供者长度变化仍须分开记录。
  Linux 替身通过不等于设备选择器或 OH AOT 已验证。

`EntryAbility` 应注册 `AttachmentFilesPlugin`；不需要额外系统权限或把外部 URI
转换为公共磁盘路径。
