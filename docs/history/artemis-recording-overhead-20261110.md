# ARTEMIS 录屏开销与退出清理调查（2026-11-10）

## 结论

**补充实测确认：当前 Android 录屏存在两条可留下 scrcpy 和 HEVC 编码资源的异常退出路径。** 测试 worker 突然退出，或停止信号发送抛出 OSError 时，现有清理不能保证结束录屏。复用项目已有 Windows ProcessJob 的对照测试，已验证能处理前一种情况。产品代码尚未修改。

这不等于已证实 11 月 9 日触发了这些路径。当天 22:03 的 HEVC 编码负载发生于仍在执行的任务中，对应虚拟屏幕于 22:05:55 被移除；后者只能直接证明显示捕获结束，不能单凭这一条证明全部编码资源已释放。现有记录仍不能将隔夜卡顿定性为录屏残留或内存泄漏。

本报告供 ARTEMIS 开发会话 `01a1bfe6-e6bc-7bd1-a6d7-975a354da678` 后续实现和验收使用。已只读查看该会话；没有发送消息、改动 ARTEMIS 产品代码、调整运行配置或操作业务界面。

## 事实与时间线

本次核对的任务：`6d32cd97-1b10-4455-a6e4-74f2dd3e034d`。

| 本地时间（UTC+8） | 证据 |
| --- | --- |
| 11-09 21:35:55 左右 | ARTEMIS 接受并启动任务；控制接口记录 execution 约 1800.969 秒。 |
| 21:36:01.369 | Android 添加 scrcpy 虚拟屏幕，编号 5，大小 230×512。stdout 同时记录启动自动录屏。 |
| 22:03 左右 | ANR 采样出现多个 HEVC 编码线程；此时任务仍在执行。media.swcodec 的总 CPU 包含该服务的其他工作，不能全部记为录屏独占。 |
| 22:05:55.896 | Android 移除同一编号 5 的 scrcpy 虚拟屏幕。 |
| 22:05:57 左右 | 任务以 task_timeout/1800 秒结束并完成收尾；最终目录中存在 recording.mp4。 |
| 22:06:40.986 → 22:25:39.240 | 下一次录屏的编号 6 虚拟屏幕成对添加、移除，stdout 还有明确的 stopping / saved 记录。 |
| 22:27:22.713 → 22:40:51.664 | 编号 7 成对添加、移除。 |
| 22:41:25.694 → 22:41:49.630 | 编号 8 成对添加、移除。 |
| 22:43:43.737 → 22:44:47.349 | 编号 9 成对添加、移除。 |
| 11-10 10:13–10:16 | 上一轮现场检查中，ARTEMIS 空闲，Windows 无 scrcpy 进程、Android 无 scrcpy server，但模拟器仍严重卡顿。 |

超时任务 stdout 没有正常的“Stopping automated screen recording”行。不能只凭缺少这一行就认定资源泄漏，应结合设备虚拟屏幕、任务生命周期、进程和媒体文件核对。本轮已有对应虚拟屏幕移除的正向证据。

## 实际视频参数

对原始录像仅运行 ffprobe 读取元数据，没有重新编码：

- 文件：`E:\Project\CodeProject\artemis\traces\web_1794231355_6d32cd97_FAIL_2026-11-09T21-36-02\recording.mp4`。
- 编码 HEVC；230×512；平均帧率 `2657000/194217`，约 13.68 FPS。
- 封装时长 1747.953 秒；文件 25,790,781 字节，约 24.60 MiB。
- `r_frame_rate=60/1` 与虚拟屏幕的 60 Hz 字段均不能单独证明实际在录 60 FPS。
- 封装时长与任务墙钟时间口径不同，不用视频时长替代录屏进程的启动/退出时间。

因此“先把高分辨率录屏降到 720p”不适用于这段现场：它原本已经远低于 720p。应优先对比编码器和帧率，而非继续牺牲可读性。

## 源码核查

源码目录：`E:\Project\CodeProject\artemis`。当前 HEAD 为 `459d7a6`，版本 2.8.2。事故任务的 runtime_diagnostics 记载 2.8.1、基准提交 `cdeda7d`、source_modified=true；不能把其未提交状态完整还原为当前 HEAD。两个提交之间下列三份核心录屏文件无已提交差异。

