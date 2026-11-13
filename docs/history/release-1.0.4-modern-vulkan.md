# ArtemisOS 15 1.0.4：Windows Vulkan 软件渲染适配

日期：2026-11-11。目标运行环境仍为 Windows x86_64；系统仍为现有精简 Android 15 镜像。本次调整运行时图形组件与启动管理，不重建或重置 Android 用户数据。

## 已验证的链路

采用 Google 官方 Android Emulator **37.3.9 Beta / build 16863232** 的程序和随包组件。软件模式的实际 `SurfaceFlinger` 输出为：

```text
ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (Subzero) (0x0000C0DE)), SwiftShader driver-5.0.0)
OpenGL ES 3.1.0 (ANGLE 2.1.22762 git hash: 533fa5cedc61)
```

官方 Windows 参数选择器会把 `swangle` 归入 SwiftShader 路径，因此日志中的后端名称仍可能写 `swiftshader`。本版本根据实际加载库版本、Android GL_RENDERER 和 Vulkan 设备判断是否接通新实现，不能只根据 CLI 后端名称判断。

本机原实例已升级到 1.0.4，软件快捷方式的 Windows 窗口实际显示 Android 桌面，标题为 `ArtemisOS 15 v1.0.4`。之后按原偏好恢复 `-gpu host`，实际使用 NVIDIA GeForce RTX 3080 Ti / `nvoglv64.dll`，Android 启动完成。偏好文件保持逐字节一致；SD 卡仍 mounted，简体中文和 Asia/Shanghai 时区保留。

## 装配方式与可重建输入

`tools/Prepare-ModernVulkanRuntime.ps1` 要求输入未经本工具处理的官方 37.3.9/16863232 完整运行时；输出必须是项目 `build` 内的新目录。它不修改输入，不修改 QEMU/Emulator 可执行程序。

1. 将官方 `lib64/gles_angle` 的全部 6 个文件作为 EGL/GLES provider 放到输出的 `lib64/gles_swiftshader`：`libEGL.dll`、`libGLESv2.dll`、`d3dcompiler_47.dll`、`vulkan-1.dll`、`vk_swiftshader.dll`、`vk_swiftshader_icd.json`。
2. 将同一来源的 `vk_swiftshader.dll` 和 ICD 同步至输出的 `lib64/vulkan`，使 Android 直接 Vulkan 请求也使用配套现代 SwiftShader。
3. 每个替换文件独立复制并记录 SHA-256；其余文件以只读构建输入的硬链接复用。输出包含 `modern-vulkan.json` 和 `ARTEMIS-GRAPHICS-NOTICE.txt`。使用期间不得原地修改这些硬链接输入。
4. 不保留旧 GLES provider 的 `libGLES_CM.dll`。配套 gfxstream 内部翻译 GLES1，并通过 EGL/GLES2 接口访问 ANGLE。

这是 EGL/GLES ABI 对接，Vulkan DLL 保留自己的接口和文件名。完整原始与第三方许可文件继续随包保留。此结果是项目实测适配，不能表述为上游正式支持该 Windows 组合，也不自动解决整包许可的所有问题。

本次构建目录：

- 完整装配运行时：`build/modern-vulkan-runtime-1.0.4`，391 个文件。
- 安装用 SDK：`build/slim-sdk-1.0.4`，429 个文件；其中运行时 385 个文件，按既有规则移除 6 个无关平台 QEMU。
- Android 镜像沿用 `releases/1.0.0-sd-fixed` 已有基线，3,576,692,736 字节，SHA-256 `ab633cc0504a61c6006cd39d2b371dff8e341f0176e70384597692d7d90a2752`。

未经适配的官方运行时保存在 `backups/before-modern-vulkan-1.0.4-20261111-172606/official-emulator-37.3.9`；`stage/sdk/emulator` 现已是适配结果。后续重跑组装器应使用原始官方输入，不能把已经适配过的输出当作源包。正式文件基线冻结于 `releases/1.0.4`；其 SDK 使用硬链接复用，应保持不可变。

## 启动选择与环境隔离

`Get-ArtemisGraphics` 将 `software`、`swiftshader`、`swangle` 以及一次性软件快捷方式归一为 `swangle`。原配置文件保留原字符串，不进行偏好迁移。

