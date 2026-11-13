# 1.0.5 本机开发版：ANGLE 硬件 Vulkan

2026-11-11。本文记录最初的本机实验，新增配置选项“硬件 Vulkan（ANGLE，实验，仅 OpenGL ES）”。默认仍为硬件 OpenGL；本机为验证新选项切换到 Vulkan。最初实验尚未发布；后续已加入 Intel 核显专用选项并发布 [1.0.5 OTA](release-1.0.5-intel-vulkan.md)。已发布的 1.0.4 文件未修改。沿用 Emulator 37.3.9 Beta / build 16863232，无额外 DLL 混装。

**状态：同屏使用已由用户确认正常，CPU 占用较低是用户本次观察，未做严格性能对照。跨屏崩溃尚未修复。** 用户接受跨屏不是本次必要条件；暂按实验功能保留，不能将短测写成普遍稳定。

## 有效链路和适用范围

Android OpenGL ES → gfxstream 的 ES 转译路径 → ANGLE → Vulkan → 显卡。

当前运行时的可用组合是 `-gpu swiftshader -feature -Vulkan`、`ANDROID_EGL_ON_EGL=1`、`ANGLE_DEFAULT_PLATFORM=vulkan`，并清理继承的软件 ICD 覆盖。这里 `swiftshader` 是选择 ES 转译分类所需的运行时参数；实际设备必须以 SurfaceFlinger 的 ANGLE/Vulkan/GPU 报告及装载模块核验。新初始化检查拒绝 SwiftShader、llvmpipe、lavapipe 等 CPU renderer，失败时仅关闭能核实 PID、完整安装路径和端口归属的本次实例。

**这个选项关闭 Android 原生 Vulkan API。** ANGLE 在 Windows 内部仍使用显卡 Vulkan；需要测试 Android 原生 Vulkan 的应用，须另行验证原硬件 OpenGL 模式，或后续适配模拟器源码。本轮未验证该类应用，不能宣称当前两条 API 都提供 GPU 加速。H.264/HEVC 视频编解码是另外的链路，本改动没有把软件编解码器变为硬件编解码器。

首轮使用本机 NVIDIA RTX 3080 Ti / 621.14。后续 Intel UHD Graphics 770 / 32.0.101.7088 已完成启动、画面及跨屏短测，见 [Intel 验证记录](intel-uhd770-vulkan-20261111.md)。其他 Intel/AMD 核显和独显仍需要实际验证，未作通用兼容承诺。未进行整夜或并发直播稳定性验证。

## 本轮发现并修正的问题

1. 最初的 `-gpu host` + EGL-on-EGL 组合能启动 Android 并报告真实 GPU，却因 HOST/GLES3 分类强制使用 `#version 330 core` 着色器，送入 ANGLE ES 后编译失败，实际画面与录屏全黑。这说明 renderer 字符串和 boot_completed 不能替代真实画面验证。
2. 首次 GUI 测试在 20:22:14 发生宿主原生崩溃：0xC0000005，`gfxstream → ANGLE!EGL_SwapBuffers → nvoglv64.dll+0xF941C7`，空指针读取 0xC8。异常线程 41632，进程 28048。Overwolf 注入模块存在于进程中，但不在已展开的 29 帧调用栈上，不能直接单方定责。
3. 仅设置新的通用 Vulkan layer filter 时仍能加载 Overwolf。增加进程级 `DISABLE_VULKAN_OW_OVERLAY_LAYER`、`DISABLE_VULKAN_OW_OBS_CAPTURE`、`DISABLE_VULKAN_OBS_CAPTURE` 后未再装载这些模块。保留 `VK_LOADER_LAYERS_DISABLE=~implicit~` 并清除可重新启用层的继承变量。此设置仅作用于本次模拟器子进程。
4. `-gpu angle` 在当前版本会被拒绝后转为 auto；它不是有效修复。选择 ES 分类并关闭 guest Vulkan 后，避免了 core 着色器和全局软件 ICD 的两处冲突，用户及原生窗口截图均确认恢复画面。
5. 原正常可写实例跨屏后无响应。972 KB 全线程 dump 展开 222 线程、1991 帧，并从异常处理栈恢复出 `nvoglv64.dll+0xF941C7`、0xC0000005、读取 0xC8、RAX=0，与首次故障相同。此次未装载 Overwolf，因而覆盖层不是复现故障的必要条件。不能凭这一份 dump 将所有直播卡死归为同一原因。
6. `-no-hidpi-scaling` 对照未能规避退出；禁用 ANGLE `asyncCommandQueue` 的对照也在跨屏操作后退出，均未部署。D3D11 对照能启动并报告真实 GPU，但 16 秒后在 ANGLE `libGLESv2.dll+0x538FC1` 发生写入 0x60 的访问异常，未作为产品选项加入。`ANDROID_GL_SOFTWARE_RENDERER=1` 缺少本版 Qt 呈现配套，不部署。