| 文件与入口 | 已确认的行为 |
| --- | --- |
| `artemis/controllers/unified_controller.py:687` | 明确选择 h265，或 auto 且 hevc_playback=true 时使用 h265；否则 h264。浏览器播放能力没有证明 Android 端有低开销的编码器。 |
| `artemis/config/agent.py:837` | 归档录像独立配置，默认 auto、长边 1280、15 FPS；模型观察截图有独立配置。这些是当前源码默认值，不是对事故任务配置的反推。 |
| `artemis/sdk/agent.py:703`、`:736`、`:928` | 暂停、进入最终只读评审以及 finally 都有停止录屏路径；finally 用 shield 防止一次取消打断清理，并提供取消后的等待。 |
| `artemis/controllers/unified_controller.py:575` | 同一录屏持续运行，旋转、录制满 1800 秒或录制进程崩溃时轮换分段；不是每次点击或截图重新启动录屏。 |
| `artemis/controllers/unified_controller.py:100` | 停止 scrcpy 时先发信号并等 8 秒，再在超时/进程查找错误时 terminate 并等 5 秒。 |
| `artemis/utils/video.py:330` | 正常封装先 `-c copy`；直接封装无效时才回退到宿主 ffmpeg/libx264 转码。 |

scrcpy 在 Android 端编码，在 Windows 端封装。因此 HEVC 软件编码消耗的是模拟器客体 CPU；宿主安装 NVENC 或更换模拟器图形后端，不会自动把这个编码器变成宿主 GPU 编码。

本机 PATH 中 scrcpy 为 4.1。它的帮助明确说明 `--no-window` 隐含 `--no-video-playback`，现有命令还含 `--no-audio`。不要把“再添加 --no-playback”当作已证实的性能修复，也不要由 PATH 版本反推事故 worker 必然用了同一可执行文件。

### 待加固的异常退出路径（源码风险，尚未证明本次发生）

1. `_stop_scrcpy` 没有将信号发送的普通 OSError 纳入 terminate 回退；第二次等待超时也没有最终 kill 的兜底。
2. `stop_video_recording` 捕获停止异常后可以继续封装、移除活动会话记录；“媒体文件可用”不等于“录制进程已确认退出”。
3. Android 的 `_spawn_scrcpy` 没有直接使用现有 `ProcessJob`；项目中的桌面/插件子进程已有该所有权机制。应评估复用，使 worker 异常退出时也能回收其所有录制子进程，避免新建另一套全局进程管理。

初轮只由源码列出这些容错缺口；补充实测已复现 worker 强退、信号发送报错这两条相关异常路径，结果见下节。它们仍不是昨晚已经触发同一故障的证明。清理只能针对任务拥有、PID 与创建时间可核验的进程，不能全局 kill scrcpy 或影响 ADB 主服务。

## 补充实测：正常退出、异常退出与所有权对照

采集目录：`E:\Project\CodeProject\ArtemisOS\build\scrcpy-audit-20261110`。使用 ARTEMIS 现有 `DeviceExecutionLock` 串行取得空闲设备租约；测试进程以与后台 worker 一致的 `CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW` 运行，调用产品自身的 `_spawn_scrcpy`、首帧确认和 `_stop_scrcpy`。仅添加 `STARTUPINFO/SW_HIDE` 隐藏新控制台窗口，不改变产品进程组标志。

真实录屏统一使用当前 scrcpy 4.1、长边 512、10 FPS、750 Kbps，不操作 APP 页面。正常路径分别测 H.265 和 H.264；异常路径显式注入故障。

| 测试 | 产品停止/worker 退出后的状态 | 测试收尾 |
| --- | --- | --- |
| 无控制台普通停止，H.265 | client 返回码 0；约 5 ms 返回；约 1 秒后 Android server 及当前编码器资源均消失。media.swcodec 线程数 14 → 25 → 14。 | 不需要强杀；有 Recording complete，MKV 非空。 |
| 无控制台普通停止，H.264 | client 返回码 0；约 6 ms 返回；Android server 及当前编码器资源消失。服务线程数 14 → 15 → 15，新增的是 HwBinder 线程；不能据此认定泄漏。 | 不需要强杀；有 Recording complete，MKV 非空。 |
| **故意让测试 worker 调用 os._exit(73)** | **client PID 70496 继续存活；Android server PID 6504 及 c2.android.hevc.encoder 当前资源仍存在。** | 外层测试持有租约，按 PID、创建时间和可执行路径核对后结束自己创建的 client，随后 server 和编码资源消失。 |
| **故意让 process.send_signal 抛出 ctypes.WinError(6)** | **产品停止函数抛出 OSError；client PID 41380 继续存活，Android server PID 6611 及 HEVC 编码资源仍存在。** | 测试 finally 结束自己的 client；之后 server 和编码资源消失。 |
| **同一 worker 强退，但测试先复用 CaptureProcessJob.assign(client.pid)** | **worker 同样以 73 退出，client PID 15444 已自动结束，Android server 和 HEVC 当前资源均消失。** | 无需外层强杀。只验证现有所有权机制，尚未接入产品。 |

