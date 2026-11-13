# 2026-11-11 软件 Vulkan CPU 负载调查与硬件 ANGLE 能力验证

调查时间：19:52–19:56，UTC+8。仅取证和运行独立 EGL 探针；未重启现有实例、未改变渲染偏好、未停止正在执行的自动化录屏。探针不启动 AVD，不读取或写入 Android 数据盘。此记录不表示已经实现新的产品渲染选项。

## 现有实例的事实

- 安装目录 `E:\ArtemisOS15`，Emulator 37.3.9 / ArtemisOS 1.0.4，QEMU PID 69096，Android 序列号 emulator-5554。
- QEMU 实际启动参数包含 `-gpu swangle -feature -HardwareDecoder`。偏好文件为 `graphics=swangle`、medium、720p、`video_compat=1`。
- SurfaceFlinger 的真实 GLES renderer 为 `ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (Subzero) (0x0000C0DE)), SwiftShader driver-5.0.0)`；实际加载 ANGLE 的 libEGL/libGLESv2 及现代 vk_swiftshader。当前 GLES 主渲染是 CPU 软件计算。
- 宿主有 32 个逻辑处理器。两次各约 5 秒采样，QEMU 占整机 CPU **35.5% 和 36.0%**；第一段约相当于持续占用 11.4 个逻辑处理器的计算时间，并非只占单核的 35.5%。进程占用包含虚拟 CPU、图形驱动、编解码等全部工作，不能全部算到 SwiftShader 上。
- WHPX 的 `-accel-check` 返回已安装并可用；目前没有证据表明虚拟 CPU 因失去硬件虚拟化而全软件执行。
- Android top 单次样本：`media.swcodec` 134%，联通智家 `com.woapp.hebei` 100%，composer 48.2%，SurfaceFlinger 27.5%。Android top 的 100% 表示一个虚拟 CPU 核，与 Windows 整机 CPU 百分比口径不同。
- `dumpsys media.resource_manager`：联通智家 PID 3337 持有 **c2.android.hevc.decoder**；scrcpy server PID 25120 持有 **c2.android.avc.encoder**，两者均为软件视频 codec。
- Windows scrcpy PID 35364 从 19:45:16 开始运行，参数为 H.264、长边最大 1280、最高 15 fps、1500K、无音频、无窗口录制。此刻有录屏会话在运行；这些证据不能单独证明它是未清理的历史录制或流程异常。

因此已经确认软件渲染、HEVC 解码和 H.264 编码同时存在，并有持续的较高 CPU 占用；没有进行分别停止各项工作的对照试验，尚不能精确分配它们各自的 CPU 比例。这次短时调查也不能证明新软件后端比旧后端多耗多少 CPU，或据此判断存在内存泄漏。

## 硬件 ANGLE/Vulkan 探针

实验脚本：`build/cpu-render-investigation-20261111/Probe-AngleVulkan.ps1`。

使用当前运行时自带 `lib64/gles_angle` 的 libEGL/libGLESv2，在独立 PowerShell 进程中显式请求 EGL ANGLE Vulkan + hardware device，清除该子进程的 Vulkan ICD 覆盖，创建 16×16 pbuffer 和 GLES3 context。未替换任何运行时 DLL。

结果保存于 `build/cpu-render-investigation-20261111/angle-hardware-capability.json`：

```text
Vendor: Google Inc. (NVIDIA)
Renderer: ANGLE (NVIDIA, Vulkan 1.4.357 (NVIDIA NVIDIA GeForce RTX 3080 Ti (0x00002208)), NVIDIA-621.14.0.0)
Version: OpenGL ES 3.1.0 (ANGLE 2.1.22762 git hash: 533fa5cedc61)
```

实际加载 ANGLE、Vulkan loader 和 NVIDIA 驱动，未加载 SwiftShader。由此证明 **随包 ANGLE + 本机驱动具备 GLES → Vulkan → 真实 GPU 的上下文能力**。这不是完整 Android Emulator 集成验证，也没有执行摄像头直播、录屏或压力测试。

当前产品 `host` 是已有的硬件渲染选择；本机此前实测走 NVIDIA 桌面 OpenGL。它不能直接等同于已经新增了硬件 ANGLE/Vulkan 选项。现代软件适配对 swangle 强制选择 SwiftShader，并不提供硬件 ANGLE/Vulkan 配置。完整接入仍需独立验证 Emulator 的 EGL provider、宿主 Vulkan ICD、Android GLES renderer、加载模块、窗口显示/读回和录屏稳定性。

## 独显与核显的适用性

ANGLE 官方列出 Windows Vulkan backend；其硬件路径并不要求显卡必须为独立显卡。Intel/AMD 核显与 NVIDIA/AMD 等独显均可作为待验证设备，实际要求取决于显卡驱动暴露的 Vulkan 版本、扩展及 ANGLE/Emulator 的功能需求。老型号不能一概保证，双显卡笔记本也需确认最终选中的物理设备。

本次只验证了 RTX 3080 Ti。当前机器枚举到的其他适配器是虚拟显示设备，不能作为 Intel/AMD 核显兼容性证据。

后续优先验证硬件 ANGLE/Vulkan 作为可选择的后端，同时保留已有 host 和软件选项。GPU 渲染本身不会自动把 Android 的 HEVC 软件解码或 scrcpy 的 H.264 软件编码变成宿主硬件视频 codec。

## 官方资料与限制

- [ANGLE 官方 README](https://chromium.googlesource.com/angle/angle/+/main/README.md)：GLES 到 Vulkan 等 API 的翻译能力和 Windows backend 支持。主线资料不能代替随包二进制实测。
- [ANGLE EGL 扩展头文件](https://github.com/google/angle/blob/main/include/EGL/eglext_angle.h)：探针使用的 Vulkan 与硬件设备选择常量，已核对。
- [Android Emulator 图形加速](https://developer.android.com/studio/run/emulator-acceleration)：host、软件及 swangle 的定义；当前文档将 angle/angle_indirect 列为已废弃。不能把传入旧 angle 参数当作硬件 Vulkan 成功的证据。
- [Emulator emugl_config.cpp](https://android.googlesource.com/platform/external/qemu/+/refs/heads/emu-master-dev/android/android-ui/modules/aemu-gl-init/src/android/opengl/emugl_config.cpp)：该主线源码含 ANGLE 模式回退及软件选择逻辑，属于源码背景，不冒充 37.3.9 精确对应版本。