- `host`：不注入软件图形环境，保持硬件优先默认。
- `auto`、`lavapipe`：仅设置 `ANGLE_DEFAULT_PLATFORM=swiftshader`，让实际选择软件 GLES 时使用 ANGLE 的 CPU provider；由运行时自行启用 EGL-on-EGL，保留其原有 Vulkan 设备选择。
- 明确软件模式：设置 `ANGLE_DEFAULT_PLATFORM=swiftshader`、`ANDROID_EGL_ON_EGL=1` 和随包 Vulkan ICD；清除会抢占该 ICD 的进程级驱动覆盖变量。

所有覆盖仅在 `Start-Process` 期间传给模拟器子进程，并在 `finally` 恢复启动器原环境，不写 Windows 用户或系统环境。运行时 manifest 与 8 个必需文件不完整时阻止软件启动并提示重新安装。继续使用 `-no-snapshot`，避免恢复旧图形实现保存的对象。

## 验证与限制

已执行：运行时组装器红绿测试、启动环境红绿测试、图形选择与默认偏好回归、SD 卡启动保护、视频兼容配置检查；隔离 Android 软件启动与本机原实例的软件/硬件启动。

隔离实例中完成一次 **20 秒 H.264** 录制，`c2.android.avc.encoder`，720×1280、15fps 上限、1.5Mbps，文件时长 20.253 秒，FFmpeg 完整解码退出码 0。联通智家在该新建实例正常启动并显示首次隐私协议页面；未操作同意、登录或验证码。该结果不代表直播、HEVC 或通宵自动化稳定性已经验证，也不证明历史所有崩溃均已修复。

隔离 `-gpu auto` 启动还实际验证了自动模式的软件 GLES 分支，同样输出 ANGLE/Vulkan/Subzero，Android 启动完成；这不能作为自动模式选择硬件的证据。首次自动模式测试因临时 Emulator home 目录未创建而反复写日志，停止该隔离进程、保留 4KB 错误样本并清除临时错误日志后，修正测试目录重新验证通过；原用户实例未受该测试的目录操作影响。

最终安装包：`dist/ArtemisOS15-Offline-Installer-1.0.4.exe`，**1,228,527,013 字节**，SHA-256 `5533582eb986f4d8b41b436958f69784ccc2b8ffe60af9558598e8891fe88d66`。Inno Setup 编译退出 0。同一最终 EXE 在临时 Windows 标准用户下完整安装成功，检查注册版本、launch/mksdcard、现代 manifest 与 8 个 provider 文件哈希，确认无旧 GLES_CM；临时用户、资料及安装目录清理成功。该隔离安装跳过了可选 NTFS 稀疏化，没有启动 Android；Android 启动及图形验证由上述独立实例与保留数据的本机实例完成。

OpenList 先发布并匿名读回验证 `1.0.4.json`、`1.0.4.sig` 两个“暂无更新”标记，使新安装包可以正常检查更新。旧版到新版的 OTA 另行按实际发行基线构建和验证，见下一节。现有完整安装器仍保护已安装 SDK/AVD，本包按全新安装交付；已有用户使用 OTA 更新运行时。

## 1.0.3 → 1.0.4 OTA

签名补丁包含 **124 个变化路径、117 个去重对象**，实际下载 **598,759,355 字节（571.0 MiB，约 600 MB）**。只更新 Windows Emulator 运行时、配置与启动管理；不含系统镜像、platform-tools 或用户 `data/avd`。仍按完整变化文件传输，不是二进制差分或 Android 分区 OTA。

**2026-11-11 18:34（UTC+8）已发布到 OpenList**。117 个对象全部匿名读回并校验 SHA-256；随后用原版旧 core 检查两条 1.0.3 谱系，均收到与本地验证完全相同的 1.0.4 签名清单；完整安装及 OTA 两种 1.0.4 均正确得到“暂无更新”。在线发布证据为 `ota-openlist-publish-result.json`、`ota-openlist-client-readback.json`。

本次协议不压缩对象。最大的三个变化文件分别是 Qt WebEngine 121.8 MB、图形界面 QEMU 66.9 MB、无窗口 QEMU 57.2 MB，合计约 246 MB；另含 Lavapipe、gfxstream、网络模拟和其他新版配套库。该体积包含整次 37.3.6 → 37.3.9 运行时升级，不只是启动脚本文本。压缩传输和二进制差分仍待后续实现，不能直接给现有对象换成压缩字节，否则旧客户端大小和哈希检查会失败。

