# ArtemisOS 内存故障采集

这个工具仅在本机采集 ArtemisOS 的 QEMU 进程与 Windows 内存指标：不改变模拟器配置、不重启、不读取应用数据、不截图、不采集 Android 日志或内存转储。默认每 30 秒采样一次，持续 8 小时；窗口提前关闭也会保留已经写入的结果。无需管理员权限，需 Windows 自带的 Windows PowerShell 和 WMI/CIM 可用。

1. 解压整个压缩包，双击 `start-diagnostics.cmd`，保持弹出的窗口打开。
2. 正常启动或继续使用 ArtemisOS，按原来的方式执行测试。在便签中记录**大致时间**和操作，例如开始直播、切换页面、黑屏、卡死及结束直播；不需要记录账号、手机号、验证码或摄像头地址。
3. 如果故障再次出现，先记录时间；如果系统提交内存剩余已经很少或电脑明显卡顿，停止测试并在保存现场后正常关闭模拟器，避免影响整台电脑。该工具**只提示，不会自动终止模拟器**。
4. 采集结束后按 `Ctrl+C` 或关闭窗口；将桌面上 `ArtemisOS-Diagnostics-日期-随机数` 文件夹压缩后发给负责分析的人。文件逐次保存，模拟器退出后依然保留。`host.json` 包含 Windows 版本、显卡名称和驱动版本；`sessions.jsonl` 包含识别出的模拟器版本、启动图形参数和虚拟硬件配置；`memory.csv` 包含带时间的内存、CPU、进程 ID 和线程/句柄数。

请同时提供 Artemis 测试日志中覆盖故障时间的片段、测试流程和发生故障的应用名称；发送前检查并遮盖个人信息、账号、验证码、令牌、IP、摄像头地址等敏感内容。若日志包含截图或录屏，先确认画面适合分享。**不要发送完整内存转储**；它可能非常大且含敏感数据。

## 数据说明

- `private_commit_bytes` 是 QEMU 进程私有提交内存；`working_set_bytes` 是进程工作集；不能将两者相加，也不等同于虚拟机配置内存。
- `host_commit_remaining_bytes` 是 Windows 系统提交上限减去当前提交量，不等同于空闲物理内存。少于 2 GiB 的提示是方便用户尽早检查的经验提醒，不是故障判定标准。
- `graphics_requested` 是启动参数。若为 `auto` 或 `software`，它本身不能说明最终实际选用了哪种渲染器，需要结合启动日志确认。
- `sessions.jsonl` 的 AVD 配置是在首次发现进程时读取的当前配置文件，若有人运行期间修改配置文件，它不一定代表启动时的配置。
- 自动识别 `ArtemisOS_15` 和旧名称 `InternalAndroid15`。若采集窗口一直显示 `no_matching_process`，请提供窗口中的提示给排查人员；可能是模拟器未启动、AVD 名称不同或进程信息不可访问。
- 数据只能说明变化趋势和时间相关性，不能单靠峰值确认泄漏及归属。即使本机正常，也不能代替故障电脑、相同负载下的长时间对照。

排查人员可通过 PowerShell 传入 `-IntervalSeconds`、`-DurationSeconds`、`-OutputRoot`，或用 `-ProcessId` 指定已确认的 QEMU 进程。指定 PID 时还会固定第一次看到的进程启动时间，防止 PID 被系统复用后误采其他进程；模拟器重启后要重新指定 PID。示例：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Collect-ArtemisMemory.ps1 -IntervalSeconds 30 -DurationSeconds 28800
```
