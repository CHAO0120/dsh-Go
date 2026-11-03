# 鸿蒙本机凭据：四方法通道与密文仓库

五处默认存储（remote、forum、settings、provider keys、hosted links）通过
`AppSecureStorage` 选择平台。`Platform.operatingSystem == 'ohos'` 且没有显式注入
`FlutterSecureStorage` 时使用 `dsh/secrets`；其他平台和已有测试注入继续调用原
`FlutterSecureStorage`。不替换该依赖的全局 platform instance，不实现本应用没有使用的
`containsKey`、`deleteAll`、监听器或平台选项接口。

## 通道

`SecretsPlugin` 只需要 `FlutterPluginBinding.getApplicationContext()`，不使用 UIAbility。
应用注册代码应添加一个 `new SecretsPlugin()`。它处理以下请求：

| 方法 | 入参 | 成功返回 |
| --- | --- | --- |
| `read` | `{key: String}` | `String` 或 `null` |
| `write` | `{key: String, value: String}` | `null` |
| `delete` | `{key: String}` | `null`，不存在时也成功 |
| `readAll` | 无 | `Map<String, String>` |

Dart 的 `write(value: null)` 使用 `delete`，不会向原生发送空值。无效回包或原生错误是
失败，不被适配器转换成空串或空 Map。错误消息不包含键名、凭据、密文或系统路径。
插件支持 `secrets_invalid`、`secrets_unavailable`、`secrets_unreadable`、`secrets_io`
和 `cancelled`；现有界面自身的错误处理没有在这里改写。

## 为什么使用 HUKS

官方 Asset ArkTS 合同将单项 `SECRET` 限为 1–1024 字节。这里保存 SSH 私钥、论坛密钥
JSON 和整个 hosted-links 列表，现有调用没有这一上限，不能以 Asset 接口直接替换。
实现使用公开 HUKS AES-256-GCM 和应用私有目录中的一个密文文件，不采用 OH fork 的
preferences/RSA 实现，不把密钥或明文保存到 preferences、文件名或日志。

当前仓库的 compatible/target SDK 都是 26.0.0。密钥别名固定为
`DSH.Go.Secrets.AES256.GCM.v1`，使用 CE 存储等级。生成时设置
`HUKS_TAG_KEY_OVERRIDE = false`；查询只有明确缺失代码 `12000011` 视为不存在。
IPC、不可用等其他错误不会触发替代密钥。密钥生成 API 不返回密钥材料，本实现不调用
导出或明文导入密钥接口。

## 格式和提交顺序

文件为 `<filesDir>/dsh-secrets/vault-v1.bin`。其内容是：

| 字段 | 字节数 | 含义 |
| --- | ---: | --- |
| header | 8 | `44 53 48 53 01 00 00 00`，包含格式版本 |
| nonce | 12 | 每次写入由系统 CryptoFramework 随机源重新生成 |
| ciphertext | 可变 | UTF-8 JSON 记录数组的 AES-256-GCM 密文 |
| tag | 16 | 官方显式 nonce 模式下 `outData` 的尾部认证标签 |

AAD 固定为 UTF-8 `DSH-Go private secrets vault v1`，不是空值。解密将尾部 16 字节作为
`HUKS_TAG_AE_TAG`，其余密文作为输入。HUKS 每次 update/finish 输入最多 64 KiB；输出
先在内存保留，必须等 finish 认证成功才解析 JSON 或交给调用方。使用新随机 nonce
不是数学上的永不碰撞承诺。当前仓库整体在内存处理，内存随已保存数据总量增长；
没有把 Asset 的 1024 字节限制偷偷带入应用。

一次读取必须验证整个仓库，`readAll` 不返回部分结果。只有仓库文件确实不存在才视为
首次空仓库。已经存在的文件缺密钥、格式未知、认证失败或内容损坏时，读、写、删除
都报错并保留该文件。这也防止界面先捕获读取失败后保存空列表而覆盖原密文。

