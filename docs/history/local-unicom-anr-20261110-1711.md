# 本机联通智家 ANR：2026-11-10 17:11 现场

状态：已保全现场、仅重启应用恢复；根因尚未完全确认。时间均为 UTC+8。

## 结论

这次确认是联通智家直播/回看 Activity 的输入分发 ANR，不是已证实的原生崩溃。故障期间，Android 有严重内存、CPU 和 I/O 等待；应用主线程同步查询系统网络状态时阻塞，system_server 同期存在窗口管理全局锁争用。窗口状态转储还产生大量 EPIPE 错误，值得优先追查查询来源、并发和取消行为。

不能仅凭这些证据认定是内存泄漏、GPU 驱动崩溃、网络/DNS 故障或某一次自动化点击导致。也不能将窗口转储错误直接认定为最初原因：它可能是资源压力下的放大因素。

本次任务已使用 ARTEMIS 2.8.3（提交 `80c0fc64d7bb6bd6ba4d5b4982867dee912bb4f6`，运行快照标记源码未修改）。任务取消后录屏资源已释放，当前无遗留 scrcpy 编码会话；这与之前复现的异常退出遗留录屏缺陷不同。录屏运行期间的额外负载仍需对照验证。

## 环境与证据

- 工作区：`E:\Project\CodeProject\ArtemisOS`。
- ARTEMIS：`E:\Project\CodeProject\artemis`。
- 实例：`emulator-5554`，Android 15，4 vCPU、约 4 GiB 内存、720×1600；QEMU PID 66500，自 10:17:37 运行。
- 启动参数包含 `-gpu swiftshader -no-snapshot -feature -HardwareDecoder`；本次未更改渲染、内存、系统镜像或启动参数。
- 应用：`com.woapp.hebei`；现场主进程 PID 2787。
- ARTEMIS 任务：`b93f3089-2951-47bb-94ff-b17688021dc8`；状态 cancelled，设备队列 idle。调查未停止或重放该任务。
- 原始证据目录：[local-unicom-20261110-1713](E:/Project/CodeProject/ArtemisOS/build/local-unicom-20261110-1713)。目录名代表调查批次，不表示所有文件采集于同一分钟。

主要文件：

| 文件 | 用途与边界 |
| --- | --- |
| `anr_2026-11-10-17-11-44-440_pre.txt` | 系统预转储，system_server 主线程和多个 Binder 线程等待窗口锁 |
| `anr_2026-11-10-17-11-47-054.txt` | watchdog 预警及线程栈；包含不同进程，线程编号必须按 PID 区分 |
| `anr_2026-11-10-17-11-48-276.txt` | 联通智家 ANR 主线程、相关进程完整栈 |
| `logcat-current.txt` | 首次采集的 main/system/crash/events 尾部日志；不是无限期完整历史 |
| `dump-write-errors.txt` | 从该日志提取的转储写入错误，保留原始行号 |
| `media-resources.txt` | 当前资源及历史事件；两部分不能混为一谈 |
| `app-meminfo.txt`、`guest-top.txt`、`guest-psi-root.txt` | 故障后采样；不能替代 ANR 时刻指标 |
| `binder-app.txt`、`binder-system.txt`、`dmesg.txt` | Binder 与内核现场 |
| `live-sigquit-trace_01.txt` | 17:24 主动 SIGQUIT 采样；不是另一场自然发生的 ANR |
| `main-kernel-stack-current.txt` | 恢复前主线程内核等待位置 |
| `host-processes.json`、`guest-vm-zram.txt` | 宿主进程及来宾交换状态 |
| `task-runtime-diagnostics.json`、`task-recording.json` | 任务运行版本、工具及成片信息 |
| `app-recovery-started.txt`、`app-recovery-start-result.txt` | 应用恢复操作时间和启动结果 |

原始日志、线程栈及截图可能包含设备、应用和摄像头信息；本次只保存在本机。对外分享前单独审查脱敏。

## 时间线

