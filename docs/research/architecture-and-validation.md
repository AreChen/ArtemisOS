# 架构、交付物与最小验证路线

研究日期：2026-10-31。本文是一份供后续实现与排障使用的方案，不是已完成的开发计划。本轮没有下载或编译整套 AOSP，也没有修改现有模拟器程序。

## 四层架构与职责

| 层 | 拟选择和职责 | 产物及依赖 | 需要证明什么 |
| --- | --- | --- | --- |
| Android 系统镜像 | 以固定 Android 15 tag 的 AOSP Goldfish `sdk_phone64_x86_64` 为基线，后续通过独立产品配置继承并定制 | Linux 构建并打包配套的内核、ramdisk、system/vendor 等完整镜像、元数据、构建清单及许可记录；内核可为预编译产物 | 干净镜像可启动；简中、UTC+8、测试组件、网络、APP、SELinux 等修改可重建 |
| Windows 模拟器运行时 | Windows x86_64 Android Emulator/QEMU 加载 Android 客体；优先 WHPX 和自动图形后端，提供软件图形选项 | 经过版本配对和许可核查的 Windows Emulator 程序、其 QEMU 后端、DLL、图形/媒体依赖 | Windows 10/11 实际兼容、CPU 加速、无独显或软件渲染、崩溃恢复；不是只在开发机启动一次 |
| 交付与管理 | 安装、首次检查、创建和启动实例、配置、更新、日志、卸载和恢复 | Windows 安装器、启动/配置器、受控更新程序、版本/内容清单、AVD 元数据、许可通知及用户数据目录 | 不安装 Android Studio，也无需最终用户安装或配置 Linux/WSL/Docker；干净系统可用并保护原有数据 |
| 自动化测试 | ADB 和可选的 Appium/UiAutomator2，管理实例生命周期和结果 | 匹配版本的 Platform-Tools、可选测试 Agent/自动化服务、各实例的端口及状态目录 | 并行设备不串线，应用安装、就绪、日志、失败恢复和结果归档可自动完成 |

Android 客体本身使用 Android/Linux 内核，是 Android 的组成部分；它运行在本机 Windows Emulator 内，并不是要求用户另装 WSL、Linux 桌面或一个远程 Linux 服务。开发团队可以在 Linux 或开发机 WSL 构建，**构建环境不会被打包成用户侧运行依赖**。

## 首选版本与适配边界