另做了不接触设备的普通/大量 stderr 输出子进程测试。无控制台本身没有导致停止失败，不能把该环境一概定性为不兼容。大量输出时 stderr reader 确实暂停读取，但本次子进程仍能被信号结束；不能把这一结果写成已经复现生产录制死锁。

### 测量口径与证据限制

- 主要证据是 client 的真实存活状态、Android server 完整命令行，以及 `dumpsys media.resource_manager` **Processes 当前资源段**。Events logs 和 Peak Usage 是历史，不能当成编码器仍活动。
- 第一版采集脚本的 `encoder_threads` 字段错误使用 ps 的 NAME（进程名）来匹配线程名，录制中也会返回空；`dumpsys meminfo media.swcodec` 按名称查询未找到进程，所以 PSS 返回 null。不得引用这些字段证明没有编码线程或内存泄漏。
- 线程数结论由原始 ps 快照中同一 media.swcodec PID 485 的行数取得。补充的 COMM 查询显示收尾后保留的是 Binder/HwBinder 线程。按数字 PID 查询可取得 PSS，但本轮没有有效的连续 PSS 曲线。
- 故障是显式注入的，用于证明清理缺陷和验证防护机制；不是声称自然运行已经发生了 WinError(6) 或 worker 原生崩溃。
- 这轮为重启后的短时录屏生命周期验证，未覆盖视频直播负载、连续多小时录制、所有取消/超时入口、方向切换或长时内存增长。
- 所有测试 recorder 的 client/server 均已清理，设备租约已释放，ARTEMIS 队列再次确认为 idle。没有清应用数据、换镜像、重启模拟器或改保存的录屏/渲染配置。

### 原始复现文件

- `probe_stop.py`、`headless-stop-result.json`：不接触设备的 Windows 无控制台停止测试。
- `probe_real_recording.py`、`real-recording-result.json`、`h265-*-resources.txt`、`h264-*-resources.txt`：正常录屏及 Android 当前媒体资源。
- `probe_abnormal_exit.py`、`abnormal-exit-result.json`、`abrupt-after-worker-exit-resources.txt`、`signal-failure-after-source-stop-resources.txt`：两条真实异常录屏残留。
- `owned-exit-result.json`、`abrupt-owned-after-worker-exit-resources.txt`：复用现有 ProcessJob 的对照结果。

## 最近提交与实际 scrcpy 版本对照

| 追溯对象 | 核查结果 |
| --- | --- |
| 11-07 `c5cfeca` | 共享录屏命令新增 `--no-clipboard-autosync`；没有改编码选择、分段和退出逻辑。不能仅据更新时间把残留归给此参数。 |
| 11-06 `d411a7e` | video.py 主要改 FFmpeg/FFprobe 的统一定位，移除 imageio_ffmpeg 回退；未改变 Android 的 `_stop_scrcpy`。 |
| `_stop_scrcpy` 的信号及等待逻辑 | git blame 追溯至 08-22 `474e56ef`，是既有逻辑。 |
| auto + hevc_playback 选择 H.265 | 追溯至 10-16 `ef7af998`，并非这两天新加。 |
| worker 无控制台标志 | 追溯至 09-02 `67248c88`，不是本轮新引入。实测普通停止通过。 |
| scrcpy 程序本体 | 11-05 14:48:32 至 11-10 04:54:44 的 29 份可用 runtime_diagnostics 都是 4.1，exe SHA256 相同；当前实际 exe 的一次读取也吻合：`575ca1284345c7b3975585bc61b66d564a9a4f1ecb28fbb4c599c92a124054a9`。源码下载预设至少从 09-22 起即为 4.1。 |

因此能确认“最近修改过录屏相关封装”，也能确认“当前代码有可复现的异常清理缺陷”；尚无证据证明二者存在新引入缺陷的因果关系。事故任务标有 source_modified=true，不能仅靠当前提交重建所有当时未提交修改。

## 建议实施顺序

