# 917 首次安装 owner

生产入口是 owner.mjs 的 loadLinuxInstallationManifest({assetsDirectory}) 与 createLinuxInstallationOwner({directory,nativeLibraryDirectory,manifest,onProgress,bootTimeoutMs})。assetsDirectory 与 nativeLibraryDirectory 必须由可信运行时发布根提供，不能来自插件 argv/env。loader 只读取固定 install-manifest.json 与五个固定文件名，不让清单选择任意宿主文件。

owner.install({signal}) 返回 Promise<{backend,active}>。下载进度与普通文件 gzip 展开有 done/total；guest 安装报告 begin/base/tools/pivot 阶段。实际 903 opened 帧验证通过后才写 active.json 并交出 914 backend。该状态名是 opened-private-guest，workspaceLease=false，不是整体 P0 READY。正常插件宿主 cwd 仍需后续授权9P，不能偷换为客体 /workspace。

## 主机与客体分工

902 使用固定 URL/长度/SHA256 下载归档，失败清理下载暂存。906 在 App 仅解压普通 gzip 镜像、拷贝归档并补齐512字节边界；不在宿主创建 tar 内的链接，也不执行 mke2fs、fork 或 shell。4个 virtio 盘为只读 bootstrap、只读下载归档、可写空ext4、只读工具归档。客体 tar 展开到 ext4，再 pivot_root，卸载 oldroot，exec 903 Python controller。epoch 每次为32随机字节，从可信kernel cmdline传入；wall clock也由宿主传入。普通作业不继承控制FD。

## 取消与发布

下载/准备取消在未创建VM时清理本次私有目录。VM开始后，取消或失败先 stop/join；只有 joined=true、retirementError=false 且无未结算transport FD债务，才删除镜像。真实 /proc/self/fd 测试检查本次目录内的磁盘句柄归零。退役未知时保留目录，撤掉active标记，隔离owner，不声称取消完成。VM设备堆仍未全部释放，干净停止同样 stopped-quarantined，不支持同App再建VM；install在dispose后明确拒绝。

active.json 位于本次私有attempt目录，原子rename在真实opened之后；不是允许下次App自动重用的安装缓存协议。dispose停止同一个VM并删除本次安装数据。后台保留/跨App恢复/可重启VM未实现。owner依赖912固定库，内部只把已创建的可信session交给914；测试第二参数可以注入归档传输/会话，生产factory不公开该参数。

## 构建与打包输入

构建机运行 tooling/ohos/build-linux-assets.py --diskimage <固定Bellard包> --alpine <固定3.24.4包> --tools-root <固定工具树> --agent <903-R2源> --output <新目录>。脚本固定验证上游包与guest-agent SHA，在构建机mke2fs，不需要mount；生成image/install-manifest.json及五个普通资产。需把这六个文件放入签名运行时的固定linux-assets目录，由可信owner传给loader；不要打包512MiB未压缩构建中间盘。镜像工具树的包依赖、许可证沿用903锁定输入，本补丁不引入新第三方库。

当前真实输入为903工具树host fixture，构建脚本记录其来源而不冒称独立可复现APK获取流水线。HAP资源聚合和平台启动owner仍需共享入口接线；本包不修改并发中的915/918或HAP composer。没有SDK/HAP构建或真机测试。

## 验证

research/linux-owner/run.py 固定输入SHA，运行strict生产owner：下载取消、展开取消、故意注入退役失败且保留数据、真实guest安装中取消、真实随机epoch安装/pivot后任务及关闭，15项。测试归档经显式fetch fixture流入，不能据此声称本环境华为云HTTP成功。902既有真实HTTP取消回归另行运行。旧909固定epoch工具盘被新owner实际拒绝，保留真实ERR_OHOS_LINUX_UNKNOWN/epoch mismatch反例。
