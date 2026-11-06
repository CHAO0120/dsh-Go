# 固定 iSH 与任务桥构建（I1/I2）

**未在 Apple 上编译。** 此项只输出可交给 iOS CI 的 DshGuest.framework，不宣告 guest available，不启动内核，不接 N-API 或开放挂载。编译成功不证明 sandbox、iPhone 可运行或已能安装 Linux；任务接口和受限挂载由后续项接入。

```sh
# Mac: LLVM 负责 Linux ELF VDSO；Xcode clang 负责 iOS Mach-O。
brew install meson ninja llvm
export PATH="$(brew --prefix llvm)/bin:$PATH"
tooling/ios/build-ish.sh iphoneos app/ios/Engine/build/iphoneos/guest
tooling/ios/build-ish.sh iphonesimulator app/ios/Engine/build/iphonesimulator/guest
# 先prepare-engine，提供对应SDK的NodeMobile与头文件：
tooling/ios/build-guest-addon.sh iphoneos app/ios/Engine/build/iphoneos/guest
tooling/ios/build-guest-addon.sh iphonesimulator app/ios/Engine/build/iphonesimulator/guest
```

需要 Python 3.11.8+（含 tarfile data filter）、Meson、Ninja、LLVM clang/lld、patch 和 Xcode SDK。两种 SDK 都是 arm64，最低 iOS 15；脚本自身不签名，embed-engine.sh 负责复制与签名。JIT 固定关闭，ELF VDSO 作为数据编进 framework，禁止上游 dummy VDSO fallback。

上游 commit、URL、压缩包 SHA256 和关键构建文件 SHA256 在 source.lock.json。下载缓存仅存于 app/ios/Engine/ish-cache；每次实际编译都重新校验、解压、以零 fuzz 顺序打 build.patch 与 job-runtime.patch，不信任旧解压树。`--cache-key SDK` 无下载，计算全部脚本/patch/许可输入、runtime/ios/guest/native所有源码、LLVM clang/lld、Meson/Ninja、Xcode和SDK版本；Apple key 需在 Mac 上运行。输出 .ish-build.json 附带全部 framework 文件摘要，命中时逐个复验；缺失或修改会重编。此缓存是同一受信任 CI 的加速，不是对恶意 receipt 的签名证明。

本补丁修复全量链接实际暴露的四份重复 gadget（保留 math.S 与 gen.c 参数流一致的实现），为 ELF 增加 SHA512变量 GOT 访问，补齐 Linux stat/FD路径/netlink 条件分支，并修复静态 offset 生成器对路径空格和失败退出的处理。Apple 文件系统与 netlink 分支保留上游行为。Linux netlink 端口仅用于构建验证，接口字节统计仍为默认值，不作运行能力承诺。

Linux 验证用同一 source pin、同一 patch、同一 whole-archive shared_library；链接附加 --no-undefined 与 -Bsymbolic（避免 ELF gadget 短分支绕到可插入的 PLT）。ARM64 Linux 主机可直接运行 `build-ish.sh linux OUT`；x86_64 主机必须提供 `DSH_ISH_LINUX_CROSS_FILE=/absolute/linux-arm64.ini`，指向 Meson 的 clang ARM64/sysroot配置。输出 DshGuest.so 和实际 libvdso.so.elf（不导出引用临时 object 的 Meson thin archives），仅用于验证，不嵌入 App。

```sh
python3 tooling/ios/ish/test-build.py
bash -n tooling/ios/build-ish.sh
```

发布 framework 自带 GPLv3全文、上游 LICENSE.md/ LICENSE.IOS、精确源码地址和本地 patch。发布者仍须提供对应发布版本的完整 DSH Go源代码与构建脚本；SOURCE.txt 说明获取路径，不把移动分支当作完整源码交付。编译入口不复制上游 app 主程序。


build.patch显式列出生产C单元，将其编入libish，并为整个上游/kernel/glue定义DSH_IOS_GUEST_CONFINED=1；N-API `.cc`不进kernel Meson目标。job-runtime.patch包含受限mount、任务线程追踪、禁用native offload、PID1 bookkeeping信号保护和不改全局SIGPIPE的初始化分支。两份patch随DshGuest.framework附带。

独立build-guest-addon.sh先调用build-ish校验同SDK产物，再以Xcode clang++链接同SDK NodeMobile.framework和DshGuest.framework。它每次重新编译小型Owner（不缓存可能与NodeMobile错配的addon），输出未签名的DshGuestBridge.framework；install_name为@rpath/DshGuestBridge.framework/DshGuestBridge，rpath包含@loader_path/..与@executable_path/Frameworks。它不被build-ish反向调用，不会递归。测试fixture不进入任何生产target。