- **系统**：保持 Android 15/API 35 为首个测试基线，原因是现有项目已经基于 Android 15，而不是因为它天然最快。示例研究使用 `android-15.0.0_r1` 以便检查固定源码；该 tag 不是最新安全更新的承诺。真正实施应另选明确维护状态的 Android 15 tag，锁定 manifest、提交、构建工具和安全补丁基线。
- **产品目标**：固定 tag 的源码注册 `sdk_phone64_x86_64`；`sdk_slim_x86_64` 可作为精简研究对象。Android 官方 AVD 页面和 Android 15 r1 在目标名称、`lunch` 参数、打包文件名上存在差异；可复现命令和继承关系见 [AOSP 构建与系统定制](aosp-build-and-customization.md)。不要把 Cuttlefish 的 `aosp_cf_*` 当作 Goldfish 目标。
- **Windows**：计划优先验证 x86_64 Windows 10 1803 及以上和 Windows 11；1803 是 [WHPX 官方技术下限](https://developer.android.com/studio/run/emulator-acceleration)，不是本产品已确认的最低支持版本。处理器应支持并在固件中启用 Intel VT-x/EPT/Unrestricted Guest 或 AMD-V/SVM 等；启用 Windows 可选功能通常需管理员权限，可能需要重启，BIOS/UEFI 设置取决于设备。Windows Home/Pro、企业策略、内存和磁盘要求须由产品矩阵实测。
- **CPU 与图形分开**：WHPX 是客体 CPU 虚拟化；有无独立显卡不是同一问题。没有独显时先检查集显；没有可用硬件图形时尝试 Emulator 支持的软件图形后端，并测试功能与负载。软件图形仍需足够的 CPU、内存，不能保证低配电脑流畅，也不能把关闭 CPU 虚拟化当作等价方案。
- **ABI 与 Google 服务**：首期不要求 32 位应用，但产品兼容目标仍需覆盖用户关心的 `arm64-v8a` 应用。native bridge 框架接口本身不是 ARM64 转译器；本次核查的 Android 15 r1 默认目标尚未证实具备 ARM64→x86_64 实现，功能、适配、安全维护和合法分发都必须单独解决。AOSP 的其他架构转译实验不等于 ARM64 可用，详见 [Native Bridge 条目](windows-runtime-delivery-and-testing.md#l2-aosp-native-bridge-不是转译器)。初始 POC 可用 `x86_64` 测试 APK，不代表可以直接发布为 ARM64 兼容产品。Google APIs、GMS 和 Play 商店分开判定，现有 Google 镜像能力不自动属于自编 AOSP。
- **设备画像**：保留 720p 作为默认，提供更高分辨率及显示密度预设；型号名称、分辨率、CPU 和运营商信息可作为测试配置研究。切换显示名称不会改变 API 等级；Android 14、16 等覆盖必须有各自对应的系统镜像。NFC、计步、电话或 SIM 特性只有在具体能力可工作时才宣称支持；模拟运营商也不等同真实蜂窝网络或短信。设备属性变化与应用兼容、OTA 指纹和测试可复现性需一起验证。

## 实际交付时必须锁定的文件和关系

1. **独立的 Windows 宿主包**：Emulator 主程序、对应 Windows x86_64 QEMU 及实际加载的 DLL/图形后端、ADB 和其他必要依赖；记录来源、版本、散列、许可证和通知。不要依据文件名任意删库；分别测试自动、硬件和软件图形路径。ADB 进程与用户已有设备/模拟器共存。
2. **完整且同源的镜像包**：用所选 Goldfish tag 的打包目标生成其指定的 `system.img`、`vendor.img`、ramdisk、配套内核、初始化 data 内容等实际产物和 `advancedFeatures.ini`、`source.properties` 等元数据；所选版本是否还需 `userdata.img` 或其他文件，以该版本打包规则和运行时实测为准。Android 15 r1 示例默认引用预编译内核，需记录来源和哈希；自定义内核要单独构建并配套模块。动态分区可能改变文件和映射关系，不能拿不同版本的 system、vendor、内核只凭文件名拼接。
3. **实例配置与用户数据**：AVD 指向已知镜像版本；每个实例独立配置、userdata、缓存、快照和唯一端口。共享基础镜像的模式必须验证并发锁及读写语义；更新时快照、userdata 和镜像的兼容关系须写入管理策略。卸载或重置时明确哪些文件属于用户数据。
4. **发布清单**：建立源码 tag/manifest、构建目标和变体、镜像文件哈希、Emulator/ADB/依赖版本、ABI 能力、许可证、签名、已验证 Windows 版本及已知问题的清单。安装包下载字节、解压峰值、安装后的逻辑大小与 NTFS 实际分配大小分开记录。
5. **发布权限**：当前 37.3.4 Emulator 包元数据引用 Preview 许可；当前 Google APIs 镜像、GMS、ARM 转译和第三方库需分别审查。请依据 [Windows 运行与许可条目](windows-runtime-delivery-and-testing.md) 的本地元数据及官方来源确定权限；源码公开或在内部使用都不自动构成整个二进制包的再分发许可。

## 最小验证路线与进入下一阶段的条件

以下全部是后续工作建议，本轮不执行下载或编译。

| 阶段 | 操作范围 | 最小通过条件与需要留存的证据 |
| --- | --- | --- |
| 0. 固定基线 | 选已授权的 Windows Emulator、Android 15 Goldfish tag、Windows CPU/GPU/OS 测试矩阵和测试 APK | 保存版本、来源、哈希、许可清单；确定无 32 位要求、ARM64 与 GMS 的明确准入标准；不得将许可不明视为已经获得分发权 |
| 1. 未修改镜像 | 开发环境构建或取得配套的原始 Goldfish 镜像包，复制到 Windows 测试机；不需要改系统内容 | 在 Windows 本地完成首次冷启动、关闭再启动；记录运行时/内核/镜像组合、AVD 配置、启动日志、数据持久化；无 Android Studio 和 WSL 运行依赖 |
| 2. 自定义镜像 | 在固定产品配置中做少量可追溯修改，例如显示名称、默认语言/时区、合法的测试 Agent；从源码重新构建 | 重新构建的产物可重复得到相同配置并启动；简中、UTC+8、测试 Agent 和权限符合预期；保留来源、改动和签名记录；不要依赖临时 `adb remount` 修改 |
| 3. 自动化与隔离 | 添加实例控制、ADB 定向访问、测试应用、无窗口和可选 Appium | 至少两个实例具有独立 data/端口/身份；就绪时同时满足 ADB、系统启动、包管理和 Agent 检查；重启后数据保留，日志能定位失败；不干扰本机真机/其他模拟器 |
| 4. 普通用户安装 | 在没有 Android Studio、WSL、Docker 的干净 Windows Intel 和 AMD 机器上安装；测试有/无可用 GPU 及权限场景 | 离线安装和首次依赖提示正确；WHPX 启用及需要提权/重启时说明清楚；装、开、关、重启、卸载与保留用户数据均达到预期；记录实际最低 OS 和硬件范围 |
| 5. 兼容与优化 | 对比原始与定制系统包、ABI、图形和自动化功能；在低配笔记本测量 | 代表性 x86_64/ARM64 APK、WebView、网络、媒体、界面操作和测试工具按目标通过；量化安装包、落盘、启动、内存与 CPU；任何未实现能力在发布说明里标明 |
| 6. 更新与恢复 | 先实验宿主镜像更新和差分，再决定是否攻克 Android 原生 OTA | 覆盖精简/完整双基线、失败重试、断电、磁盘不足、并发实例、快照和回滚；只有真正的 guest 分区更新完成并验证才能宣称系统 OTA；详见 [OTA 研究](system-ota-and-release.md) |

发行与技术两个门禁并行：阶段 1 的内部开发验证不等于获得最终用户分发授权；阶段 4 完成安装体验也不代替组件授权、ARM64 或功能兼容性审核。

迁移当前功能时应建立回归清单：简体中文和 `Asia/Shanghai` 首启与重启、Wi-Fi 默认连接和不同宿主网络下的 DNS、移动/电信/联通的模拟资料、720/900/1080p 及自动/软件渲染、可见版本号与无终端启动、APP 安装及视频/WebView、既有用户数据和配置升级。固定某台开发机的路由器地址不能当作所有用户的 DNS 配置；应验证断网、换网络和重启恢复。此前项目中的具体功能与历史证据见 [0.3.4 验证记录](../history/release-0.3.4-validation.md)；自编镜像要重新执行这些验证。

## 精简和性能验证方法

优先按使用场景核对实际系统包和后台服务，逐项判断依赖，再用产品配置、资源覆盖及模块依赖构建可复现镜像。可研究 Android 测试设备目标，但官方 ATD 示例的裁剪可能去掉图形界面、系统 UI、电话或相机；这不一定满足本产品的交互式应用测试。详细版本差异与证据见 [AOSP 构建资料](aosp-build-and-customization.md)。

候选优化包括：从自建镜像排除未使用预装 APP、避免不必要的后台服务、配置和验证分区布局、压缩发行包、减少多实例重复文件。删除分区内文件不一定缩小固定容量镜像的逻辑长度；稀疏/动态容器的逻辑容量、宿主实际分配大小及安装包压缩字节是不同指标。不得照搬雷电专有文件，差异参考见 [雷电本地观察](ldplayer-local-comparison.md)。

实验要在同一 Windows 实体机、相同 CPU 核数、RAM、显示尺寸/dpi、后端、运行状态和测试 APK 下进行，分别覆盖 Intel/AMD、低内存笔记本、集显与软件渲染。记录每次冷/热启动及 APP 启动时间、空闲和负载时 CPU、宿主进程实际内存及峰值、磁盘 IO、图形流畅度/失败情况，并报告样本数、分布与失败；另计安装包字节、解压峰值、安装后实际磁盘、用户数据增长。不同 Android API 级别和不同商业模拟器实现是混杂因素，结果不能简单归因给某一个开关。

## 已知问题和排障入口

| 现象 | 先区分的层与证据 | 下一步方向 |
| --- | --- | --- |
| 无法创建虚拟设备或启动很慢 | Windows 版 Emulator 版本、`-accel-check`、BIOS/UEFI、WHPX 与待重启状态 | CPU 虚拟化优先；软件图形不解决缺少虚拟化 |
| 黑屏、崩溃、低帧率 | 运行时版本、GPU/驱动、auto/host/software 后端、分辨率与日志 | 同版本按后端复现；不要把所有问题归因于 Android 镜像 |
| `init`、挂载、vendor 或 bootloop | 完整产物来自哪个 tag、内核/ramdisk/vendor/system/元数据是否同源 | 查看 Emulator 日志、早期串口和 Android logcat；从未修改包回退，避免混拼 |
| APK 安装/启动失败 | APK ABI、应用依赖、目标 API、GMS/Play、传感器/权限、logcat | `x86_64` 与 ARM64 分开诊断；检查是否存在可用 native bridge，不能只改 ABI 声明 |
| 网络登录异常 | Android 时区/时间、DNS、连通性、代理、APP 日志与服务端错误 | 控制网络测试与日志脱敏；模拟 SIM 不提供真实短信或运营商身份 |
| 并发串设备、数据丢失 | 实例 ID、ADB serial、端口、data 目录、快照及更新版本 | 逐实例复现并核对锁和持久化，不应无差别清理全部 AVD 或重启用户的 ADB server |
| OTA 失败或恢复后版本不一致 | 分清宿主文件更新或 Android OTA，查镜像/manifest 哈希、分区、引导槽及日志 | 先保护和备份数据；按对应方案回滚。Goldfish r1 默认不是 A/B OTA 基线 |

这些排障建议的上游来源和验证状态分别记录在 [AOSP 条目](aosp-build-and-customization.md)、[Windows 与自动化条目](windows-runtime-delivery-and-testing.md)和 [OTA 条目](system-ota-and-release.md)。
