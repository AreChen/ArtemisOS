# 2026-11-10 用户证据包与本机隔夜卡顿调查

## 结论与边界

- 尚无证据证明某个错误点击、快速连续点击或直播业务动作直接造成这次故障。
- 用户证据包明确记录了两次联通智家 ANR，以及随后独立的系统看门狗事件：`android.fg` 卡在 `GnssNative.native_stop`，`system_server` 被终止并重新启动。GNSS 调用为何无法返回尚未确定。
- 本机昨晚即使使用 4 核 / 4096 MB，也出现多次 `LOW_MEMORY` 退出和 ANR；今天卡顿现场则主要表现为 CPU 调度、I/O 等待和中断开销，采样时内存仍有余量。
- 自动化录屏可能增加负载。已有 HEVC 软件**编码器**繁忙的直接证据，但尚未通过同负载对照确认它是否为必要触发条件。不能把编码器记录写成摄像头视频解码器故障。
- 本次只采证、恢复运行并作短时对照，没有修改产品代码、默认配置、用户数据或发布 OTA，也没有完成隔夜稳定性验证。

## 两套环境必须分开

| 项目 | 用户证据包 | 本机现场 |
| --- | --- | --- |
| 安装版本 | 包内说明为 ArtemisOS 1.0.2；启动日志确认 Emulator 37.3.6.0，build 16696583 | ArtemisOS 1.0.3，Emulator 37.3.6 |
| 安装路径 | `D:\ArtemisOS15-Release` | `E:\ArtemisOS15` |
| GPU | 启动日志明确为 SwiftShader | 进程参数与 preferences 明确为 SwiftShader |
| 虚拟 CPU / RAM | 不能仅凭本机配置推断；本包未取得完整 AVD 配置 | 4 核 / 4096 MB |
| 本轮系统启动 | 模拟器日志从 11 月 9 日 19:18 开始 | 旧 QEMU 进程创建于 11 月 9 日 20:19:51 |
| 主要故障 | APP ANR，随后 GNSS 阻塞触发系统服务重启 | 昨晚内存压力；今天隔夜后持续卡顿 |

两边都叫 `emulator-5554`，并不表示是同一实例。所有下述时间为 UTC+8。

## 用户 ZIP：故障和自动化实际动作

输入：`G:\Download\ArtemisOS-fault-evidence-20261110-095950.zip`。
只读解压目录：`build/user-evidence-20261110-2b316dfc/`。
任务 trace：`9044d710-e9dc-4208-9f3b-681f3d66c4de`。

| 时间 | 已确认事件 | 直接证据 |
| --- | --- | --- |
| 09:46:27.714 | 任务运行诊断采样：宿主物理可用内存约 1.34 GiB | `failed-artemis-trace/runtime_diagnostics.json` 的 start.memory |
| 09:46:39.446 | 联通智家 PID 20627 首次 ANR：无焦点窗口 | `capture-20261110/android-logcat.txt:55660` |
| 09:46:40.249 | 本轮 scrcpy 虚拟屏建立，576×1280 | 同上 `:55747` |
| 09:46:51 左右 | `manage_app launch`；回执接受前台 task，即使 focused window 为 None | `failed-artemis-trace/stdout.log:194` 起 |
| 09:47:01 左右 | 第一次点击系统 ANR 对话框“等待”，实际 `input tap 360 902` | 同上 `:225`、`:228` |
| 09:47:15.584 | 同一 PID 再次出现无焦点窗口 ANR | `android-logcat.txt:56186` |
| 09:47:43.685 | 保存第一次故障截图 | trace 的 screenshot 回执和 notes/output.md |
| 09:47:47 左右 | 第二次点击“等待”；仍只有一次实际 tap | `stdout.log:354`、`:363` |
| 09:47:53 左右 | 请求关闭推广弹窗；没有对应 ADB tap，任务记录目标已不可见 | 同上 `:384` 起，以及结果说明 |
| 09:48:08.072 | 保存第二次故障截图 | trace 的 screenshot 回执和 notes/output.md |
| 09:48:24.045 | 失败诊断采样：宿主物理可用内存约 474 MiB | runtime_diagnostics.json 的 failure.memory |
| 09:49:08.638 | Watchdog 记录 android.fg 已阻塞 71 秒 | `android-logcat.txt:56996` |
| 09:49:17.679 | Watchdog 终止 system_server，打印 GNSS stop 调用栈 | 同上 `:57051` 起 |
| 09:49:24 起 | Zygote / Android 系统服务重新启动 | 同上 `:57080` 起 |

