# ArtemisOS 技术资料库索引

**研究主题**：面向最终用户分发的 Windows 原生 Android 模拟器；自主构建、可维护的 Android 系统镜像；以 APP 和自动化测试为主要场景。

**核查日期**：2026-10-31。**工作性质**：资料整理、固定版本源码审阅，以及本机文件和模拟器系统包观察；本次没有下载整套 AOSP、编译镜像或实现产品。下文的建议和阶段均不是已经完成的工程。

## 从这里开始

| 文档 | 能回答的问题 |
| --- | --- |
| [架构、交付物与最小验证路线](architecture-and-validation.md) | 运行时如何选，四层分别做什么，交付哪些文件，用户依赖什么，如何一步步验证和排障。 |
| [AOSP 构建与系统定制](aosp-build-and-customization.md) | 固定 Android 15 tag 应选择哪个 Goldfish 产品，文档与源码有何差异，镜像如何配套打包，如何做可重建定制。 |
| [Windows 运行时、交付、自动化与许可](windows-runtime-delivery-and-testing.md) | WHPX、图形后端、Windows 版本、ADB/Appium、多实例、ABI、授权及替代方案的证据和限制。 |
| [系统 OTA 与发布](system-ota-and-release.md) | 区分宿主组件更新、宿主镜像更新和 Android 原生 OTA，了解 Goldfish 当前源码限制、签名及失败恢复。 |
| [雷电 14 本地对比](ldplayer-local-comparison.md) | 安装包和磁盘镜像实际测量、动态 VDI 的含义、当前能观察的差异、不能推断的删减清单及可复测方法。 |

各专题的来源条目分别记录标题、链接、维护者、类型、版本/分支、构建与运行环境、问题、结论、限制和验证状态。项目历史与本轮资料应区分：历史验证也只适用于当时的版本、测试应用和那台机器。

## 一眼看懂目前的结论

1. **建议主线**：用户在 Windows x86_64 本机运行 Android Emulator/QEMU 和 Android 客体；开发团队在 Linux 构建 Goldfish 镜像，再以我们自己的安装器、启动器与自动化接口交付。无需用户安装 Linux、WSL2、Docker、Linux 虚拟机或连接远程 Linux 才能运行；也不要求完整 Android Studio。Android 客体本身使用 Linux 内核不等于需要额外安装 Linux 宿主。
2. **固定版本核查，而不是照抄当前文档**：Android 15 r1 的 Goldfish 源码注册 `sdk_phone64_x86_64`，当前 AVD 指南中的旧目标、`lunch` 参数及压缩包名称与该 tag 不同。`android-15.0.0_r1` 只是本次可核对的历史示例，正式基线需要另选安全更新适宜的 tag；实际构建和 Windows 启动均待验证。
3. **可能做自己的镜像，但 ARM64 和许可是门槛**：native bridge 接口本身不等于 ARM64 转译器；本次核查的 Android 15 r1 `sdk_phone64_x86_64` 尚未证实包含可用的 ARM64→x86_64 转译实现。当前 Google APIs 镜像中的 ARM64 转译不能假定允许复制到新镜像或再分发。首期用户不要求 32 位，但应分别验证 `x86_64`、ARM64 APP、GMS 依赖和所有组件分发条件。现有镜像虽有一个 ARM64 JNI 测例通过，不代表所有 APP 或自编镜像都通过。
4. **雷电更小有真实数据，原因还不能全归因**：本机安装包雷电约 710 MiB，ArtemisOS 0.3.4 精简包约 1,491 MiB。雷电的系统文件是动态分配 VDI，ArtemisOS 使用不同格式的系统镜像；两者 Android 版本和发行内容也不同。本轮分别读到雷电现有实例 96 个、ArtemisOS 现有实例 241 个系统包名，包含资源覆盖和后台组件；当前 ArtemisOS 实例仍含 Gmail 等应用，不是全新精简安装。清单展示的是当前差异，不能证明各自从什么基线删除了组件，也不能用包名数量代表体积或性能。
5. **系统 OTA 可以作为独立研发目标，默认并没有**：Android 15 r1 的 `sdk_phone64_x86_64` 继承链明确设置 `AB_OTA_UPDATER := false`，其 x86_64 配置注释不支持 OTA。现有原型由 Windows 替换变化文件，不是 Android `update_engine` 分区 OTA，也没有大文件二进制差分。建议先验证宿主镜像的安全更新与回滚，再攻关真正的客体 OTA。
6. **低配和无独显要分别测**：CPU 虚拟化与图形加速是两回事。优先检测 WHPX 和可用 GPU；无独显可使用集显，没有可用硬件图形时可尝试软件渲染，但需在真实低配设备上测启动、APP 行为、CPU 和内存，不保证一定流畅。
7. **设备画像按测试需要设计**：保留 720p 默认、增加更高分辨率与密度预设；以 Android 15 为当前基线，按测试需要增加 Android 14/16 等版本的独立镜像。改变型号名称或分辨率不等于切换 Android 版本、增加真实传感器或获得运营商网络能力。

## 现有方案与可借鉴范围

| 项目或路线 | 构建环境 | Android 实际运行位置 | 对 Windows 本机交付的判断 |
| --- | --- | --- | --- |
| Windows Android Emulator + Goldfish | 系统镜像在 Linux 构建 | 用户 Windows 上的原生 Emulator 进程及 Android 客体 | **首选验证**；完整打包、兼容性与分发权待确认 |
| 雷电模拟器 14 | 厂商私有构建流程未知 | Windows 本机的商业模拟器 | 可以比较用户体验、参数和可观察行为；不能推断或复用其专有代码、镜像及翻译组件 |
| Cuttlefish | Linux | 官方部署说明中的 Linux/KVM 环境 | 不满足本项目最终用户边界；借鉴构建、自动化与实例隔离 |
| ReDroid | 项目对应的 Linux 构建流程 | Linux 内核容器 | 不满足最终用户边界；借鉴容器化测试和管理经验 |
| Google emulator-container-scripts | Linux/Docker | Linux Docker + KVM 的 Emulator | 不满足最终用户边界；借鉴测试、ADB 桥和服务脚本 |
| Docker-Android | Linux/Docker | Linux 容器，Windows 示例需 VM 或 WSL2 | 不满足最终用户边界；借鉴自动化和监控思路 |
| Android-x86 | Linux | 裸机，或 Windows 原生 VirtualBox/QEMU 中的 Android 客体 | Windows 原生 VMM + Android 客体原则上可本机运行；需另行解决版本、驱动、图形、权限和授权，不是当前首选 |

各方案的具体来源、分支、运行约束和验证状态见 [现有项目对比及资料条目](windows-runtime-delivery-and-testing.md#d-其他项目和运行环境对比)。Windows 能打开某个网页或连接 ADB，并不证明 Android 是在 Windows 本机运行。

## 资料可信度与后续维护

- **官方支持**：仅表示官方文档或源码对其所述版本、条件和功能提供依据；并不自动覆盖我们的整体产品。
- **社区实践**：维护者或社区描述的方案，按其具体环境和版本使用，不扩展为官方承诺。
- **依据源码推断**：说明了固定 tag 与继承路径，但没有实际编译或端到端运行；需要实测复核。
- **待实测/待确认**：当前没有足够的运行或授权证据，不能写成已具备的能力。

新资料应注明调查日期、准确 tag/commit 或文档版本、构建环境、最终运行环境、主张范围、来源和复现结果。上游网页、`main` 分支、许可文本和产品版本可能变化；正式决策前重新核对。尤其不要把安装包体积、安装后实际磁盘占用、虚拟磁盘容量和运行内存混作同一指标。