1. 16:43:20 接收任务，约 16:43:24 开始运行。最后保存的界面操作包括回看时间轴拖动、暂停和原生控件稳定性读取；不能据此认定这些操作直接造成后续 ANR。
2. 17:03:42 已有 watchdog.monitor 等待 WindowManagerService 转储持有的锁约 2.9 秒的日志。
3. 17:03:43 起出现 `FastPrintWriter: Write failure` / `EPIPE (Broken pipe)`；17:04:12 出现预 watchdog 记录。因此 17:11 并不是首次出现系统卡顿线索的时间。
4. 17:11:43 任务取消；17:11:44 资源管理日志记录录屏进程 26062 的资源移除。
5. 17:11:45～17:11:48 系统预转储、watchdog 转储和应用 ANR 写入。联通智家 Activity 为 `com.iot.activity.phone.NHEPhoneLivePreviewActivity`，输入等待 5064ms。
6. 故障后采样时内存、I/O 压力已大幅下降；不能用此时的空闲内存否定之前发生过压力。
7. 17:23 仅点了一次 ANR 对话框“等待”；弹窗随后再次出现。
8. 17:24 主动取得主线程栈，已处于 `MessageQueue.nativePollOnce → Looper`，内核为 `do_epoll_wait`。原来阻塞的同步查询已不在主线程栈上，不能将其描述为持续到此时的死锁。
9. 17:26:44 开始仅重启联通智家，保留应用数据。新主进程 PID 8311，冷启动耗时 6646ms，进入 `MainActivity`。随后关闭启动广告。
10. 17:34:25 复核：前台为 `MainActivity`，原生界面读取到 49 个应用控件及“首页/我的”，无 ANR 弹窗、无启动广告遮挡；恢复后的所采日志未检出新 ANR、Java 致命异常或原生崩溃。QEMU 仍为 PID 66500，未重启。此项证明短时界面恢复，不代表直播或隔夜稳定性通过。

## 直接证据

### 1. 主线程等待系统服务，而非直接等待 DNS

ANR 主线程栈：

```text
BinderProxy.transactNative
IConnectivityManager$Stub$Proxy.getActiveNetwork
ConnectivityManager.getActiveNetwork
com.thingclips.smart.android.common.utils.NetworkUtil.getNetConnType
NetworkUtil.networkAvailable
...handleMessage
Looper.loop
```

这是同步 Binder 网络状态查询。栈本身不能证明外网不通，也不能沿用以前 DNS/时区登录问题的结论。

### 2. ANR 当时存在严重资源等待

`logcat-current.txt` 原始行 23155～23179：

| 指标 | 值 |
| --- | --- |
| memory PSI some avg10 / avg60 | 51.79 / 66.66 |
| memory PSI full avg10 | 24.11 |
| CPU PSI some avg10 | 60.12 |
| I/O PSI some avg10 / avg60 | 78.19 / 95.52 |
| 同期来宾总 CPU | 93%，其中 kernel 79% |
| 应用在约 10.8 秒统计窗中的 major faults | 40,892 |

PSI 是等待时间占比，不是内存使用率或磁盘容量占比。高内存等待、大量重大缺页和内核执行开销，与严重回收/换页争用一致；尚缺故障前按进程连续内存曲线，无法识别最初的分配者或证明泄漏。

17:17 宿主采样仍有约 24.8 GiB 可用内存，C/E 盘均有约 300 GB 空间；这是故障后的采样，不能排除故障高峰宿主曾出现短时负载。

### 3. 窗口转储异常和锁争用

17:11:47 系统转储中，窗口锁 `<0x0f159fcb>` 被 Java tid 193、Linux tid 1552（`binder:620_13`）持有。栈位于 `DisplayArea.dumpChildDisplayArea → WindowManagerService.doDump` 的输出路径，经 `FastPrintWriter` 进入日志输出。另有 9 处等待同一锁的记录，包括其他窗口转储及 watchdog 监视。