日志中启动流程和录屏都早于首个可执行业务步骤。两个实际 tap 均发生在首个 ANR **之后**。没有进入摄像头直播、回看、通话或云台页面的执行证据。

`StepMemoryService Retrying Step ...` 对应步骤摘要调用的 HTTP 400：模型不支持 `temperature`。这不是同一个点击被执行四次；应以 `Executing Flash tool` 和实际 `[ADB] input tap` 对照判断。该模型配置错误应另行修正，不能当成 Android 原生崩溃栈。

启动回执在 focused window 为 None 时仍认定 ready，说明自动化的就绪判断值得加强；它不能证明窗口已经响应，也不能证明就是该判断造成了最初 ANR。

### GNSS 已确认到哪一层

看门狗栈为：

```text
GnssNative.native_stop
GnssNative$GnssHal.stop
GnssNative.stop
GnssLocationProvider.stopNavigating
GnssLocationProvider.updateRequirements
GnssLocationProvider.onSetRequest
... android.fg HandlerThread
```

已确认系统线程卡在停止定位的调用路径。包内没有成功取得 `/data/anr` 的完整看门狗栈，也没有 GNSS HAL 的 native 线程现场；无法区分 HAL 死锁、回调阻塞、设备通道问题等具体原因。现有自动化动作中没有设置位置或切换 GPS 的记录。不能把首次 APP ANR、后续 GNSS 看门狗、历史图形故障合并成一个已证实根因。

本包 Windows Application 事件最新为 11 月 7 日；选取的 System 资源事件最新为 11 月 5 日。它们不能证明 11 月 10 日发生了同一宿主 QEMU 崩溃。任务前后宿主可用内存下降是压力信号，两个点不足以证明泄漏。

## 本机：昨晚与当前卡顿

取证目录：`build/local-unicom-20261110-cb2af1ef/`。

### 11 月 9 日 22:03–22:05

- `exit-info-unicom.txt` 记录主进程和多个辅助进程反复以 `LOW_MEMORY` 退出，包括 22:03:23、22:03:46、22:03:58、22:05:08 的主进程记录。
- 22:03:46 的 ANR 为无焦点窗口。内存 PSI some avg10=34.00，CPU PSI some avg10=75.46，I/O PSI some avg10=41.93；这不是空闲健康状态。
- ANR CPU 采样中 `media.swcodec` 为 50%，短窗口可见多个 `id.hevc.encoder` 线程；`kswapd0` 同时繁忙。这里的百分比按日志自身口径引用，不直接当作四核整机利用率。
- 完整 ANR 已通过 `adb shell su 0 cat` 保存到 `anr-20261109-220336.txt`，未重启 adbd。主线程为 Runnable，在 ART 类校验 / 初始化、Fragment 页面构建路径中；不能据此写成已定位的互斥锁死锁或 OpenGL 崩溃。

### 11 月 10 日 10:13–10:16 卡顿现场

- 原 QEMU PID 73756 运行约 14 小时，启动参数仍是 SwiftShader、4 核 / 4 GB；硬件视频解码兼容开关未改变。
- ARTEMIS 队列 idle，设备 is_busy=false；Windows 未发现 scrcpy 进程，Android ps 也未发现 scrcpy server。因此正在发生的持续卡顿不能直接解释为 AI 此刻连续操作或录屏。
- 客体 MemAvailable 约 1.7 GiB；宿主空闲物理内存约 27 GiB。QEMU private bytes 约 6.8 GiB，仅有当前采样，不能认定泄漏。
- `/proc/pressure/cpu` some avg10=55.60、avg60=60.99；memory some avg10=0.08。PSI 表示等待压力，**不是 CPU 使用率**。
- 两秒 top 采样仍见较高中断时间（四核总量 400% 中 irq 约 163%）和 I/O 等待。中断计数、dmesg、宿主线程 CPU 采样均已保存；没有足够证据将其定性为某个 WHPX / 内核中断风暴缺陷。
- 当前移动爱家和联通智家均有进程；今天这个现场与昨晚单次 ANR 的负载条件不同。

