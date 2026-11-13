# 2026-11-10 ARTEMIS 设备无法观测调查：8ebf2029

时间均为 UTC+8。本报告记录此次任务，不能用作其他历史卡死事件的最终归因。

## 结论和当前状态

指定任务 `8ebf2029-34e1-4b07-9196-186dc8507ef5` 因设备观测失败而阻塞结束。故障时段同时存在 Android 系统窗口锁争用、严重内存/IO 压力、联通智家 ANR，以及 system 自身的输入 ANR。不能把这次事件简单归为 ADB 掉线、模型接口不可达或某次业务点击直接造成崩溃。

23:51—23:53 的复查中，原始 ADB 截图和 ARTEMIS 控件树均已可读取，但两者都显示“进程 system 没有响应”的弹窗。这只说明观测通道当前可用，不代表系统与业务已经恢复稳定。本次未关闭弹窗、主动重启模拟器/ADB/ARTEMIS、停止被测应用、清理数据、改配置或重跑任务，现场保留。

Windows 侧已按用户要求将任务、初步证据和后续定位重点直接发给 `CodexManger开发主线-1109 · WSLDL`：`01a1c4bd-d592-72c2-8f22-baed1c1db50a`，host `remote-ssh-codex-managed:WSLDL`。对方正在检查观测回退和线程收尾，尚未拿到可断言“谁发起全部窗口转储”的证据。

## 任务和版本

- 目标：将联通智家当前云回看时间定位至 2026-11-09 13:14:10，误差不超过 5 秒。
- 实际设备：`emulator-5554`，Android 15，当前 ADB `127.0.0.1:5037`。
- ARTEMIS 运行记录：2.8.4，源码提交 `8a2e8eb423751cda4d81985e20accd145bac0748`，`source_modified=true`。现场 Git 变更涉及 LLM reliability、相关测试及 DESIGN.md；未据此认定修改造成故障。
- 任务约 23:17:13 接收，23:45:02 结束。任务状态 failed；测试结论 blocked；错误码 `device_observation_failed`。
- 最终错误：`设备观测失败（已尝试 3 次）：Failed to capture screen state: 设备屏幕观测超时（60 秒）`。
- 初查和观测复查时执行队列均无活动任务。
- 模拟器 QEMU PID 66500，10:17:37 启动；ADB server PID 68004，10:02:26 启动。本次并未重启它们。

## 故障时间线

| 时间 | 实际记录 | 能说明什么 |
| --- | --- | --- |
| 23:31:25—23:31:26 | 第 7、8 个已记录动作均为 `read_control`，成功读取回看时间与日期 | 这些已记录动作是读取；不能把动作数当作点击数 |
| 23:35:54 起 | 新的 ANR 预转储；后续系统转储内部采样时间 23:36:14 | 系统异常证据早于最后一次失败的暂停按钮操作 |
| 23:36:14 的系统采样 | WindowManager 全局锁被窗口显示信息转储持有，Watchdog 和其他线程等待 | 存在系统服务锁争用；不能仅凭采样宣布已证明死锁 |
| 23:38:15 左右 | generic trace 记录模型请求 300 秒未完成，安排重试 | 同一任务另有模型请求等待问题；不是最终 device_observation_failed 的同义词 |
| 23:40:36 起 | 后续 `click`，target=13，description=播放暂停按钮，记录 failed、耗时约 204 秒 | 单条失败动作不能证明底层输入完全没有发生；不要自动重放 |
| 23:40—23:45 | helper `/snapshot?fields=xml` 超时、已安装包检查超时、多次连接 UIAutomator2，随后观测重试失败 | 错误覆盖了控件树/回退链路，不能仅凭“screen state”断言原始截图必然失败 |
| 23:45:06 | 联通智家主进程 PID 8311 的输入 ANR | 应用当时确实无响应 |
| 23:45:12—23:45:16 | system/PointerEventDispatcher 输入 ANR，事件等待 566109ms | 系统本身也受到影响，并非只有应用窗口失去响应 |
| 23:48 起 | ADB 在线；完整保存新 ANR、任务日志、logcat、内核日志及资源快照 | 保留故障时段证据；复查时点不能替代故障时点 |
| 23:51—23:53 | 原始截图 1.413 秒成功，ARTEMIS 控件树返回 system ANR 弹窗的 3 个控件 | 当前观测能力已回归，系统弹窗仍在 |