1. **先做可控的 H.264 对照。** 显式 h264，长边先保持事故现场的 512，帧率先试 10 FPS。不要同时改虚拟机 RAM、渲染器、镜像或摄像头清晰度。H.264 是否更省 CPU 由同一负载实测，不保证仅切换编码就解决崩溃。
2. **改进 auto。** 将设备端实际编码器、软件/硬件属性和必要的短时能力探测纳入选择；浏览器 HEVC 播放能力只作播放兼容性判断。保留用户显式 h264/h265 的选择，不把“所有模拟器都无法硬件编码”写死。
3. **优先修复已复现的停止与所有权缺陷。** 复用 `artemis/plugins/recording_process.py` 的现有 ProcessJob，处理创建失败、启动取消、分段替换和关闭句柄，验证 worker 强退时的自动回收。停止信号抛 OSError 时也进入有界终止回退，确认 client 退出和设备端当前编码资源释放后再清理活动会话。Windows 的 kill/terminate 是同一底层终止机制，不能靠重复 kill 解决未排空管道。正常路径仍优先写完容器；损坏媒体恢复与停止失败分别报告。确保共享 ADB server 不被纳入录制进程的所有权清理。
4. **沿用现有暂停/只读评审停录机制。** 验证取消、30 分钟超时、模型长等待和异常 worker 退出的实际行为，不重复实现已经存在的 finally。等待模型仍可能需要记录应用状态变化，不要未经产品选择就自动停掉所有等待期录像。
5. **可选后续方向。** 评估通过现有 Windows 窗口捕获链路录制模拟器窗口，并利用宿主硬件编码，减少客体编码负担。它是另一路录制方案，需验证最小化、遮挡、多实例窗口归属、帧时间与用户无 GPU 时的回退，不能直接把 scrcpy 编码器名称改成 NVENC。

帧率建议只影响归档视频；保持 AI 观察截图、关键步骤截图和原始操作坐标的质量。视频断言任务另行保留足够帧率，不用低帧率归档替代运动/卡顿测量。

## 验收条件

- 固定应用版本、同一视频/回看片段、分辨率、网络、镜像与资源配置，对比无录屏、H.264、HEVC。每轮保持相同起始状态并重复，避免同时改帧率后把全部收益算给编码器。
- 分别记录 guest media.swcodec、应用 PSS/SwapPss、MemAvailable、CPU/memory PSI、宿主 QEMU CPU/private bytes；记录 encoder 名称、参数和 client/server 生命周期。
- 正常完成、手动取消、任务超时、worker 强制退出后，验证所属 scrcpy/client/server/虚拟屏幕消失、文件不再增长，且能再次开始录屏，不触发重复编码。
- 用有界循环检查每次收尾后的资源基线；区分短时编码/缓冲峰值、系统缓存与持续单调增长。仅有一次内存快照不能证明泄漏。
- 录屏变轻后，仍须单独验证长时间运行退化；今天无录屏时的隔夜卡顿不可直接标记为已修复。

## 本轮验证与来源

- 已用 ARTEMIS `mobile_manage_task(status)` 只读确认超时状态及 lifecycle；已核对本地 stdout、Android 历史 logcat、ffprobe 输出、当前源码和已提交差异。
- 初轮为只读取证；补充调查进行了上述短录屏、故障注入及 ProcessJob 对照。未发送验证码、回放业务动作、重启模拟器、改保存的配置、修改 ARTEMIS 产品代码或发布程序。
- 尝试运行两份现有录屏单元测试，项目 `.venv` 报 `No module named pytest`，没有执行任何测试用例；未为本轮只读调查安装依赖，不能引用开发会话历史测试数量作为本轮通过结果。
- [scrcpy 官方录屏说明](https://github.com/Genymobile/scrcpy/blob/master/doc/recording.md)：设备端编码、客户端封装及无播放录制。
- [scrcpy 官方视频说明](https://github.com/Genymobile/scrcpy/blob/master/doc/video.md)：尺寸/帧率限制、可变帧率与编码器选择。master 文档能力须对照实际 scrcpy 版本。
- [Microsoft Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects)：进程组所有权与子进程管理。
- 本机日志：`E:\Project\CodeProject\ArtemisOS\build\local-unicom-20261110-cb2af1ef\logcat.txt`，关键行 11705、45770、46074、48801、49044、50927、51088、51125、51373、51543。此前结论见同目录 `user-logs-review-20261110.md`，本报告补充录屏生命周期和真实录像参数。
