# 硬件 ANGLE/Vulkan 设计

用户已在完成能力调查后要求实现。目标是在 ArtemisOS 的图形配置中提供 Android GLES → gfxstream → ANGLE → Vulkan → 宿主真实 GPU 的选择，减少长时间视频场景中的 CPU 软件图形负载。

方案：复用 Emulator 37.3.9 build 16863232 随附 ANGLE，通过独立的进程级 EGL provider 和宿主 Vulkan 驱动设置接入。与现有 host/OpenGL、软件 SwANGLE 并列。仅独立 EGL 上下文测试已成功，必须继续验证完整 Android 集成。不能使用已废弃 angle 参数冒充完成，也不能改动 SwiftShader 的软件选项语义。若运行时无法可靠集成，保留证据并明确阻塞点，不伪造成功。

保留 host 默认值。新增偏好键 vulkan，界面写明硬件 Vulkan；原有软件快捷方式对新偏好仍提供一次性覆盖。偏好、父进程/Windows 全局环境、其他实例互不污染；不将用户的其他设置或数据重置。失败时显示可操作错误，不静默切到 CPU。完整选项需校验当前运行时版本与 ANGLE provider 文件。支持范围以真实显卡/驱动实测为准，不把一台 NVIDIA 电脑的结果扩展为所有核显兼容。

先使用已有独立实验 AVD 验证，再备份安装脚本并应用于本机，允许重启保留原数据的用户实例。发布目录和历史 SDK 硬链接保持只读。本轮完成实现、本机部署和短录屏验证，不改动已发布 OTA 内容。

验证：偏好读写、模式选择、子进程环境、软件快捷方式覆盖、provider 缺失拒绝，以及实际 Android 启动、SurfaceFlinger renderer、宿主模块/真实 GPU、短 H.264 录屏。GPU 渲染不自动实现硬件视频编解码；不承诺未进行的过夜稳定性测试或跨 GPU 性能结论。

实测收敛（2026-11-11）：运行时须使用 `-gpu swiftshader -feature -Vulkan` 的 ES 分类，配合 ANGLE 的 Vulkan 硬件设备选择，避免 host 的 core shader 错配。它暂关闭 Android 原生 Vulkan API。用户确认同屏使用正常、CPU 较低；跨屏仍触发 NVIDIA 宿主异常，用户明确不将跨屏作为本次必要条件。界面标记实验模式，不发布稳定安装包/OTA，不把固定 DPI、异步队列开关或短暂启动成功的 D3D11 对照误记为修复。
