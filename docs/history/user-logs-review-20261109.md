# 用户故障证据包复核（2026-11-09）

## 范围

来源：`G:\Download\artemis_problem_logs_20261109_101220_final2.zip`。这是不同日期、不同测试批次的混合证据；压缩包生成于 11 月 9 日，不意味着其中所有事件发生于 11 月 9 日。未在用户电脑上复现或修改用户数据。

## 已确认与未确认

1. **Android system 无响应截图**：截图标题为 ArtemisOS 15 v1.0.2，Android 弹出“进程 system 没有响应”。压缩包中该图片的文件时间是 11 月 9 日 09:40:26（UTC+8）；文件时间不能独立证明 ANR 的发生时间。截图不能证明 Windows 中 QEMU 已退出，也不能确定 system 无响应的原因。包内没有该截图时刻对应的 Android ANR 堆栈、logcat、QEMU 日志或 Windows 崩溃转储。
2. **11 月 7 日模拟器进程崩溃**：00:54:27 左右，Windows Application Error 报告 QEMU 的故障模块为 `lib64\gles_swiftshader\libGLESv2.dll`；WER 文件独立记录同一进程、模块和异常偏移 `0x15b05d`，异常代码 `0xc0000409`，P9 为 `7`。WER 的文件时间字段约为 00:54:28。SwiftShader 路径是本次崩溃的直接定位线索，但未有故障电脑的 DLL 哈希、转储或调用栈，无法确定触发原因。截图与此事件没有证据证明属于同一次故障。
3. **关联的测试中断**：崩溃前移动爱家两次出现无响应提示，之后设备详情页点击唤醒，约 12 秒后模拟器崩溃；其后 ARTEMIS 日志显示设备不再被 ADB 列出，截图重试 3 次失败，测试结果为 `blocked`。时间顺序支持模拟器退出造成设备失联，但不证明先前 ANR 或唤醒操作是崩溃根因。
4. **该次内存样本**：崩溃前约 1 分 56 秒，Windows 物理内存总量 15.38 GiB、可用 1.28 GiB；系统提交量 30.86 / 40.38 GiB。存在内存压力，但不能由此断定崩溃瞬间提交耗尽或泄漏。崩溃后可用内存变化也不能全部归因于 QEMU。
5. **另一次 11 月 5 日事件**：该日 05:48 的 Windows 资源耗尽事件显示提交量 38.388 / 38.548 GiB，余量约 163 MiB；QEMU 提交约 9.352 GiB。约两分钟后，scrcpy 目录中的 ADB 崩溃并出现设备离线。资源压力与 ADB 异常各有证据，但缺少调用栈，不能断言两者唯一因果。该事件不能当作 11 月 7 日崩溃时的实时数据。
6. **版本边界**：截图中的 v1.0.2 是 ArtemisOS 产品版本，不是 Emulator 运行时版本。仓库历史显示 1.0.2→1.0.3 仅更新配置与版本文件，未替换模拟器运行时或镜像，因此不能宣称升到 1.0.3 就修复了此故障。

此前对 11 月 7 日报告和本地 DLL 的条件性分析见 [user-swiftshader-crash-20261107.md](user-swiftshader-crash-20261107.md)。本次包中的 WER 提供了故障签名和加载模块路径，但没有增加用户端 DLL 哈希或转储，因此仍不能把本地 DLL 的反汇编结果直接认定为用户端事实。

## 建议的最小排查顺序

1. 在用户机器正常测试时启动 [内存诊断工具](../../build/ArtemisOS-Memory-Diagnostics-20261103.zip)，从模拟器启动开始连续记录；此工具采集 QEMU 和 Windows 内存、CPU、启动参数等，不采集 Android 日志或转储。
2. 若工作场景允许，在任务间隙关闭模拟器，配置中将图形渲染从 SwiftShader 改为“硬件加速”，其余内存、分辨率和视频兼容设置保持不变；使用普通启动快捷方式，而不是会强制 SwiftShader 的“软件渲染”快捷方式。按相同设备、应用和测试步骤对照，记录实际启动参数和故障时间。硬件模式依赖显卡及驱动，不保证规避故障。如果出现画面异常或启动失败，可恢复原设置，再单独试 `swangle`，不能同时改变多个条件后归因。
3. 出现 Android ANR 时，若原 ADB 连接仍正常，尽快保存包含 main、system、events、crash 缓冲区的 logcat 和相应 ANR 信息；必要时由用户侧保存 bugreport。日志可能包含个人信息，发送前需检查。若设备已离线则如实记录，不能把空日志当成没有 ANR。
4. 出现 Windows 进程崩溃时，保留同期 WER、完整 Emulator 日志、实际启动命令、版本和故障 DLL SHA-256；如需调用栈，在用户侧采集并分析匹配的转储，注意转储可能含敏感数据。此证据包没有这些信息。
5. 16 GB 物理内存的现场曾发生明显提交压力；不要未经对照直接增大虚拟机内存。系统页面文件应有足够空间并监测提交余量；调整它只能改善余量，不能证明或修复图形崩溃与潜在泄漏。

2026-11-09 在开发机上核对诊断工具压缩包内三个文件与仓库版本哈希一致，并运行 `tests/diagnostic-memory-selftest.ps1`，通过虚拟进程识别、采样、退出检测和提交余量计算测试。该自测不等于已在用户现场验证，也不采集 Android ANR 日志。

参考：[Android 模拟器图形后端](https://developer.android.com/studio/run/emulator-acceleration)、[Android ANR 排查](https://developer.android.com/topic/performance/issues/anr)、[Microsoft 快速终止机制](https://learn.microsoft.com/en-us/cpp/intrinsics/fastfail?view=msvc-170)。
