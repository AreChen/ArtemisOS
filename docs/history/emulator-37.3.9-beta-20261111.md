# Android Emulator 37.3.9 Beta 升级与 Windows 渲染后端核查

后续进展：本文记录原始官方二进制的行为；随后 [1.0.4 完成了 Windows ANGLE/Vulkan provider 适配](release-1.0.4-modern-vulkan.md)，并验证实际现代软件链路。两次工作的运行时装配不同。

日期：2026-11-11，UTC+8。用户要求将 Android Emulator 更新到官方最新 Beta，保留本地实例数据，并解释为什么软件渲染仍使用旧 SwiftShader GLES。

## 来源与实际交付范围

以当日 [Google SDK 官方索引](https://dl.google.com/android/repository/repository2-3.xml) 的 `emulator`、`channel-1`、Windows x64 条目为准，最新 Beta 为 **37.3.9，build 16863232**。[官方版本记录](https://developer.android.com/studio/releases/fixed-bugs/emulator/37) 同样列出该版本。版本记录没有明确承诺修复本项目遇到的 GLES 原生崩溃。

| 项目 | 本次结果 |
| --- | --- |
| 官方包 | `emulator-windows_x64-16863232.zip` |
| 下载地址 | https://dl.google.com/android/repository/emulator-windows_x64-16863232.zip |
| 官方文件长度 | 456,614,209 字节 |
| 官方索引 SHA-1 | `f7bc48d1899941702fa20686dd532ca7eeba229d`，下载后一次核对通过 |
| 旧运行时 | 37.3.6 Canary，build 16696583 |
| 本机新运行时 | `E:\ArtemisOS15\sdk\emulator`，37.3.9.0，build 16863232 |
| 项目打包源 | `E:\Project\CodeProject\ArtemisOS\stage\sdk\emulator`，相同官方新包 |
| Android 镜像 | 原 Android 15 / API 35 x86_64 镜像 |
| 本机产品版本号 | 仍为 1.0.3；本次没有生成或发布新的安装包、OTA 清单 |

完整官方运行时含 386 个文件。本机安装目录按现有精简策略保留 380 个文件，仅省去 `qemu-system-aarch64`、`armel`、`i386` 的普通和 headless 六个 EXE，共 377,159,568 字节。x86_64 普通、headless 运行程序和图形库均保留。项目打包源保留完整官方运行时。

`installer.iss` 默认读取 `stage/sdk`。若后续使用已有的精简 SDK 缓存，必须用新版运行时重新生成，或向 `tools/Prepare-SlimSdk.ps1` 显式传入 `-EmulatorDirectory 'E:\Project\CodeProject\ArtemisOS\stage\sdk\emulator'`；不能直接复用旧缓存并声称已升级。既有发行基线应保持只读，下一次正式发布使用新产品版本号。

## 数据保护与备份

先向原实例发送 `adb -s emulator-5554 emu kill`，确认 QEMU 退出，再复制 AVD。未使用 `-wipe-data`，未卸载应用或重新创建实例。

备份目录：

```text
E:\Project\CodeProject\ArtemisOS\backups\emulator-before-37.3.9-20261111-164825
├── avd                       原 AVD 的离线副本
├── installed-emulator        原安装目录的 37.3.6 运行时
├── source-emulator           原项目打包源的 37.3.6 运行时
├── preferences.ini
├── setup-state.ini
└── version.ini
```

离线 AVD 共 30 个文件，逻辑长度合计 11,565,381,396 字节，含历史快照。副本与源的相对路径和逐文件长度一致；没有对大数据盘反复计算哈希。关键数据盘为 `InternalAndroid15.avd\userdata-qemu.img.qcow2`，6,096,224,256 字节。SD 卡、加密相关文件和实例描述文件一并保留。备份为独立文件副本；原运行时目录通过移动保留，避免修改可能与旧基线共享硬链接的文件。

最终仍使用 `ArtemisOS_15` / `InternalAndroid15.avd`，端口 5554；`preferences.ini` 与升级前内容完全相同：medium、4 核 / 4096 MB、720p、`graphics=host`、中国移动模拟 SIM、视频兼容开关开启。

## 为什么新版仍会用旧 GLES

之前直接沿用了官方 Windows 软件后端，没有充分核查 SwANGLE 在 Windows 上的回退行为。必须区分两条 API 路径：

```text
现有软件模式：
  GLES 请求   → 旧 SwiftShader GLES
  Vulkan 请求 → 随包 Vulkan SwiftShader

希望验证的现代软件路径：
  GLES 请求 → ANGLE → Vulkan → SwiftShader
```

存在 `vk_swiftshader.dll`、开启 Vulkan 或设置 Android UI 渲染属性，都不能证明任意应用的 GLES 调用已经经过 ANGLE。

在实际 **37.3.9 Windows 二进制**上，以 `-gpu swangle -read-only -no-window -no-snapshot -verbose` 短暂启动原实例，观察到：

```text
emuglConfig_init: vulkan_mode_selected:swiftshader gles_mode_selected:swiftshader
Selecting Vulkan device: SwiftShader Device (LLVM 10.0.0), Version: 1.2.0
useVulkanComposition: false
Graphics API Version OpenGL ES 3.0 (OpenGL ES 3.0 SwiftShader 4.0.0.1)
```

进程实际加载 `lib64\vulkan\vk_swiftshader.dll`，同时加载 `lib64\gles_swiftshader\libGLESv2.dll`、`libEGL.dll` 和 `libGLES_CM.dll`，没有将 GLES 后端切换成 ANGLE。测试实例随后正常退出，再通过原启动器恢复 `host` 模式。

比较 37.3.6 与 37.3.9 的四个 DLL：旧 GLES `libGLESv2.dll`、Vulkan `vk_swiftshader.dll`，以及 `gles_angle` 目录下的 `libGLESv2.dll` 和 `vk_swiftshader.dll`，其所有 PE 节的原始字节哈希相同，包括程序代码和只读数据。完整文件哈希不同，不能称为整个 DLL 文件逐字节相同，也未进一步断言差异全部来自签名。该结果说明这些随包库的程序节未更新；不能据此断言运行时其他改动一定无效，或原故障必然重现。

[Emulator 的 emugl_config.cpp](https://android.googlesource.com/platform/external/qemu/+/refs/heads/emu-master-dev/android/android-ui/modules/aemu-gl-init/src/android/opengl/emugl_config.cpp) 中的 Windows 参数回退逻辑与实测一致。该链接指向 `emu-master-dev`，不冒充 37.3.9 的精确源码 Tag。[SwiftShader 主线](https://swiftshader.googlesource.com/SwiftShader/) 推荐通过 ANGLE 提供 GLES；其能在 Windows 构建，不等于官方 Windows Emulator 已完成这一集成。

**结论：升级到 37.3.9 不会自动接通现代 GLES → ANGLE → Vulkan 软件链路。** 真正迁移需要另行验证、适配 Windows Emulator 与 ANGLE 的集成和发行依赖，不能直接覆盖或改名 DLL。本次没有进行该定制编译。

## 本机验证结果与边界

通过 `E:\ArtemisOS15\start-auto.vbs` 正常启动，实际 QEMU PID 1228；未更改用户渲染偏好。

| 检查 | 观察结果 |
| --- | --- |
| 实际运行版本 | 启动日志为 37.3.9.0 / 16863232 |
| 宿主加速 | WHPX，Windows 10.0.26300 |
| 实际图形后端 | Vulkan `host` + GLES `host`，NVIDIA GeForce RTX 3080 Ti，驱动 621.14；加载 `nvoglv64.dll`，未加载旧 SwiftShader GLES |
| Android 启动 | `sys.boot_completed=1`，本次日志约 29.148 秒 |
| 系统与显示 | Android 15 / API 35 / x86_64，720×1600，`zh-CN`，`Asia/Shanghai` |
| 网络 | 飞行模式关闭，百度域名解析及一次 ICMP 请求成功 |
| 应用保留 | `com.woapp.hebei` 的已安装 APK 路径与升级前完全相同 |
| H.264 短录制 | scrcpy 4.1，`c2.android.avc.encoder`，长边 1280、最大 15 fps、1500K；15 秒采集窗口正常开始、结束并生成 H.264 文件，文件时间轴 6.686 秒，576×1280 |
| 当次进程存活 | 短录制后仍为同一 QEMU PID，ADB 启动完成状态保持为 1 |
| 当次 Windows 崩溃记录 | 从本次正常启动到 16:57 的查询未发现匹配 QEMU/图形库的新 Application Error / WER 记录 |

短录制没有覆盖原摄像头直播场景，也不是过夜稳定性或跨机器显卡兼容性测试，不能宣布历史崩溃已修复。此前故障证据见 [3c49a730 原生退出记录](emulator-exit-3c49a730-20261111.md)。

## 回退方式

需要回退时先正常关闭原实例，确认安装目录下的 QEMU 已退出；将现有两个 37.3.9 `emulator` 目录移至新的隔离目录，再把备份里的 `installed-emulator` 和 `source-emulator` 分别移回原路径，之后通过原启动器启动。执行递归移动前必须核对绝对路径与目标边界，不要覆盖或原地删除已运行过的数据目录。

优先仅回退运行时并继续使用现有 AVD。只有确认必须恢复升级前的数据状态时，才将当前 AVD 另存，再恢复备份里的 `avd`；这会丢失升级后的 Android 数据变动，不应自动执行。

## 证据位置

小型结构化证据保存在 [evidence/emulator-37.3.9-beta-20261111](evidence/emulator-37.3.9-beta-20261111/)，包括官方包来源、部署文件数、离线备份清单核对、软件与硬件后端实测、PE 节比较、系统属性、短录制元数据及升级后检查。下载包和完整启动日志保存在本机 `build\emulator-beta-upgrade-20261111`，原运行时与实例备份位于上述 `backups` 目录。
