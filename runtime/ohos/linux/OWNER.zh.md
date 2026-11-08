# Linux 安装 owner（917，930 接线与数据保留）

生产入口是 owner.mjs 的 loadLinuxInstallationManifest({assetsDirectory}) 与 createLinuxInstallationOwner({directory,nativeLibraryDirectory,manifest,onProgress,bootTimeoutMs})。assetsDirectory 与 nativeLibraryDirectory 必须由可信运行时发布根提供，不能来自插件 argv/env。loader 只读取固定 install-manifest.json 与五个固定文件名，不让清单选择任意宿主文件。

owner.install({signal}) 返回 Promise<{backend,active}>。下载进度与普通文件 gzip 展开有 done/total；guest 安装报告 begin/base/tools/pivot 阶段。实际 903 opened 帧验证通过后才写 active.json 并交出 914 backend。该状态名是 opened-private-guest，workspaceLease=false，不是整体 P0 READY。正常插件宿主 cwd 仍需后续授权9P，不能偷换为客体 /workspace。

930 的实际 OHOS subprocess service 在 `/dsh-go/v1/linux` 注册经现有 connection 鉴权的 App 控制入口。唯一 host preload 在插件前捕获 `DSH_GO_OHOS_LINUX_DIRECTORY` 和 `DSH_GO_OHOS_NATIVE_LIBRARY_DIR`；前者来自可信 `HostOptions.linuxDirectory = filesDir + '/linux-tools'`。普通 profile、argv、后续 env 和 HTTP body 不能选择这些路径。固定 assets 从当前 runtime 模块的 `linux/assets/` 读取。完整字段、请求去重、取消和状态见 [CONTROL.zh.md](CONTROL.zh.md)。此入口没有给 CommandRouter 注入 Linux，插件命令路由保持其既有能力。

## 主机与客体分工

902 使用固定 URL/长度/SHA256 下载归档，失败清理下载暂存。906 在 App 仅解压普通 gzip 镜像、拷贝归档并补齐512字节边界；不在宿主创建 tar 内的链接，也不执行 mke2fs、fork 或 shell。4个 virtio 盘为只读 bootstrap、只读下载归档、可写空ext4、只读工具归档。客体 tar 展开到 ext4，再 pivot_root，卸载 oldroot，exec 903 Python controller。epoch 每次为32随机字节，从可信kernel cmdline传入；wall clock也由宿主传入。普通作业不继承控制FD。

## 取消与发布

下载/准备取消在未创建VM时清理本次私有目录。VM开始后，未发布的取消或失败先 stop/join；只有 joined=true、retirementError=false 且无未结算transport FD债务，才删除该未发布 attempt。已发布的可写 instance 属于用户，正常停止与故障收尾均保留其数据。`resourcesRetired`、`filesRemoved` 和 `dataRetained` 分别报告资源退出、删除和数据保留；没有以 unlink 或目录消失替代关闭证明。已发布目录用 retired.json 或 quarantined.json 代替 active.json，保留目标身份。若元数据更新失败，错误与保留目录仍存在，不把它改成资源释放成功的证据。

普通开关 false 只关准入并取消/等候本 service 的 job，保留同一个已打开的空闲 VM；再次 true 复用同 owner。最终 App shutdown 才调用 dispose 并等待真实资源退休。VM设备堆仍未全部释放，干净停止同样 stopped-quarantined，不支持同 Node 再建 VM；install 在 dispose 后明确拒绝。主进程不能因 HTTP 202、超时、socket close 或 Node exited 而宣称 joined。历史 job UNKNOWN 即使 native 后来退出也仍 UNKNOWN。

active.json 的原子 rename 发生在真实 opened 之后。跨 App 恢复尚未实现；新 owner 遇到已有 `.installation-*` 目录会明确拒绝，而不会下载新副本掩盖、覆盖或清理旧数据。因此 705 的长期可恢复实例仍是 P0 待完成项。owner 依赖 912 固定库；测试第二参数可注入归档传输/会话，生产 factory 不公开该参数。进度观察回调抛错被隔离，不能把安装成功改判为失败。

`retired.json` 只记录已确认的宿主 native thread/drive 退休。当前 guest-agent 的 closed 帧没有另行提供 `sync`/`syncfs` 事实；宿主 `fflush` 只处理已经送达的块写。因此保留文件不证明客体文件系统干净或可安全恢复，后续必须另补客体 flush 屏障与恢复验证，不能据此把 705 宣称完成。

## 构建与打包输入

构建机运行 tooling/ohos/build-linux-assets.py --diskimage <固定Bellard包> --alpine <固定3.24.4包> --tools-root <固定工具树> --agent <903-R2源> --output <新目录>。脚本验证固定上游包与 guest-agent SHA，在构建机 mke2fs，不需要 mount；930 增加干净的 `<output>/assets/` 六件目录，`image/` 只保留诊断与构建中间产物。六件为 install-manifest.json、bbl64.bin、kernel-riscv64.bin、tools.block、bootstrap.ext4.gz、empty.ext4.gz。不要把 512MiB 未压缩构建盘装入 App。

composer 可选 `--linux-assets <output>/assets`，固定发布 `runtime/ohos/linux/assets/`，核对实际 bytes/SHA 与展开 SHA，并纳入 runtimeVersion、manifest 和 ZIP32 回读。资产存在时 HAP 固定库配对检查必须要求 libdsh_linux.so；library-only 可保留诊断兼容，但运行时缺资产仍 unavailable。构建细节见 `runtime/ohos/package/LINUX-ASSETS.zh.md`。工具树输入来源沿用固定 903 材料，不冒称独立可复现 APK 获取流水线；本执行器没有 SDK/HAP 构建或手机实测。

## 验证

research/linux-owner/run.py 固定输入 SHA，运行 strict 生产 owner：下载取消、展开取消、故意注入退役失败且保留数据、真实 guest 安装中取消、真实随机 epoch 安装/pivot 后任务及关闭。930 更新正常关闭断言为发布数据保留与 retired 描述符。归档经显式 fetch fixture 流入，不能据此声称本环境华为云 HTTP 成功；原生库、guest 与退休事实须来自真实 driver 结果。

`linux-control-entry.test.mjs`、`linux-owner-control.test.mjs`、`linux-control.test.mjs` 登记为 `linux-app-control-plain/strict`：真实 Cordis 入口、锁定 BrowserAuth、HTTP 与 TCP socket、生产 owner/backend、真实文件字节；createSession/requestStop/join 为明确的原生边界替身，不能把这组称为真实 VM join。既有 host-startup 组增加插件阶段修改 env 后的封存路径检查与 Worker 无 owner 路径检查。跨 App 恢复、生产每任务 grant、SDK/HAP/手机不在这些通过项内。