所采日志中有 **273 条 `Write failure` 记录**、546 条含 EPIPE 的行；提取文件总计 7156 行。异常堆栈有多行，一个转储也可能报多次写入失败，因此这些数字不是转储次数、并发数或用户点击次数。

可以确认窗口转储受阻及重复报错，尚不能确认全部请求来自 ARTEMIS、第三方诊断还是其他客户端，也没有证明网络查询与该锁之间存在完整的等待闭环。

### 4. 录屏有正常收尾证据，不能排除运行时负担

当前资源部分只有应用的 `c2.android.hevc.decoder` 客户端，无活动 scrcpy 编码客户端；历史事件显示录屏资源 17:11:44 释放。历史 PID 条目为空不等于进程仍存活。

成片为 HEVC、230×512、平均约 14.62fps、1245.378 秒、6,044,990 字节；任务生命周期约 1705 秒。不能把成片时长当作录屏进程存活时长，也不能据此断言全程持续编码或严格确定停止产帧的墙钟时刻。此处已经是低分辨率，继续建议“降到 720p”并不符合实际配置。

### 5. 自动化输入与查询的排查线索

ANR 等待事件是 `KEYCODE_UNKNOWN(0)`。当前 ARTEMIS 的 `awake_service.py` 152、291 行存在每 5 秒发送该按键的保活回退路径。这与事件类型一致，但尚未还原本次运行究竟由哪个客户端发送，不能因此认定该保活事件制造了卡死；它也可能只是暴露了已存在的阻塞。

代码中还存在窗口查询回退：

- `E:\Project\CodeProject\artemis\artemis\drivers\android\adb_driver.py:565`，尝试 `device.current_app()` 后回退到 `dumpsys window displays`。
- `E:\Project\CodeProject\artemis\artemis\controllers\platform_specific_commands_controller.py:118`，尝试同名接口后回退到完整 `dumpsys window`。
- 当前安装的 adbutils 提供 `app_current()`（`shell.py:417`），其内部本身仍会调用 `dumpsys window windows`（436 行）。必须核查对象接口及调用频率；仅改方法名不能解决重型转储和并发问题。

以上是源码线索，不是已经证明与现场某条 Binder 请求一一对应的调用链。

## 下一步验证与修复顺序

1. 优先追踪前台包名、窗口状态和保活的实际调用来源。复用现有设备入口限制重复并发查询、加入超时退避；核查取消后远端转储是否仍在执行。不要把持续启动完整 `dumpsys window` 作为健康心跳。
2. 对窗口查询/转储取消建立小规模针对性回归，不在当前用户现场反复制造大批并行转储。调整查询实现前核对当前 adbutils 接口；避免只换方法名后继续同样的转储负载。
3. 单独验证保活回退是否对当前模拟器生效，区分心跳暴露 ANR 与心跳引发阻塞。若调整策略，保留设备作用域和退出恢复，不能直接全局修改所有设备。
4. 相同 APP 场景、相同 4 GiB 配置先对比“关闭录屏 / 当前 HEVC / H.264”，按进程记录 RSS、PSS、SwapPSS、major faults 与 PSI。各组保持其他条件相近，再决定是否调整录屏默认值。
5. 如仍复现，再单独做 6～8 GiB 内存对照；这可以检验容量余量，不代表已经修复泄漏。GPU、解码器、内存不要一次同时更改。

当前没有发布安装包、修改正式代码、清除应用/AVD 数据或重启整个模拟器。短时恢复不代表隔夜或持续视频测试问题已解决。

## 解释指标时的官方依据

- [Linux PSI 文档](https://docs.kernel.org/accounting/psi.html)：some/full 与 10/60/300 秒等待比例定义。
- [Android ANR 排查文档](https://developer.android.com/topic/performance/anrs/diagnose-and-fix-anrs)：系统负载、system_server、同步 Binder 与输入超时的关系；输入分发默认超时 5 秒。以上为通用解释，具体故障结论来自本次本机证据。
