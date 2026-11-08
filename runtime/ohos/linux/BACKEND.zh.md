# LinuxRuntimeBackend（914）

这是正式宿主 JS 后端，通过 912 固定可信目录下的 libdsh_linux.so 与 903-R2 客体控制器通信。工厂 `createLinuxRuntimeBackend(options)` 同步返回对象；`await backend.opened` 仅在真实客体 opened 帧通过校验后完成。

options 包含可信 nativeLibraryDirectory、绝对 configPath、与客体一致的 64 位小写十六进制 epoch、已有私有 temporaryRoot；closeTimeoutMs 默认 10000。生产路径不读取 SIM 开关。第二参数 internals.createSession 只用于显式测试注入。共享 owner 负责配置、镜像和 native 目录的可信来源。

## 授权边界

当前 confinement=[]，workspaceLease=false。prepare 明确抛 ERR_OHOS_BACKEND_CONFINEMENT，不签发无法落实的票据；spawn 同样拒绝 policy 与 confined argv。唯一可接纳 cwd 是显式客体私有 /workspace。通常插件传入的是宿主 cwd，必须先完成授权 9P 映射才能运行；本后端不偷换 cwd、不假装已有宿主工作区隔离。PTY 未实现。

## 作业与流

spawn 接受现有 subprocess spec，返回 stdin Writable、stdout/stderr Readable（pipe 模式）、collected、started、done、terminate、waitForExit。串行提交作业，严格验证 epoch/seq/job、偏移、base64、帧序和结果。环境先用现有 scrubbedParentEnv，客体 PATH/HOME/TMPDIR/LANG 使用客体默认值，最后显式 env 可覆盖或用 undefined 删除。

每个输出流的客体未确认信用窗口为 64 KiB；pipe 另有 64 KiB Readable 高水位，不能把两者相加误称总共仅 64 KiB。push(false) 后停止 ACK，消费恢复后才续传。collector 使用现有公开 OutputCollector；ACK 在 Buffer 已交给 collector.push 后发出。ignore 是明确丢弃，inherit 等待写入接受及 drain。stdin 每次切片最多 4096 字节，最多 64 KiB 未确认，Writable 回调要等客体实际 write ACK；调用方仍须遵循标准 Writable 背压。

完成必须有双 EOF、全部输出被宿主 sink 接受并确认、客体 produced 偏移一致，以及客体 PID namespace 树回收后的 complete。cancelled 原样保留，不能由 exitCode 推测。SIGTERM/SIGKILL 均是取消请求，903 实际用 namespace SIGKILL；结果保留真实 leader exitCode/signal 和 requestedSignal。leader 先退出而子孙仍在时，最终可合法得到 exitCode=0、signal=null、cancelled=true。取消宽限到期没有释放事实则进入 UNKNOWN，绝不虚构强杀完成。

## 生命周期

断线、乱序、错误或无法确认回收会拒绝 done/waitForExit 并保留 live owner 隔离。每个作业不会 stop/join VM。只有 backend.dispose 取消与排空作业，等待真实 closed 帧后才 requestStop/join。干净 dispose 仍报告 ownerQuarantined=true：TinyEMU 堆设备未完整释放，不支持同 App 重建 VM。未知态不提升为 closed/READY。

## 验证

运行 tooling/ohos/research/linux-backend/run.py，参数 --node、--dsh-prefix、--native-library-dir、--guest-config、--output。它复制所有可写盘后执行 JIT/strict 协议测试及两个真实客体（正常与断线），记录固定输入 SHA256。run-gates.py 登记 linux-runtime-backend；需 prepared/dsh、tinyemu_native_library_dir 与 tinyemu_guest_config 输入。

这是 Linux host 真实 Node NAPI + TinyEMU + 四盘安装/pivot 后客体的验证。不是 SDK/HAP 编译或真机验证；尚未闭合应用首次下载安装 owner、工作区 9P、可重启 VM，不能宣称整体 P0 READY。