第 8 步返回的 generic_tools 还包含后续未形成成功动作步的记录；因此“8 步”不能解释为该任务仅有 8 次内部工具调用。

## Android 侧直接证据

### 窗口服务锁

文件 `anr_2026-11-10-23-45-02-045.txt` 的 Subject 为 Watchdog 等待 WindowManagerService，内部进程采样标题为 `system_server` PID 620、23:36:14。

锁 `0x0f159fcb` 是 `WindowManagerGlobalLock`。持有者为 `binder:620_17`，Java tid 202、Linux tid 1560，栈为：

```text
Class.getDeclaredField
ViewDebug.getFlagMapping / flagsToString
AppearanceRegion.toString
DisplayPolicy.dump
DisplayContent.dump
RootWindowContainer.dumpDisplayContents
WindowManagerService.doDump
  locked <0x0f159fcb>
```

同一份系统转储中有 20 处该锁等待记录、18 处 `WindowManagerService.doDump` 栈。它们是静态记录中的出现次数，不是已证实的 20 个独立请求或 18 个独立发起者。等待者包括其他 dump Binder 线程与 Watchdog。尚未追溯出发起这些请求的全部进程。

这次持锁线程的采样位置与 17:11 历史事件不同；不能直接套用之前 FastPrintWriter 的持锁栈作为本次事实。

### 应用主线程

文件 `anr_2026-11-10-23-45-06-402.txt`，应用 `com.woapp.hebei`，PID 8311，回看 Activity `com.iot.activity.phone.NHEPhoneLivePreviewActivity`：

```text
BinderProxy.transactNative
IConnectivityManager.getNetworkCapabilities
ConnectivityManager.getNetworkCapabilities
Thingclips NetworkUtil.getNetConnType / networkAvailable
Handler.dispatchMessage
```

这确认应用主线程在等待系统网络能力查询。它与窗口锁/资源压力同时出现，但尚未建立完整 Binder 因果链，不能声称窗口锁必定直接阻塞了此网络调用。

### 系统输入 ANR

文件 `anr_2026-11-10-23-45-12-393.txt` 与 logcat 对应 system PID 620 的输入无响应，PointerEventDispatcher 等待约 566 秒。现场截图和 ARTEMIS 控件树均为系统无响应弹窗。

### 故障时段资源压力

logcat 23:45:12 的联通智家 ANR 报告：

| 指标 | avg10 | avg60 | avg300 |
| --- | ---: | ---: | ---: |
| 内存 PSI some | 43.89 | 65.60 | 62.53 |
| 内存 PSI full | 18.65 | 26.11 | 24.56 |
| CPU PSI some | 65.58 | 62.73 | 60.56 |
| IO PSI some | 73.62 | 94.50 | 85.17 |
| IO PSI full | 10.18 | 15.84 | 16.33 |

同期 Load 为 `41.37 / 36.98 / 22.82`，CPU 报告 TOTAL 79%，其中 kernel 69%。当前实例配置为 4 vCPU/4 GiB；23:48 快照显示约 1.66 GiB swap 已使用。故障时段存在严重等待和换页压力，但不能据此断言某个进程存在内存泄漏。

任务 failure runtime 快照中宿主机仍有约 21.35 GiB 可用物理内存，提交额度亦有余量。因此已有证据不能解释为“整台 Windows 的物理内存耗尽”；宿主 CPU/磁盘在全时段的负载、虚拟机内存配置和来宾内部问题仍需分别排查。

## 当前边界探测

只执行一组受时限约束的只读 ADB 探测，没有重试业务：

