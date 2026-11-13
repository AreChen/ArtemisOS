# 本机联通智家异常调查：2026-11-09

时间均为 UTC+8。原始证据保存在本机 `build/local-unicom-incident-20261109-173752-b58575/`，包含应用日志和 ANR 堆栈，可能含敏感数据；对外分享前必须脱敏。

## 故障现场

- ArtemisOS 1.0.3，Android 15；联通智家 `com.woapp.hebei` 8.3.4，ARM64 原生库。模拟器为 2 核、2560 MB、720×1600，使用 `-gpu swiftshader`，启动参数包含 `-feature -HardwareDecoder`。
- 17:35:19，Android 低内存管理器终止应用主进程 PID 14415。该进程随后重新启动。
- 17:35:34，新主进程 PID 28256 发生输入分发超时 ANR。堆栈采集时，主线程调用路径经过 `IWindowSession.relayout`；单凭这份栈不能断定窗口服务或应用代码是根因。
- 17:35:37，应用的 `ANRHandler` 进程 PID 28988 发生 `SIGABRT`。日志记录 `fdsan` 文件描述符所有权异常；主机侧栈涉及 `libndk_translation.so`，ARM64 侧栈涉及 `libcrashsdk.so`。该 PID 与主进程 PID 28256 不同，异常发生在 ANR 之后，不能据此认定是 ANR 或主进程退出的原因。
- 17:35:36 和 17:35:58，Android 低内存管理器先后回收应用的 pushservice 和 remote 子进程。17:36:16 回收主进程 PID 28256，记录 `device is low on swap` 和 `thrashing`；17:36:17 的 `ApplicationExitInfo` 确认退出原因是 `LOW_MEMORY`。退出时记录的主进程 RSS 为 631 MB，不能与其他进程 RSS 直接相加。
- 故障前后出现了多次服务启动 ANR 和低内存回收。当前证据能确认低内存压力是主进程此次退出的直接原因，但不能确认压力的完整来源，也不能证明内存泄漏。没有证据将此次退出归因于 SwiftShader 崩溃。
- 17:37 左右，Windows 采样可用物理内存约 17.4 GiB；这是故障后的快照，不能代表故障瞬间。

## 本机缓解和短测

- ARTEMIS 查询显示队列空闲。保存现场与原配置后，将档位从低改为中：4 核、4096 MB；保留软件渲染、视频兼容和其他设置，并正常重启现有实例，未清除数据。
- 原配置保存在上述证据目录中的 `preferences-before-test.ini`。正常启动后配置和设备报告的内存容量均已核对。
- 17:43:55 启动联通智家；17:44:54 时主进程仍为 PID 2690，主页面位于前台。短测日志中未检出新的联通智家 ANR 或低内存回收。
- 这次同时增加了 CPU 和内存，且只验证了启动与主页面，没有复现原自动化操作、直播或长期运行，不能据此断言已修复。后续应在相同操作下监测 Android 可用内存、swap、应用各进程 PSS 与 Windows QEMU 私有提交，必要时继续分析 ANR 处理进程的 ARM 转译异常。
