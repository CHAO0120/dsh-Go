# OHOS fork 的固定版本修补

`prepare-forks.py` 是 `check-arkts.sh` 和 `build-hap.sh` 共用的准备器。输入是已经解析的插件包目录；它不下载依赖，不改 pub 缓存或 SDK。`patches.json` 钉住输入、输出的完整包树 SHA256、补丁 SHA256、每个修改文件的前后 SHA256，并保留上游仓库、标签和 commit。

树指纹按路径排序，将每个普通文件的相对路径、字节数、SHA256 编成无多余空白的 UTF-8 JSON 后再取 SHA256。包括 Dart、ArkTS、测试、示例和许可证；不忽略缓存或额外文件。包内符号链接、缺文件、多文件或未知字节直接失败。`--input` 还拒绝根目录符号链接；package_config 模式先解析并规范化 file URI，再核实际包内容。文件权限不参与跨宿主的内容指纹。

准备器先在仓库外的临时目录校验并应用补丁，再核完整输出树、修改集合和输入未变，最后发布到一个新目录。输出已有内容会失败。`output/package` 是完整插件包，`output/report.json` 保存前后逐文件清单；report 不混进包的指纹。新的修补项加入同一清单，重新钉住明确审核过的前后像，不能宽松接受不同版本。

## 当前 WebView 修复

固定上游为 `oh-flutter/flutter_packages` 的 `webview_flutter-v4.13.1-ohos-1.0.2`，commit `89476bb7432938a54e5b09b449d1d031e85f0e5c`，包目录 `packages/webview_flutter/webview_flutter_ohos`，共 127 个普通文件。只修改两个 ArkTS 文件：

| 入口 | 上游行为 | 修补后行为 |
|---|---|---|
| `onSslErrorEventReceive` | 无条件 `handleConfirm()` | 调用一次 `handleCancel()` |
| 新 WebView 的 mixed mode | `0`，即 All | `2`，即 None |
| mixed mode 未知值回退 | All | None |

显式选择 `0/1/2` 仍分别得到 All/Compatible/None。应用当前没有显式设置 mixed content；未知值不会意外放行。OpenHarmony SDK 26.0.0.38 的 `ets/component/web.d.ts` 声明了这三个枚举值和 `SslErrorHandler.handleCancel()`。Android 应用 targetSdk 为 28；[Android WebSettings 文档](https://developer.android.com/reference/android/webkit/WebSettings#setMixedContentMode(int))说明 Lollipop 及以上目标默认拒绝混合内容，[WebViewClient 文档](https://developer.android.com/reference/android/webkit/WebViewClient#onReceivedSslError(android.webkit.WebView,android.webkit.SslErrorHandler,android.net.http.SslError))说明证书错误默认取消加载。

这两个修补没有给用户增加绕过证书错误的开关，也没有实现新的 SSL 提示页面。页面具体显示、系统错误页和证书握手结果仍须在设备验证。

## 构建接缝

`check-arkts.sh --with-forks` 从既有固定 overrides 取上游，把需修补的 fork 扩展到完整包树，再调用准备器；编译副本来自准备后的 `package/ohos`。普通不带 `--with-forks` 的检查不编这些 fork，不能拿它证明 fork 编译通过。

`build-hap.sh` 在第一次 pub get 和既有平台 switch vendoring 后，从实际 package_config 找到 fork，准备到 `app/ohos/.vendor/forks`，向本次临时 overrides 追加修补包路径，再执行 pub get。随后要求实际解析根精确指向准备包，且完整输出 SHA 相同。build 后仍要求根与所有受保护源文件相同，仅允许清单声明的 `ohos/build`、`ohos/oh_modules`、`ohos/.hvigor`、`ohos/oh-package-lock.json5` 新产物；127 个原文件不在这些路径下，新增或篡改其他源码仍失败。再检查 `entry/oh_modules` 实际安装的修改文件。原来的退出清理继续恢复 Android lock，移除本次 overrides 和 `.vendor`。没有修改 Android 构建入口、锁文件、依赖声明或引擎补丁。

## 独立复核

输入必须是上述固定标签下未经改动的完整插件包。以下命令的工作目录为本仓库；`FORK` 和 `WORK` 是调用方选择的目录。

```sh
python3 -I -B tooling/ohos/prepare-forks.py \
  --package webview_flutter_ohos --input "$FORK" --output "$WORK/prepared"
DSH_WEBVIEW_FORK="$WORK/prepared/package" node --test --test-isolation=none \
  tooling/ohos/tests/webview-security-contract.mjs
DSH_WEBVIEW_FORK="$FORK" python3 -I -B tooling/ohos/tests/prepare-forks-contract.py
```

第一组检查执行真实 ETS 中提取的 SSL 回调和 mixed-mode 方法体，配合明确的 handler 替身；测试不会重写成另一份等价实现。第二组实际调用 CLI，检查未知源、错补丁/输出指纹、符号链接、覆盖保护、pub 选择、实际安装文件和失败时 overrides 保持。原始 fork 在第一组应失败，修补后通过。

这些是源码、宿主组件和构建准备合同。真实 Dart pub get 可以验证依赖解析；它们均不替代完整 HAP 构建、ArkWeb 渲染或真机证书测试。
