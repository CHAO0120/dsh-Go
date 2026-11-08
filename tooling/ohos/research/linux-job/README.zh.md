# 903：真实 Linux guest 通用作业协议

## 范围与实测

6459f947新增guest代理。真实TinyEMU 2019-12-21、Linux4.15、Alpine3.24.4/riscv64内15个连续作业、17项检查通过：python3 print(1)、gh/Git版本、rg、真实guest TCP/HTTP小仓库clone、cwd/env/argv、流式stdin和输出/取消收尾。没有宿主exec替代guest命令。真实账号gh pr list由本机验证。

不含Node生产绑定、HAP、真机、主机工作区/挂载/FID租约。opened明确workspaceLease:false，complete不能冒充829全部主机资源屏障。使用904-R2受控VM ABI，停止后仍保留owner/堆，不可重建或dlclose；908另行处理盘FILE。

## 协议与不变量

私有console用JSONL，guest输出前缀DSHG1、v=1、宿主随机32字节十六进制epoch、单调seq。job严格递增且为JS安全整数。测试镜像epoch重复01仅属fixture。payload的独立stdio pipe输出经base64包装，不直接接控制TTY/状态pipe。

start提供argv数组、绝对guest cwd和完整env；无shell文本拼接。stdin含base64 data和十进制字符串offset，只有写入任务pipe的字节才stdin-ack；stdin-end关闭。输出data含offset，host取得字节所有权后ACK through，只ACK新data，不给空流发额外ACK0；EOF含最终长度。

每流0<=sent-acked<=65536，单次读min(4096,剩余credit)。stdin待写不超过65536，控制行最多131072字节。这不是全App内存上限证明，host还须自己的sink背压和spill契约。

每任务独立PID namespace，init等待全部子孙；leader状态与全树收回分别记录。外层starter持cancel pipe；cancel或控制者死亡关闭pipe时终止namespace init，Linux回收其他进程，包括setsid子孙。payload降UID/GID60081、清附加组与capability bounding set、置no_new_privs。这是guest作业所有权机制，不代表主机文件授权已完成。

complete要求starter已waitpid、namespace结束事实成立、状态pipe EOF、stdout/stderr双EOF和全部输出ACK。cancel-requested只表示请求收妥。complete.cancelled保留请求事实，exitCode保留实际leader状态；若leader先退出再取消其子孙，host不得丢掉cancelled并标整个作业普通成功。完成后迟到取消不伪造reap失败。

非法epoch/job/offset/ACK及截断控制流fail-closed。当前fixture PID1遇协议错误退出会导致guest panic，native owner必须隔离，不能当普通可恢复任务失败继续使用。任务exec失败正常返回126/127及分离stderr。host控制者唯一可信，不能把插件任意JSON直接转发。

## 先红后绿与原始失败

基底没有此代理，不能把缺模块错误冒充行为红。开发版固定读取4096，独审指出剩1字节信用额会越界；credit-red真实收到69631个未ACK字节而失败。修订按剩余额读，同一真实guest场景最大65536并仍能取消；green-02和runner-green均17PASS。

保留两次测试工具错误：run-01给已complete任务发额外空流ACK0，触发严格协议错误；green-01仅固定等待0.35秒，子孙未真正启动，计数文件未创建。最终等待真实child-ready消息，不能把这两项称产品兼容修复。原日志均保留。

## 复跑与门登记

Linux构建机需Python3、C编译器、mke2fs、git；不把构建命令放进App。packages.lock.json固定31包版本、字节数、SHA256、URL和许可证。准备脚本不执行APK脚本；builder只展开核验后的数据成员到私有测试目录，拒绝路径越界及父目录链接。builderUid记录在BUILD；非root fixture不作为分发系统镜像。

```sh
python3 tooling/ohos/research/linux-job/prepare-inputs.py --out /tmp/903-inputs
# 可加 --alpine-mirror https://repo.huaweicloud.com/alpine，SHA仍严格相同
python3 tooling/ohos/research/tinyemu-stop/run.py --source-archive /path/tinyemu-2019-12-21.tar.gz --diskimage /tmp/903-inputs/diskimage-linux-riscv-2018-09-23.tar.gz --alpine /tmp/903-inputs/alpine-minirootfs-3.24.4-riscv64.tar.gz --output /tmp/904-run --cc cc
python3 tooling/ohos/research/linux-job/run.py --inputs /tmp/903-inputs --library /tmp/904-run/candidate/libtemu.so --output /tmp/903-run --cc cc
```

统一门linux-guest-jobs依赖tinyemu-stop-boot，新增配置linux_job_inputs；缺输入BLOCKED_NOT_RUN。本轮没跑完整门。既有core3/CLINT13/低写1由自含904门覆盖，本件作者复用该已验证冻结库。

## 基底与来源

累计补丁含904-R2 recipe（来源SHA e56305e4a3094567d88897598ff26851a860d8bb12f8936836735cbd5a2edbd0），不要叠加904。未改Android或TASK禁区。906/908是另一些累计替代包，不可盲目叠加；正式整合应保留最新原生修订并统一注册门。

主来源：TinyEMU https://bellard.org/tinyemu/ ，Linux https://kernel.org/ ，Alpine https://alpinelinux.org/ ，PID namespace语义 https://man7.org/linux/man-pages/man7/pid_namespaces.7.html 。TinyEMU MIT及slirp随源通知、Linux GPL-2.0与工具逐包许可证需保留。这里只是测试输入，没有新增HAP生产分发依赖；最终分发需owner审定。