| 探测 | 耗时 | 结果 |
| --- | ---: | --- |
| `shell echo` | 0.166s | 成功 |
| `exec-out screencap -p` | 1.413s | 成功，434809 字节 PNG |
| `dumpsys -t 3 input` | 0.292s | 成功 |
| ARTEMIS hierarchy | 返回成功 | 系统 ANR 标题、“关闭应用”、“等待”共 3 控件 |

当前 helper 为已安装版本 16、协议 3，可达；bundled 为 15，诊断标为 newer_than_bundled，不是过期。没有擅自降级或重装 helper。23:52 进程清单未发现 scrcpy/screenrecord 残留；此结论不代表整个任务期间没有录屏负载。

## ARTEMIS 侧需要继续核实/修改的点

1. 追踪窗口 dump 的实际调用者。2.8.4 的 `artemis/drivers/android/foreground.py` 仍使用 `dumpsys window displays`，已加入预算、同进程合并和子进程收尾；这些措施不能直接证明系统端 Binder dump 一定随客户端取消而停止，也不保证跨进程合并。本次任务 stdout 未检出该模块的 `Foreground query` 日志；不能凭锁栈就认定都是该 worker 发起。
2. 区分截图、XML、helper 重连和 UIAutomator2 初始化的具体失败阶段。当前错误只说“屏幕观测超时”，会掩盖原始截图仍可能可用这一情况。对方同步调查已发现 XML 请求超时和 UIAutomator2 `server not ready` 记录，待其落盘证据进一步交叉核验。
3. 保留原始超时详情：`artemis/mcp/observation.py` 112—115 行将 TimeoutError 统一改写为笼统 60 秒，会丢弃 `adb_driver.py` 223—225 行附加的 stage/detail。此为源码确认的可诊断性缺口，不是已证明的系统 ANR 根因。
4. 检查外层取消后 SDK 阻塞线程、helper 回退及 ADB 子进程的实际退出，不把外层 wait_for 到期当作所有底层工作已经结束。当前没有复现或注入终止故障。
5. 事件稳定后再做受控对照：先独立验证无业务操作的观测，再分离视频播放、录屏与内存档位；避免直接重复整条 28 分钟任务。高内存档位可作为对照，不应在没有证据时自动更改所有用户默认设置。

没有在本次调查中修改产品源代码、发布新版本或声称根因修复。

## 跨会话复核进度（2026-11-11 00:00）

指定协查会话反馈：任务 worker PID 18352 已退出，未见其直接子进程残留；超时不会立即停止底层同步调用，现有代码会复用尚未完成的观测任务。其源码调查列出三类需要追踪的窗口转储入口：ARTEMIS 前台查询、提交前锁屏检查和 adbutils.app_current()。这是已找到的调用入口，不是对 ANR 中所有窗口 dump 的逐一归属。

对方还区分了 helper XML 超时与 UIAutomator2 `server not ready`，没有把截图 1.413 秒的事后复查当成故障当时截图一定成功。该会话继续核对回退与收尾，尚未宣布产品修复或通过稳定性验收。

## 证据目录

`E:\Project\CodeProject\ArtemisOS\build\device-observation-8ebf2029-20261110-2348`

主要入口：

- `task-status.json`、`task-runtime-diagnostics.json`、`last-task-steps.json`
- `stdout.log`、`diagnose-readonly.json`、`hierarchy-probe.json`
- 上述三份 `anr_2026-11-10-23-45-*.txt`、`anr_2026-11-10-23-35-54-311_pre.txt`
- `logcat-all.txt` 含同机较早历史事件，分析时必须按本次 23:17—23:45 时间窗过滤；`anr-logcat-excerpts.txt` 也保留了前一事件，不能混用其数值
- `raw-screenshot.png`、`boundary-probes.json`、`input-state.txt`
- `guest-psi.txt`、`guest-psi-after-probes.txt`、`guest-top.txt`、`guest-meminfo.txt`
- `guest-processes.txt`、`binder-system-current.txt`、`dmesg.txt`
- `host-processes.json`、`host-memory-and-processes.json`

这份报告是当次调查与跨会话交接记录，不是一次通过的长期稳定性验收。