两种真实发行谱系的根 `launch.ps1` 不同，旧协议每条路径只支持一个基线哈希。补丁不直接列出根 launcher，而是更新两份共同 VBS 入口，并增加 `update/launch-current.ps1` 和已签名的 `update/launcher-1.0.4.ps1`。首次启动先执行原恢复程序，再持原更新锁完成迁移：只接受两个明确旧哈希，验证新文件精确哈希，备份实际旧 launcher 并原子扩充现有恢复事务，原子替换后完成事务。未知或损坏输入拒绝覆盖并恢复公共更新；断电恢复、重复执行和未来版本透传均有回归覆盖。签名、公钥和旧文件检查没有放宽。

两条完整 1.0.3 基线分别由 `releases/1.0.0`、`releases/1.0.0-sd-fixed` 叠加三次真实签名发布重建。使用真正旧版 core 和 apply，分别验证 `host`、`swiftshader` 偏好：124 个安装对象、111 个已有 SDK 文件、8 个 provider、启动器归一及恢复记录均通过，偏好和隔离 AVD 数据标记逐字节不变。

随后从实际升级后的 SDK 启动 Android，`sys.boot_completed=1`，SurfaceFlinger 确认 ANGLE/Vulkan/SwiftShader Subzero；模块记录包含现代 `libEGL.dll`、`libGLESv2.dll` 和 Vulkan driver。旧 `libGLES_CM.dll` 因 OTA 无删除指令仍留在磁盘，实测没有加载。一次性软件启动也没有改变保存的渲染选择。启动验证工具曾因 CLI 代理继承子进程管道而等待，改为等待原 PowerShell 进程后完整测试退出 0；该问题属于验证工具。

工具与证据：

- `tools/ota/Launch-ModernVulkan.ps1`、`tests/modern-vulkan-ota-migration.ps1`。
- `tests/modern-vulkan-ota-release.ps1`、`tools/runtime-lab/Test-ModernVulkanOtaBoot.ps1`。
- `build/ota-1.0.4-modern-vulkan/repository` 为本次不可变签名仓库；清单 SHA-256：`4ca2a38fe934f02f5bd355fcc3d208d70b55c86b8260bc167c21d92d2db72a6e`。
- `releases/1.0.4-ota` 保存实际升级后的文件基线，不含用户数据。它与完整安装基线的 VBS、迁移文件和未删除旧 SDK 文件不同；后续构建须保留两者并按清单涉及路径检查基线，不能只按版本号推断所有文件相同。
- 长期小型证据：`evidence/release-1.0.4-modern-vulkan/ota-package-summary.json`、`ota-baseline-compatibility.json`、签名清单、`ota-legacy-upgrade-tests.json`、`ota-native-boot.json` 及上述 OpenList 发布与客户端读回记录。

1.0.2 用户沿现有通道先升 1.0.3；1.0.0/1.0.1 的历史更新器退出等待问题仍应先用已发布的 1.0.2 更新修复工具处理。此补丁不改写历史更新清单，不声称直接解决所有旧版更新器问题。软件偏好升级后自动使用新链路，硬件偏好继续使用硬件；不强制改变用户的渲染选择。通宵直播或自动化的稳定性范围仍受前节验证限制约束。

## 证据与回退

原始实验和日志：`build/modern-vulkan-20261111`。小型长期证据见同名 `evidence/release-1.0.4-modern-vulkan` 目录。

本次本机运行时与脚本备份：`backups/before-modern-vulkan-1.0.4-20261111-172606`。此前完整 AVD 备份：`backups/emulator-before-37.3.9-20261111-164825/avd`。

回退时先关闭模拟器并确认运行时辅助进程退出，将新运行时另存后恢复 `installed-emulator` 和备份脚本即可。用户 `data` 目录不参与本次运行时替换；不要为了回退图形库而恢复旧 AVD 或删除用户数据。

## 主要依据

- [官方 Emulator 37 发布记录](https://developer.android.com/studio/releases/fixed-bugs/emulator/37) 与[官方包索引](https://dl.google.com/android/repository/repository2-3.xml)。
- [QEMU 对应 build 16863232 的快照提交](https://android.googlesource.com/platform/external/qemu/+/6ba955e9dfe60e2ce28e7fe3e9b68479fdbb9812)；其 `emugl_config.cpp` 包含 Windows `swangle` 选择及 EGL-on-EGL 环境设置。
- [gfxstream 对应 build 16863232 的快照提交](https://android.googlesource.com/platform/hardware/google/gfxstream/+/501867e6a3b1a3be7b935cc977d291150846edab)；其中 EGL loader 通过真实导出检测 ANGLE，GLES1 dispatch 由运行时内部提供。
- [SwiftShader 上游](https://swiftshader.googlesource.com/SwiftShader/)：现代 Vulkan 与 ANGLE 的配套关系。