## 配置与回退

在桌面“ArtemisOS 15 - 配置”的“图形渲染”中选择新选项，保存并重启。普通启动重读偏好；软件快捷方式仍只对当次启动覆盖为软件渲染。

本机验证配置：中档、720×1600、硬件 Vulkan，视频兼容模式保持勾选。用户从桌面启动后，21:12:01 初始化日志确认真实 NVIDIA GPU，用户确认同屏画面和操作正常。短 H.264 录屏为 19.899 秒、576×1280、296 帧、1,870,766 字节，全帧解码通过；之后用户再次跨屏，窗口退出。先固定在同一屏幕使用；跨屏修复不能计为已完成。视频兼容模式的软件解码与图形后端独立，当前没有擅自关闭。

维护命令（Windows PowerShell，1.0.5）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File E:\ArtemisOS15\configure.ps1 -NoGui -SetGraphics vulkan
# 恢复硬件 OpenGL；下次启动生效
powershell.exe -NoProfile -ExecutionPolicy Bypass -File E:\ArtemisOS15\configure.ps1 -NoGui -SetGraphics host
```

本机脚本与偏好备份：`backups/before-hardware-vulkan-20261111-202054/`。先前已有完整 AVD 数据备份；本轮未删除或重建原 AVD、应用、SD 卡。早期试验使用原数据的 `-read-only` 实例，完成后通过原桌面启动流程启动正常可写实例。

## 证据与复现

- `build/hardware-vulkan-20261111/gui-crash-20261111-202215/`：首次日志和 47 MB crashpad dump，保留于本地，不提交 dump。
- `build/hardware-vulkan-20261111/CRASH-20261111-202214.md`、`crash-minidump-unwound.json`：时间关联及真实 x64 栈展开。
- `build/hardware-vulkan-source-20261111/CORE-PROFILE-BUG.md`：精确源码、错误模式与有效实验参数。
- `build/hardware-vulkan-source-20261111/INTEROP.md`：ANGLE 缺少 UUID/Win32 外部内存共享扩展时的限制。interop=0 不能等同于所有 GLES 渲染都在 CPU 上。
- `build/hardware-vulkan-20261111/hang-cross-display-20261111-205655/`：跨屏无响应的全线程栈、恢复的异常记录和分析。`build/hardware-vulkan-source-20261111/WINDOW-PRESENT.md` 记录窗口呈现源码与对照限制。
- `tests/hardware-vulkan-environment.ps1`：偏好往返、原默认值、软件覆盖、运行时分类与 guest Vulkan 隔离、provider 缺失/版本错误拒绝、软件 ICD/覆盖层隔离、实际 renderer 验真和停止实例的归属边界。已先观察失败再实现通过。
- 原有 modern-vulkan、display-graphics、sdcard-launch、video-compatibility 等相关回归通过；本轮证据摘要为 `docs/history/evidence/hardware-vulkan-20261111.json`。录屏及 dump 仅保存在本地 build 目录，不提交。

## 一手资料

- [QEMU 精确源码](https://android.googlesource.com/platform/external/qemu/+/6ba955e9dfe60e2ce28e7fe3e9b68479fdbb9812/)：emugl_config、main-emugl、opengles 的模式和 ICD 处理。
- [gfxstream 精确源码](https://android.googlesource.com/platform/hardware/google/gfxstream/+/501867e6a3b1a3be7b935cc977d291150846edab/)：gles_version_detector、gles_context 的 core profile 与 shader 选择。
- [ANGLE](https://chromium.googlesource.com/angle/angle/+/533fa5cedc6164dbb98279f1dfa339f29b66247e/README.md)：GLES 转译后端。ANGLE 在这条 Vulkan 路径中有用；原生硬件 OpenGL 路径不需要强行增加此层。
- [Vulkan loader 的 layer filter](https://vulkan.lunarg.com/doc/view/latest/windows/LoaderLayerInterface.html#layer-disable-filtering)：通用层过滤与 provider 的 opt-out 是两个机制，不能仅凭过滤日志判断模块没有加载。
