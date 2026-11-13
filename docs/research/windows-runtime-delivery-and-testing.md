# Windows 运行时、交付、自动化与许可资料

资料核查日期：2026-10-31。范围：最终用户在 Windows x86_64 本机运行；开发或构建系统可在 Linux。本文是技术资料，不是许可证法律意见，也不代表本项目已完成所有主张。每个条目分别列出来源、适用范围、环境、解决的问题、结论、限制与验证状态。来源中的 `main`/在线手册会变动；实施前固定具体提交、软件构建号和 SDK 包许可。

## 先读：结论和已知边界

- Android Emulator 的 **Windows 宿主程序**可以在 Windows 使用 WHPX 加速运行模拟器；AOSP 镜像在 Linux 构建，不意味着终端用户要安装 Linux、WSL2、Docker、Linux 虚拟机或使用远程服务器。独立交付一套可加载自制镜像的 Windows 运行时及许可证、依赖、安装升级、性能和可维护性仍须验证。
- 不应把 SDK 下载、AOSP 开源、二进制中的某个 `LICENSE` 或 NOTICE 当作整个产品的再分发授权。当前 SDK 通用条款对复制和再分发设限，开源组件另按其许可；需结合**包内实际许可、所有二进制组件、版本、来源和分发场景**逐一审核。当前本机 37.3.4 包的 `package.xml` 实际引用 `android-sdk-preview-license`，尤其需要核对该具体条款。
- AOSP `libnativebridge` 是桥接框架，接口本身不是 ARM→x86 翻译器。本次尚未证实 Android 15 r1 默认目标具备 ARM64→x86_64 实现；兼容 ARM64 APK 需要进一步取得、适配并验证可分发且可维护的实现。AOSP 也有面向其他架构的转译实验，不能一概否认；Google APIs 镜像已有的特性不能自动转移为自编 AOSP 镜像能力。32 位暂不纳入本期要求。
- 图形软件渲染与 CPU 虚拟化是两回事：没有可用 GPU 可尝试 SwiftShader 等，但依然推荐并在本项目当前启动器中要求可用 CPU 虚拟化加速（`-accel-check` 成功，脚本不严格限定 WHPX）。本机 Emulator 37.3.4 的 `-help-accel` 将 `-accel off` 标为不受支持并需特殊变量才能启用；未实测的低配设备不能宣称可流畅运行。

## A. Windows 宿主与虚拟硬件

### W1. Android Emulator 硬件加速