### 原配置重启对照

确认队列空闲并保存现场后，使用 `adb emu kill` 正常结束旧实例，经已安装的 `start-software.vbs` 启动同一 AVD。没有清数据、换镜像、改渲染后端、提高内存或改变分辨率。

- 新 QEMU PID 66500，创建于 10:17:37。
- 10:18 已确认 `sys.boot_completed=1`。
- 10:19:04，启动约 82 秒后的空闲采样：CPU PSI some avg10=0.40；I/O some avg10=0.32；top 中 irq 回落至接近零，客体 MemAvailable 约 2.5 GiB。
- 该对照同时清除了应用运行现场，负载并不完全相同。它证明重启后当时的系统压力大幅回落，不能证明长期运行故障已经修复，更不能单独证明运行时泄漏。

联通智家随后仅作一次启动检查，未进入直播业务：`am start -W` 返回 `Status: ok`，冷启动耗时约 5.64 秒。启动时 CPU PSI 一度上升至 19.49；约启动 235 秒时再采样，CPU PSI some avg10=2.99，memory 与 I/O 的 some avg10 均为 0。新进程 PID 2787 存活；本次重启后采集的 main/system/events/crash 日志中，没有匹配到新的联通智家 ANR、Watchdog、Fatal signal 或 FATAL EXCEPTION。preferences 与重启前逐字一致。

这些是短时启动与日志检查，未验证直播负载、所有界面交互或长时运行。原始记录见同目录 `after-restart-unicom-launch.txt`、`after-unicom-launch-pressure.txt`、`after-restart-logcat.txt`、`final-pressure.txt`。

## 下一轮验证与修复顺序

1. 优先取得复现当时的 GNSS HAL / system_server 完整栈，单独排查 GNSS stop 阻塞。不要用禁止全部定位或替换不匹配的 vendor 文件直接当正式修复。
2. 固定同一镜像、后端、CPU/RAM、应用版本与清晰度，比较：手动无录屏、自动化无录屏、自动化现有录屏、自动化低负载 H.264 录屏。记录启动/停止录屏时间、PSS/SwapPss、PSI、编码器、ANR、退出原因和宿主 private bytes。轮次之间保持相同初始状态，并重复验证。
3. 录屏对照可试 H.264，并在任务退出时核对 client/server 和当前编码资源均已释放。该次录像只有 230×512、平均约 13.68 FPS，不再优先建议进一步降分辨率。22:05:55 虚拟屏幕移除本身不能证明全部编码资源已清理。11 月 10 日的显式故障注入已复现 worker 强退或停止信号报错后 scrcpy/HEVC 仍运行，现有 ProcessJob 对照可处理前一种残留，但未证实昨晚触发同一路径；产品代码尚未修改。完整时间线、复现证据及开发修复点见 [录屏开销补充调查](artemis-recording-overhead-20261110.md)。
4. 自动化遇到重复 ANR 后应保留现场并结束本轮，避免一直“等待—重新启动—继续业务”；启动 ready 应结合真实焦点及可交互窗口。步骤摘要 API 参数错误与 Android 故障分开处理。
5. 增加固定工作负载的长时运行采样后，才判断是否存在单调内存增长、录屏资源残留或仅长时间运行后出现的调度退化。一次重启和一次短时成功不能作为正式发布验收。

参考：[scrcpy 维护者视频参数文档](https://github.com/Genymobile/scrcpy/blob/master/doc/video.md)说明了分辨率、帧率、编码器的调整方式，以及 H.264 与 H.265 的延迟取舍。具体参数必须按所用 scrcpy 版本核对。

原始日志可能含账号信息、设备信息和网络地址；本报告只保留诊断所需字段，原始目录不直接作为公开分发材料。