同进程的所有插件/engine 实例共用串行队列。每次修改都重新读取并认证旧文件，然后
加密新内容；使用 `mkdtemp` 创建私有临时目录，循环处理真实短写、fsync 临时密文、关闭、
rename 到最终路径，再 fsync 仓库目录。队列不是跨进程锁；没有推导其他进程并发写入
的保证。

提交边界是 rename。此前的写入失败或已观察到的 engine 退役不会发布新密文；rename
完成后的目录 sync 失败或迟到退役可能返回错误，但文件已经更新，不能解释为回滚。
首次创建目录时没有据此宣称整个父目录链具备经断电验证的持久性。临时文件只有密文；
清理尽力收束，不承诺任意崩溃后磁盘不存在旧密文残留。

## 升级、删除和设备范围

普通覆盖升级复用同一 alias、算法参数和 v1 文件；不自动更换密钥或将未知版本重建为
空库。删除一条记录会重写其余记录的密文，不删除仍供其他记录使用的 HUKS 密钥。
没有从旧 fork preferences 自动迁移数据，也不宣称所有历史安装都没有遗留数据。

华为官方说明应用卸载会销毁应用 HUKS 密钥，重装后不能用新密钥解开旧密文。这个
接口合同不等于本项目已经验证设备卸载清理、物理介质擦除、系统备份恢复或断电时点。
真机确认应分别做：同 bundle/signature 覆盖升级后四方法读回；卸载重装后旧密文不能
解开；锁屏/首次解锁的 CE 行为；系统 HUKS 不可用时可读错误且已有文件不被替换。

## 可重跑检查

Node 组件入口（`OHOS_TYPESCRIPT_PREFIX` 指向已有 TypeScript 5.9.3 前缀）：

```sh
node --test --test-isolation=none --test-reporter=tap --test-timeout=15000 runtime/tests/ohos/secrets.test.mjs
node --jitless --test --test-isolation=none --test-reporter=tap --test-timeout=15000 runtime/tests/ohos/secrets.test.mjs
```

组件执行真实 ETS、真实 Linux 文件和显式 HUKS/Flutter 替身；Node AES-GCM 只验证协议和
认证失败控制流，不作为设备 HUKS 的实现证明。Dart consumer 入口是
`app/test/secrets/secure_storage_test.dart`，覆盖 OH 通道、错误传播及五默认的 Android
行为。普通 `check-arkts.sh --hms-stubs` 的最终组合结果另附实际记录；HMS 非官方桩的
限制不被本次公开 HUKS API 编译消除。

Dart 的四项 consumer 是非 UI 测试，子目录 `flutter_test_config.dart` 不加载字体；
应用其他目录的视觉测试配置保持原样。依赖准备后可在 `app` 执行：

```sh
flutter test --no-pub --no-test-assets test/secrets/secure_storage_test.dart
```

OH 分支在 Linux 测试中使用适配器的显式平台测试入口；五处默认对象的原 key 和
Android 存储选择使用真实 Dart 调用核对。它不将 Linux 的 `Platform.operatingSystem`
改成设备值，也不是设备通道或 HUKS 的端到端测试。

## 官方来源

- [Asset 新增数据](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/asset-js-add.md)：SECRET 容量和持久性选项。
- [HUKS ArkTS API](https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/js-apis-huks.md)：密钥生成、查询、会话和 KEY_OVERRIDE。
- [HUKS 加解密](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/huks-encryption-decryption-arkts.md)：显式 nonce 的 GCM 数据和 AE_TAG 拆分。
- [随机数](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/crypto-generate-random-number.md)：CryptoFramework 随机源。
- [卸载与升级 FAQ](https://developer.huawei.com/consumer/cn/doc/doccenter-dev-faq/faqs-universal-keystore-16.md)：应用密钥生命周期和升级参数边界。