- **来源**：[Configure hardware acceleration for the Android Emulator](https://developer.android.com/studio/run/emulator-acceleration)；维护者 Google Android Developers；类型：官方产品手册。
- **适用版本、环境**：当前在线手册；Windows 10 1803+ 的 Windows x86_64 宿主，x86/x86_64 Android 客体。源码构建环境不限定在这份文档中。
- **解决的问题与结论**：官方推荐 Windows Hypervisor Platform（WHPX）；Intel VT-x + EPT + Unrestricted Guest、AMD-V/SVM 与二级地址转换等要求应按处理器核查，并在 BIOS/UEFI 中开启。启用 Windows 可选特性一般涉及管理员授权，官方步骤要求启用后重启。运行时用随目标版本提供的 `emulator -accel-check` 验证，而不是只检查注册表。
- **限制**：官方同时列出了 Android Studio 开发环境要求，不应误当成独立运行时的已测最低配置。嵌套虚拟化和同时运行其他虚拟化软件需要单独验证；不要把 Windows 完整 Hyper-V 管理角色与 WHPX API 混同。
- **验证状态**：官方支持说明；项目当前机器此前报告 WHPX 可用，仅代表该机器可用。2026-12-31 后 AEHD 将停止支持，不应把 AEHD 作为长期首选。

### W2. Windows 特性与权限：区分 WHPX 和 Hyper-V 角色

- **来源**：[Microsoft Hyper-V 安装](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/get-started/install-hyper-v)、[Windows 上的 Android 模拟器加速](https://learn.microsoft.com/dotnet/maui/android/emulator/hardware-acceleration)；维护者 Microsoft；类型：官方操作指南。
- **适用版本、环境**：Microsoft 文档各自列出的 Windows 10/11 或 Windows Server；运行环境 Windows；与 AOSP 构建环境无关。
- **解决的问题与结论**：通过系统可选功能或受提升权限的系统管理命令启用相应虚拟化功能，系统可能需要重启。Microsoft 的 Hyper-V **完整角色**要求支持的 Windows 版本和版别，不能直接据此断言 WHPX 在 Windows Home 必然不可用。
- **限制**：Google Emulator 指南推荐单独启用 WHPX；Microsoft MAUI 文档描述启用 Hyper-V 和 WHPX 的另一条配置，版别和系统版本要求不完全相同。具体 Windows Home/Pro、企业策略、版本组合应在实体机上核对；不要未经许可自动改 BIOS/安全策略或强制重启。
- **验证状态**：官方文档；最终产品的 Home/Pro/受管企业电脑的矩阵**待实测**。

### W3. 图形后端与无 GPU 环境

- **来源**：[Emulator 图形加速](https://developer.android.com/studio/run/emulator-acceleration)、[Emulator 故障排查](https://developer.android.com/studio/run/emulator-troubleshooting)；维护者 Google；类型：官方手册。
- **适用版本、环境**：在线文档对应的 Emulator 版本；Windows x86_64，也适用于文档所列其他宿主。不同版本对模式支持不同。
- **解决的问题与结论**：`-gpu auto` 由模拟器结合环境选择，`host` 使用宿主 GPU；`software` 自动选软件后端，`swiftshader`/`swangle`/`lavapipe` 是具体软件渲染选项。图形问题可尝试软件模式；应记录选择与失败日志，并允许手动覆盖。`-feature -Vulkan` 是部分 Vulkan 故障的官方排障选项，不是默认适用于所有版本的优化。
- **限制**：无 GPU 不代表没有 CPU 虚拟化；软件渲染可能增加 CPU 占用，不保证视频播放和 Vulkan 兼容。旧名称如 `swiftshader_indirect` 在较新版本已弃用，不能直接照抄旧教程。
- **验证状态**：官方支持的模式；本项目 0.3.4 本机已验证相关启动配置，真实无 GPU、低端笔记本及 Intel/AMD 集显矩阵**待测**。

### W4. 产品化安装与离线运行所需文件

- **来源**：[Emulator 命令行和镜像目录](https://developer.android.com/studio/run/emulator-commandline)、[Emulator 源码](https://android.googlesource.com/platform/external/qemu/+/refs/heads/emu-master-dev/)；维护者 Google/AOSP；类型：官方文档和源码目录。
- **适用版本、环境**：在线文档；Windows x86_64 运行时；系统镜像可先由 Linux 编译。项目当前 `stage/sdk/emulator/source.properties` 为 37.3.4 / build 16555280，当前 Google APIs API 35 镜像 revision 9 的元数据要求 Emulator ≥33.1.24，这是**现有 Google 镜像**的要求，不是对自编镜像的承诺。
- **解决的问题与结论**：最终包需准备匹配版本的 Windows Emulator 可执行程序及运行时依赖、对应的完整系统镜像目录与元数据、启动/配置工具、必要 ADB 工具、许可与通知文件。每个用户/实例需独立可写数据；可以无需安装 Android Studio IDE，但完整离线交付、Windows 缺失运行库和授权必须独立验证。
- **限制**：文档列出 `kernel-ranchu`、`ramdisk.img`、`system.img`、初始 `userdata.img` 等示意，不是任意版本都能仅靠这四个文件拼装。动态分区、vendor、AVB、内核和元数据必须以同一产品/构建的产物清单及实际 Windows 启动为准。不能把 Cuttlefish 文件当作 Goldfish AVD 的直接替换。
- **验证状态**：对 Google 官方包结构属官方说明；已自编 AOSP 镜像与目标 Windows 运行时组成可分发产品仍**待实测和授权审核**。

### W5. 宿主系统要求与不支持的平台

- **来源**：[Install Android Studio](https://developer.android.com/studio/install)、[Emulator 故障排查](https://developer.android.com/studio/run/emulator-troubleshooting)；维护者 Google；类型：官方系统要求和排障。
- **适用版本、环境**：文档当前为 64 位 Windows 10 及以上的 Studio + Emulator；Windows ARM 当前标为不支持。运行需求与 Linux 构建需求分离。
- **解决的问题与结论**：本项目应单独声明 Windows 10 1803+ 为 WHPX 的官方技术下限，而将自己产品的最低 Windows 版本、内存、磁盘和 CPU 范围以实际验证结果发布。官方 Studio + Emulator 推荐/最低值（当前页面包含 16 GB、图形硬件等）涵盖 IDE，不可无证据挪作独立产品保证。
- **限制**：官方对 Windows 8.1 的旧版本解决办法属于不支持的尝试；Windows ARM 另立研究，不默认可用。兼容性测试需要覆盖干净系统，不能只依赖本开发机。
- **验证状态**：官方文档；实际产品最低硬件和 OS/Edition 矩阵**待实测**。

## B. 多实例与自动化

### T1. AVD 文件、端口和数据生命周期

- **来源**：[Start the emulator from the command line](https://developer.android.com/studio/run/emulator-commandline)；维护者 Google；类型：官方手册。
- **适用版本、环境**：当前在线文档、项目本地 Emulator 37.3.4；Windows 本机运行；语法以具体版本 `-help` 为准。
- **解决的问题与结论**：只读系统镜像可共享；每实例使用独立 `-datadir`/userdata、AVD 名、console 与 ADB 端口。`-port` 优先指定偶数，典型占用邻接端口；`-no-window` 可无 UI 运行，`-no-snapshot` 关闭快照载入和保存但**并非删除用户数据**。`-wipe-data` 会清除该实例的应用和设置，`sdcard.img` 另行处理。
- **限制**：端口申请与启动之间存在竞态，须在独立实验中验证冲突和释放；不要无差别停止 ADB server 或重置其他模拟器；Windows 路径/权限、用户名和磁盘容量必须纳入测试。
- **验证状态**：官方接口；[本项目 0.3.4 验证记录](../history/release-0.3.4-validation.md)在独立目录安装并启动 AVD，另有端口共存测试脚本；尚非已验证完整的多实例生命周期管理实现。

### T2. 快照和并行隔离

- **来源**：[Emulator release notes：28.0.16 多实例](https://developer.android.com/studio/releases/emulator)、[Emulator console commands](https://developer.android.com/studio/run/emulator-console)；维护者 Google；类型：官方历史发布说明和命令参考。
- **适用版本、环境**：`-read-only` 的引用来自 **28.0.16（2018）** 发布说明；迁移到 37.3.4 必须再实测。Windows 原生宿主；构建环境不涉及。
- **解决的问题与结论**：官方历史说明同一 AVD 后续实例可使用 `-read-only`，退出后这些实例的可写数据更改丢弃；可用 `adb -s <serial> emu avd snapshot …` 管理快照。
- **限制**：快照不是通用的镜像升级、可持久实例或容错事务；恢复可能覆盖保存时点后的数据。宿主、Emulator、镜像和图形配置变化后的快照兼容、并发锁和性能均待测。对于可持久并发实例，优先设计独立 AVD/data，而非默认为共享写入安全。
- **验证状态**：历史版本官方说明；本项目新多实例与跨版本快照**待实测**。

### T3. ADB、就绪状态与日志

- **来源**：[Android Debug Bridge](https://developer.android.com/tools/adb)、[Emulator 命令行](https://developer.android.com/studio/run/emulator-commandline)、[网络地址](https://developer.android.com/studio/run/emulator-networking-address)；维护者 Google；类型：官方工具文档。
- **适用版本、环境**：按随运行时固定的 Platform-Tools 版本；Windows 本机宿主，Android 客体。开发机/用户机均可仅用运行所需工具，无需完整 Android Studio。
- **解决的问题与结论**：`adb devices -l` 枚举设备；所有实例操作必须显式 `adb -s <serial>`。ADB 上线不等于系统和目标服务完全就绪，应组合 `sys.boot_completed`、包管理器及被测 Agent 的健康检查并设置超时。收集 Emulator stdout/stderr、版本、启动参数、崩溃日志及必要 `logcat`，注意脱敏。默认访宿主 `10.0.2.2` 是模拟网络约定，不代表远程主机或互联网地址。
- **限制**：不同 SDK 的 ADB server 共享及版本不匹配可能影响本机其他设备，需验证共存策略；日志和抓包可能包含敏感用户信息。模拟 SIM 不等于真实蜂窝网络和短信。
- **验证状态**：官方接口与项目既有隔离测试；完整自动化日志、健康检查及隐私策略**待实现和实测**。

### T4. Appium / UiAutomator2 并发

- **来源**：[Appium UiAutomator2 Driver](https://github.com/appium/appium-uiautomator2-driver)；维护者 Appium；类型：维护者仓库/接口说明。
- **适用版本、环境**：仓库当前说明 driver 5+ 使用 Appium 3，driver 6+ 要求 Android API 26+；服务端可跑 Windows/Linux/macOS；被测 Android 可在本机 Windows Emulator 中。Appium 只是可选自动化工具，并非每个用户运行模拟器的必装依赖。
- **解决的问题与结论**：黑盒测试通过 ADB 和 Android UiAutomator；并发时显式设置 `appium:udid`、独立 `appium:systemPort`，涉及 WebView/视频时还要独立 ChromeDriver/MJPEG 端口。该驱动文档要求 host 配置 Platform-Tools 与 JDK，发布前须固定并测试兼容版本。
- **限制**：Appium 位于自动化层，不负责提供 Android 客体或解决镜像分发；“浏览器可访问”也不能证明本机运行。Android 15、user 构建权限、SELinux、后台策略及并发重置需实际兼容测试。
- **验证状态**：维护者文档；项目自定义镜像 + 指定 Appium/driver 组合**待实测**。

## C. ABI、授权与第三方依赖

### L1. Android NDK ABI

- **来源**：[Android ABIs](https://developer.android.com/ndk/guides/abis)；维护者 Google；类型：官方 NDK 文档。
- **适用版本、环境**：当前 NDK 文档；APK 运行在 Android 客体内，与 Windows 宿主 ABI 必须分别考虑；构建 APP 可在开发者指定环境进行。
- **解决的问题与结论**：`x86_64` 与 `arm64-v8a` 为不同 ABI；含 JNI/native `.so` 的应用应检查 APK 支持的 ABI。纯 Java/Kotlin 不能等同包含 arm64-only 原生库的 APK。
- **限制**：64 位 ARM 不代表 32 位 ARM；项目决定暂不支持 32 位。不同模拟器/镜像的 `ro.product.cpu.abilist*` 声明也不构成执行正确的证明。
- **验证状态**：官方规范；[本项目 0.3.4 验证记录](../history/release-0.3.4-validation.md)中，当前 Google APIs 精简镜像通过一个 ARM64 JNI 测例，**不是**自编 AOSP 全面支持保证。

### L2. AOSP Native Bridge 不是转译器

- **来源**：[AOSP ART libnativebridge README](https://android.googlesource.com/platform/art/+/refs/heads/main/libnativebridge/README.md)；维护者 AOSP；类型：源码随附说明。
- **适用版本、环境**：main 分支会变化，须在所锁定 Android 15 tag 的源码复核接口；桥运行于 Android 客体，宿主本项目为 Windows x86_64，构建在 Linux。
- **解决的问题与结论**：提供加载异架构 native 库的框架接口；该 README 写有 AOSP 不提供实际 native bridge 的说法。但 Android 15 r1 的 [Berberis 源码](https://android.googlesource.com/platform/frameworks/libs/binary_translation/+/refs/tags/android-15.0.0_r1/README.md)明确描述的是 riscv64→x86_64 转译，两份材料的范围或时点存在差异；不能把前一句外推为 AOSP 中不存在任何架构的翻译实现，也不能把 Berberis 的 RISC-V 示例当作 ARM64 支持。
- **限制**：需要单独可获得且合法分发的实现、配套版本和安全更新；不能简单从现有 Google APIs 镜像复制专有文件后推断可再分发，也不能通过只改 ABI 属性伪造支持。
- **验证状态**：AOSP 源码直接说明；自建 64 位转译器的可用性/许可证/APP 覆盖**待确认**。

### L2b. Android 15 r1 Berberis 架构范围

- **来源**：[Android 15 r1 Berberis README](https://android.googlesource.com/platform/frameworks/libs/binary_translation/+/refs/tags/android-15.0.0_r1/README.md)、[r1 Goldfish riscv64 产品配置](https://android.googlesource.com/device/generic/goldfish/+/refs/tags/android-15.0.0_r1/64bitonly/product/sdk_phone64_x86_64_riscv64.mk)；维护者 Google/AOSP；类型：固定 tag 官方源码。
- **适用版本、环境**：Android 15 r1；构建环境 AOSP/Linux；源码描述 x86_64 设备或模拟器承载 riscv64 原生应用，不是本次 Windows 发布能力验证。
- **解决的问题与结论**：说明官方源码中确有特定架构的动态翻译项目，并与 L2 的宽泛表述形成范围差异；该 README 只证明所述 RISC-V 方向，不能证明 ARM64 APP 可以运行。
- **限制**：具体默认目标是否包含何种模块、转译效果、源码/依赖许可与 Windows 完整产品兼容均需另行核查；不能推论成用户需要的 ARM64 翻译器已可用。
- **验证状态**：固定 tag 源码已核查；未编译或运行。

### L3. SDK 许可与当前包的具体依据

- **来源**：[Android SDK License Agreement，3.1、3.4、3.5、3.7](https://developer.android.com/studio/terms)；维护者 Google；类型：官方许可条款；本项目本地 [`Android-Emulator-Preview-License.txt`](../../stage/licenses/Android-Emulator-Preview-License.txt)、`stage/sdk/emulator/package.xml`、`stage/sdk/emulator/NOTICE.csv`。
- **适用版本、环境**：SDK 通用条款按接受时版本核查；本机实际包为 Emulator 37.3.4，包元数据引用 `android-sdk-preview-license`；分发面向 Windows 最终用户，开发端构建可在 Linux。
- **解决的问题与结论**：通用 SDK 条款 3.4 对复制、修改和再分发有限制，3.5 对开源许可组件另适用其开源许可。本机包的 `package.xml` 内嵌预览协议：3.1 将其授权用途限定为个人或组织内部的 Android 应用开发，3.3 限制复制、修改、再分发以及分发包含预览部分的软件，3.5 对开源许可组件另按其开源许可处理；需结合实际打包组成和具体协议做分发审查。`stage/sdk/` 和本地许可文件可能不随 Git 检出，应以实际准备发行的 SDK 包自身元数据和许可证为准。本地 `NOTICE.csv` 给出依赖映射，如 Qt GUI 标为 LGPL-3.0-only，gfxstream 标为 Apache-2.0；说明宿主发行物包含多组件，不可仅凭顶层 Apache 文件一概判定。
- **限制**：不因“内部使用”自动证明有再分发权，也不因条款限制得出每个文件都不可分发的武断结论。需要依赖清单/SBOM、确切版本和各许可证、源码提供/修改交付与 NOTICE 义务、二进制再分发权、商标和必要书面授权的专业审核；具体义务逐组件判定。
- **验证状态**：官方条款及本地包元数据已读；本项目实际发布授权及义务履行**未确认**，属于分发前阻塞项。

### L4. Google APIs、GMS、Play 和商标

- **来源**：[AOSP overview](https://source.android.com/docs/setup/about)、[Android Compatibility FAQ](https://source.android.com/docs/compatibility/compatibility-faq)；维护者 Google/AOSP；类型：官方兼容性和许可说明。
- **适用版本、环境**：官方当前项目政策；自编 Android 系统及最终用户 Windows 软件；镜像构建于 Linux。
- **解决的问题与结论**：AOSP、Google APIs、GMS 和 Play 商店是不同范围；没有 Play 商店不等于没有专有 Google 服务或许可要求。Android 兼容和 CTS 与获得 Google Play/GMS 许可不是同一回事，需要相应授权和资格确认。
- **限制**：自编纯 AOSP 不自动获得 GMS、Google API/Play Services、地图及 Play；部分应用依赖这些服务，应按依赖测试与披露，而不是承诺可登录或播放。Google 标志和 Android 商标另需核查使用条件。
- **验证状态**：官方说明；目前项目 Google APIs 镜像和 GMS 的用户端分发权及替代方案**待确认**。

### L5. 开源项目许可不等于分发包的整体许可

- **来源**：[AOSP licenses](https://source.android.com/docs/setup/contribute/licenses)、[Android Emulator QEMU 源码](https://android.googlesource.com/platform/external/qemu/+/refs/heads/emu-master-dev/)；维护者 AOSP；类型：官方许可政策与源码。
- **适用版本、环境**：按具体源码提交及实际链接/打包的依赖确定；Windows 主程序和 Android 客体分别建立物料清单，Linux 为编译环境。
- **解决的问题与结论**：先确认每个文件/依赖的来源及许可，再分别处理 Apache、BSD、GPL、LGPL 等条件；保留版权及许可证通知，识别源码提供、可替换库、修改说明等**可能**义务。
- **限制**：仓库开源不自动覆盖 SDK 打包中的非开源依赖、图像、驱动、编解码器和商业 App；是否能从源码构建可分发的 Windows 版本及对应构建链，须实验和授权审核。
- **验证状态**：官方源码可查；本项目分发物逐组件许可证审计与复现构建**未完成**。

## D. 其他项目和运行环境对比

以下条目均有独立来源，Windows 能否打开页面或发 ADB 命令不代表 Android 运行在 Windows 本机。

| 方案 | 系统/产物构建环境 | Android 实际运行位置 | 是否直接符合最终用户 Windows 本机边界 | 可借鉴内容 |
| --- | --- | --- | --- | --- |
| 本项目拟采用：Windows Emulator + Goldfish | 自定义 AOSP 在 Linux 构建 | 用户 Windows x86_64 上的 Emulator 进程及其 Android 客体 | 技术路线有官方基础；完整交付和许可待验证 | 官方 AVD 接口、系统定制、自动化 |
| Cuttlefish | Linux | Linux + KVM 客体，可远程连接 | 否 | AOSP 测试、实例磁盘隔离 |
| ReDroid | 参考项目的 Linux 构建流程 | Linux 内核容器 | 否 | 容器隔离、测试服务 |
| Google emulator-container-scripts | Linux/Docker | Linux Docker + KVM 的 Emulator | 否 | ADB 桥、镜像与实例管理 |
| Docker-Android | 参考项目的 Linux/Docker 流程 | Linux Docker/KVM；Windows 常通过 VM 或 WSL2 | 否 | UI 自动化、测试录屏 |
| Android-x86 | Linux | 裸机，或 Windows 原生 VirtualBox/QEMU 等虚拟机中的 Android 客体 | Windows 原生 VMM + Android 客体原则上可满足本机约束；完整产品方案待验证，非当前主线 | x86 移植经验 |

表中“否”只针对本项目的终端运行约束，不否认这些项目适合 Linux 开发或其他用途。用户不接受中间 Linux 宿主虚拟机，并不禁止 Windows 原生虚拟化程序运行 Android 客体。雷电模拟器是另一类 Windows 商业成品，其镜像裁剪及许可证不能通过上述开源项目推断。

### P1. Cuttlefish

- **来源**：[Cuttlefish overview](https://source.android.com/docs/devices/cuttlefish)、[Get started](https://source.android.com/docs/devices/cuttlefish/get-started)、[Multi-tenancy](https://source.android.com/docs/devices/cuttlefish/multi-tenancy)；维护者 Google/AOSP；类型：官方平台文档。
- **适用版本、环境**：页面当前示例 `aosp_cf_x86_64_only_phone`；构建 Linux，官方示例运行于有 KVM、Debian 包和宿主服务的 Linux 机器或 Linux 云环境，浏览器可能是 Windows 客户端。
- **解决的问题与结论**：用于 AOSP 平台研发、虚拟设备与多实例；可借鉴产品定制、镜像构建、日志、实例和状态设计。
- **限制**：官方描述的该方案不是 Windows 本机 Emulator/QEMU 交付；不得直接把 `aosp_cf_*` 镜像当 Goldfish AVD 镜像。文档的 KVM/`apt`/`dpkg` 运行步骤不应用于最终用户。
- **验证状态**：官方所列部署；本项目仅作为参考，不作为直接产品交付。

### P2. ReDroid

- **来源**：[remote-android/redroid-doc](https://github.com/remote-android/redroid-doc)；维护者 ReDroid 项目；类型：维护者仓库。
- **适用版本、环境**：当前项目列出 Android 8.1–16 版本，示例使用 Android 12；运行在 Linux 内核上的 Docker/Podman/Kubernetes 等容器，构建见该仓库，不是 Windows 原生运行。
- **解决的问题与结论**：可借鉴 Android 系统服务裁剪、容器实例隔离、Android 自动化及 GPU 映射；可进行 Linux 开发侧实验。
- **限制**：依赖 Linux binder 等内核能力；Windows 通过 Docker、WSL 或 Linux 远程访问不符合本项目最终用户的本机 Windows 运行边界。网络暴露 ADB 会引入权限风险。
- **验证状态**：维护者文档；未测试与 Windows 交付的兼容，也不应把其镜像直接当作 Emulator 镜像。

### P3. Google android-emulator-container-scripts

- **来源**：[android-emulator-container-scripts](https://github.com/google/android-emulator-container-scripts)；维护者 Google；类型：维护者实验性脚本仓库。
- **适用版本、环境**：仓库当前要求 Linux、Docker 和 `/dev/kvm` 等；官方明确 Windows/macOS Docker Desktop 不支持 KVM 加速。Python、构建/容器依赖为开发侧方案。
- **解决的问题与结论**：可学习镜像组成、容器化测试、ADB 桥和日志；Windows 客户端可以连接 Linux 上的 Android，但运行仍在 Linux。
- **限制**：不满足无需 WSL/VM/远端 Linux 的最终用户 Windows 原生交付；容器能运行也不授予镜像与 SDK 无限再分发权。
- **验证状态**：官方维护者说明；仅作参考。

### P4. Docker-Android

- **来源**：[budtmo/docker-android](https://github.com/budtmo/docker-android)；维护者 budtmo 社区项目；类型：维护者仓库。
- **适用版本、环境**：仓库示例 Android 11，说明 Windows/macOS 需 Linux VM，也提供 Windows 11 WSL2 + nested KVM 操作说明；Android 实际运行在 Linux 容器/VM。
- **解决的问题与结论**：可借鉴测试服务、视频录制、设备状态、持久化及自动化配置；网页/noVNC 是客户端呈现方式。
- **限制**：Linux VM/WSL2 都与本项目最终用户约束相冲突；旧版本示例不能直接推为 Android 15 产品方案。
- **验证状态**：维护者文档；仅作为开发和测试经验参考。

### P5. Android-x86

- **来源**：[Android-x86 Get Source](https://www.android-x86.org/source.html)、[VirtualBox HowTo](https://www.android-x86.org/documentation/virtualbox.html)；维护者 Android-x86 社区；类型：维护者文档。
- **适用版本、环境**：所引源码页面列出最高 Android 11 的 `r-x86` 分支；VirtualBox 示例为 Android 6 / Windows 10 / VirtualBox 5.2 的历史测试。构建 Linux；可裸机引导，也可运行在 VirtualBox/QEMU 等 VM 中。
- **解决的问题与结论**：可借鉴 x86 硬件适配与历史移植经验；它是 Android 系统移植项目，**不是** Windows 原生模拟器本身。如果采用在 Windows 原生运行的 VirtualBox/QEMU，再让它直接启动 Android-x86 客体，原则上可以在 Windows 本机运行，不必引入中间 Linux 宿主虚拟机。
- **限制**：裸机/双启动取代当前 Windows 会话；Windows 原生 VMM 路线仍需解决 VMM/驱动及安装权限和重启、图形、手机功能、更新、Android 版本与分发授权，不能从历史例子直接推断 Android 15 或产品兼容。这条路线不同于优先研究的 Android Emulator + Goldfish。
- **验证状态**：社区历史文档；Android-x86 + Windows 原生 VMM 的本项目完整交付**待实测**，不应一概判定违反边界，也不作为当前主线。

## E. 本项目后续验证清单

1. 固定 Windows Emulator 实际二进制版本、完整清单、依赖与许可；首次运行区分 CPU 虚拟化未开、WHPX 未启用、系统待重启和 GPU 不可用。测试 Windows 10/11、Home/Pro、受管用户、集显/独显/软件渲染与低端机器。
2. 按每个 AVD 分配独立数据/身份/端口，并检查与真实手机、其他模拟器及已有 ADB server 共存；管理层需要明确重置、快照与卸载时对用户数据的操作。
3. 在 Linux 生成匹配的自定义 Goldfish 镜像完整产物及元数据后，复制到干净 Windows 机器，固定版本加载；依次验证冷启动、关闭重开数据保留、用户 UI、无窗口、ADB/Appium、网络、媒体、日志和异常恢复。
4. 明确 ARM64 翻译和 GMS 的独立授权与兼容性结论；AOSP 验证机可先使用 x86_64 原生测试 APK。正式承诺 arm64-only APP 之前必须拿到可分发的翻译实现并跑代表性测试集。
5. 逐文件审核 SDK/驱动/GUI/编解码器/镜像/翻译器/第三方 APK 的许可和发布流程；无明确授权前不应宣称可以分发。本资料不把已有内部安装包视为满足全部对外授权。
