# Linux 固定镜像下载（902，尚非Linux READY）

`downloadLinuxBase` 是Node侧独立下载入口：传入App私有绝对目录、构建时可信的{url, bytes, sha256}、AbortSignal和onProgress。源必须HTTPS且不含用户凭据；拒绝重定向，下载长度和SHA双核；源默认应由本机发布清单指定华为云URL。没有伪造可下载的产品镜像URL或校验值。当前没有随HAP发布的实际guest镜像，调用方必须先提供真实固定清单。

产物为内容寻址目录内base.bin，状态仅verified-base，不能映射为Linux已就绪。不会解包符号链接，不碰现有DSH rootfs；guest ext4也只作为普通数据下载，不能host dlopen。临时目录每次独占；写入/进度回调/HTTP/长度/哈希/取消失败均关闭body与文件并删除本次staging。已有缓存重新核完整SHA；损坏明确报错，不静默覆盖。并发下载相同SHA仅接受验证过的赢家。

直接使用已有OH node:http(s) dispatcher，避免无WebAssembly时内置fetch默认llhttp失败；没有修改任何builtin或读SIM变量，无新npm依赖。全局网络profile不参与启用此入口，单项和实际production transport一致。URL/manifest需来自可信宿主配置，不能让guest或插件任意指定落盘目录。

本包没有开关的ArkTS通道、安装器激活、实际guest镜像构建或boot，也没有HAP/设备通过。UI由本机监听progress阶段download/verified和done/total；关闭开关传AbortSignal。成功提交是rename的提交点，取消发生于提交后不删除已验证缓存。目录fsync/断电持久性未承诺，重启读取缓存会重新校验。完整P0仍需900与后续native/job/授权根接线。

单测：`node --test runtime/tests/ohos/linux-base-download.test.mjs`；严格：`node --jitless --import ./runtime/ohos/sim/preload.mjs --test runtime/tests/ohos/linux-base-download.test.mjs`。门登记linux-base-download-jit/strict。实际8项均通过，包含真实本地HTTP流的cancel；用本地映射只隔离公网，不声明华为云/手机TLS实测。

先红：新功能缺失导入失败。真实追加反例：原global fetch在严格无WASM下本地HTTP失败（ReferenceError WebAssembly），改显式复用已有dispatcher后严格8/8。原始失败日志保留。受影响既有net/test.sh基底与候选均36 PASS/5 FAIL：307/308 multipart与falsy abort reason null/0/false；属于本沙箱同Node二进制的共同现状，没有修或隐藏。shell入口第一轮失败即停止，不能称第二轮已执行。没有跑完整门。
