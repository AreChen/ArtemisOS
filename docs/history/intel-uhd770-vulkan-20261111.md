# Intel UHD Graphics 770：硬件 Vulkan 本机验证

验证日期：2026-11-11，UTC+8。用户启用集显后，要求验证 ArtemisOS 是否可以使用该设备。本次没有修改正式启动器、系统镜像、已发布安装包或 OTA，也没有修改 Windows 全局显卡偏好。

以上为最初只读试验的范围。后续用户已要求正式接入，现已发布 [1.0.5 Intel 核显 OTA](release-1.0.5-intel-vulkan.md)，并从正式启动器验证原可写实例。下文保留最初的试验记录和限制。

## 结论与边界

本机 Intel UHD Graphics 770 可以运行现有 ANGLE 硬件 Vulkan 路径。Android 已启动、实际窗口可见，ADB 保持响应；一次自动跨屏移动后画面正常，用户也确认核显跨屏没有崩溃。当前证据是短时验证，不能据此承诺所有 Intel 驱动、显示器组合或长时间直播均稳定。

这与本机此前 NVIDIA 路径跨屏触发 `nvoglv64.dll+0xF941C7` 异常形成对照，支持继续调查特定驱动与 ANGLE/Vulkan 呈现的兼容问题。它不是单方定责或所有故障同源的证明。

## 实际配置

- 集显：Intel(R) UHD Graphics 770，vendor `0x8086`，device `0xA780`。
- Windows 驱动：`32.0.101.7088`；Vulkan 设备报告 `1.4.323`。
- 运行时：Android Emulator `37.3.9 Beta`，build `16863232`。
- ANGLE：`533fa5cedc6164dbb98279f1dfa339f29b66247e`。
- 原 Android 15 AVD 的只读测试实例：`emulator-5576`，不删除或重建原用户数据。
- 使用现有 ES 运行时分类：`-gpu swiftshader -feature -Vulkan`，并非 CPU SwiftShader。宿主仍通过 ANGLE 使用显卡 Vulkan，Android 原生 Vulkan API 暂未接通。
- 进程环境：`ANDROID_EGL_ON_EGL=1`、`ANGLE_DEFAULT_PLATFORM=vulkan`，额外设置 `ANGLE_PREFERRED_DEVICE=Intel(R) UHD Graphics 770`。其余隔离设置复用 `Get-ArtemisGraphicsEnvironment`。

实际 SurfaceFlinger：

```text
GLES: Google (Google Inc. (Intel)), Android Emulator OpenGL ES Translator (ANGLE (Intel, Vulkan 1.4.323 (Intel(R) UHD Graphics 770 (0x0000A780)), Intel Corporation-101.7088)), OpenGL ES 3.0 (OpenGL ES 3.1.0 (ANGLE 2.1.22762 git hash: 533fa5cedc61))
```

进程装载了 Intel `igvk64.dll`、`igvkMedia64.dll`，未在检查样本中装载 `vk_swiftshader.dll`。同进程仍可装载 NVIDIA 模块以枚举设备或提供其他图形功能；仅凭装载模块不能断言实际 renderer，必须结合 Android 的 GLES 报告。

## 选择显卡的方法与限制

当前工具进程以管理员权限运行。即使设置 `VK_DRIVER_FILES` 和 `VK_ICD_FILENAMES` 指向 Intel JSON，`vulkaninfo --summary` 仍枚举两张 NVIDIA 和一张 Intel。官方 Vulkan Loader 文档说明，提升权限时会忽略这类驱动文件覆盖。此次改用 ANGLE 自身的设备选择，并以实际 Android renderer 验证。

匹配 ANGLE 源码 `src/common/vulkan/vulkan_icd.cpp:94-100` 读取 `ANGLE_PREFERRED_DEVICE`，与 `VkPhysicalDeviceProperties.deviceName` 作完整字符串比较。因此这里使用设备完整名称，不能把 `Intel` 子串匹配当成已验证用法。未来若加入产品显卡选项，仍应检查实际 renderer；设置环境变量本身不是成功标准。

临时复现脚本为 `build/intel-vulkan-20261111/Start-IntelVulkan.ps1`，仅适用于本机实验。当前窗口是只读实例，退出后新增设置和安装内容不保留。原桌面快捷方式尚未固定 Intel，不能把本次选择解释为常规启动已完成迁移。

## 验证与证据

- `build/intel-vulkan-20261111/vulkaninfo-summary.txt`：设备能力枚举。
- `emulator-stdout.log`、`surfaceflinger.txt`：真实启动及 Intel renderer。
- `runtime-facts.json`：进程、完整模块列表和采样时间。
- 原生窗口截图确认画面；Windows 跨屏操作后仍正常，用户亦确认跨屏成功。
- 20 秒 H.264 采集窗口生成 11 帧、媒体时长 1.1 秒、576×1280、66,197 字节，完整解码通过。画面主要静止，这不是连续 20 秒动态视频播放或长时录制稳定性验证。
- 录制完成后，ADB `sys.boot_completed=1`，QEMU 仍响应。没有进行严格 CPU 对照、过夜或多实例稳定性测试。
- 可提交的摘要：`docs/history/evidence/intel-uhd770-vulkan-20261111.json`。视频、完整日志和驱动源码摘录仅留本机 build 目录。

## 一手资料

- [匹配的 ANGLE 设备选择源码](https://chromium.googlesource.com/angle/angle/+/533fa5cedc6164dbb98279f1dfa339f29b66247e/src/common/vulkan/vulkan_icd.cpp)
- [Vulkan Loader：驱动覆盖与提升权限的例外](https://vulkan.lunarg.com/doc/view/latest/windows/LoaderDriverInterface.html)
