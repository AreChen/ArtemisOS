# Android 15 Goldfish 镜像构建与定制资料

调查日期：2026-10-31。范围：Windows x86_64 本地 Android Emulator + 团队在 Linux 上构建的 Android 镜像；本文只做源码和官方资料核对，没有下载完整 AOSP、编译、启动自制镜像或执行产品实现。

## 可供架构设计直接使用的结论

1. 可优先验证 **Google Android Emulator Windows 运行时 + AOSP Goldfish 自定义镜像**。官方有 AVD 镜像构建与分享指南；能否用拟分发的 Windows 运行时加载我们构建的完整镜像集、具体性能和再分发权利，都还需要逐项验证。Windows 用户不需要为了运行产品安装 WSL 或 AOSP 编译工具；团队编译环境与最终运行环境是两回事。
2. Android 15 基线应固定 manifest tag 和各仓库实际版本，再从 Goldfish 产品配置选目标。`android-15.0.0_r1` 是下文可复核的**历史源码示例，不代表最新安全补丁**。本次固定 tag 中，适合先研究的交互式目标是 `sdk_phone64_x86_64`；自动化精简实验可比较 `sdk_slim_x86_64`，但后者明确以 FakeSystemApp 替代核心界面，不能先假设适合普通用户。
3. 官方 AVD 指南里的旧目标名称、`lunch` 参数和 ZIP 名称与本次固定 tag 源码有差异；应以选定 tag 的源码为准。尤其 `system-qemu.img` 打包后才叫 `system.img`，不能只靠文件名把不同构建的 system、vendor、ramdisk、内核拼起来。
4. Android 15 r1 的 `sdk_phone64_x86_64` 默认板级配置为 **Non-A/B、`AB_OTA_UPDATER := false`**；其内核配置源码还明确注释该模拟器不支持 OTA。不能因为支持动态分区就断言支持系统 OTA。其他版本或定制板级配置必须重新验证。
5. 64 位 x86 Android 并不自动包含 ARM64 指令转译。先检查目标系统映像的实际 ABI、native bridge 实现与其授权，验证真实 ARM64 APK；用户暂不要求 32 位支持，不能因此宣称 ARM64 APK 一定兼容。

### 开发环境与交付环境

| 项目 | 团队构建环境 | 最终用户运行环境 |
|---|---|---|
| 任务 | 拉取固定源码、构建 Goldfish 系统镜像并生成构建物、许可证和来源清单 | 本机运行 Windows Emulator、虚拟化后端、镜像和我们的启动/安装程序 |
| 环境 | 以官方支持的 64 位 x86 Linux 为基线；团队可另行验证 WSL2 的构建与性能 | Windows x86_64；Windows ARM 不默认支持；不要求安装 Linux/WSL2/Docker/完整 Android Studio |
| 资源 | 官方入门页当前建议约 400 GB 空闲磁盘和 64 GB 内存，实际按分支和并行度测量 | 以实际 Emulator 版本、CPU 虚拟化、图形后端、Windows 页面文件和磁盘空间测试为准，不套用 AOSP 编译资源要求 |

## 源码入口、资料条目与验证状态

以下“已核对”表示本次阅读了链接处的官方资料或固定 tag 源码，**不表示本机构建或运行成功**。文档为动态页面时注明；将来需重新检查版本。

### A1. AOSP 入门、下载与版本识别

- **链接与维护者**：[Try Android development](https://source.android.com/docs/setup/start)、[Download the Android source](https://source.android.com/docs/setup/download)、[Codenames, tags, and build numbers](https://source.android.com/docs/setup/reference/build-numbers)，Google/AOSP；官方文档与版本表。
- **版本/环境**：当前动态文档；开发侧 64 位 x86 Linux，运行侧另定；版本表涵盖 Android 15。
- **解决问题**：确定开发机能力、同步入口、Android 版本与源码基线。
- **结论**：当前源码下载页使用的 `android-latest-release` 是移动引用，不能当作 Android 15 长期可重现基线。版本表将 `android-15.0.0_r1` 对应 AP3A.240905.015.A2；固定 tag 后还应在实际构建时保存 `repo manifest -r` 和构建元数据。版本选型应考虑较新的 Android 15 安全修补与上游兼容性。
- **限制**：版本表中的设备/构建编号与 Google 官方模拟器镜像 fingerprint 不是一一等价证明；400 GB、64 GB 是文档给开发环境的资源建议，不是 Windows 用户最低规格。**状态：官方文档已核对；项目构建未验证。**

### A2. Android 15 r1 manifest

- **链接与维护者**：[platform/manifest: android-15.0.0_r1](https://android.googlesource.com/platform/manifest/+/refs/tags/android-15.0.0_r1/default.xml)，Google/AOSP；Repo manifest 源码。
- **版本/环境**：`android-15.0.0_r1`；构建 Linux，最终镜像目标待 Windows 运行验证。
- **解决问题**：追踪整套源码组成和可重现性。
- **结论**：manifest 包含 `build/release`、`device/generic/goldfish`、`device/generic/goldfish-opengl`、不同版本虚拟设备内核模块与预编译内核等。应固定完整 manifest 与实际解析后的 revisions，再记录开发环境、构建参数、输出哈希和改动。
- **限制**：这里逐文件只读核查，并未执行 repo sync；不同 tag 包含的依赖和构建组合可能不同。**状态：固定 tag 官方源码已核对，构建未验证。**

### A3. Android Emulator 镜像官方指南

- **链接与维护者**：[Use Android Emulator virtual devices](https://source.android.com/docs/setup/test/avd)，Google/AOSP；官方 AVD 指南。
- **版本/环境**：动态文档；区分 Android 13+ 与 Android 12 及更旧系统的打包命令；示例为 Linux 构建，提供 Android Studio 消费方式。
- **解决问题**：判断官方是否提供自建并分享模拟器镜像的基本路径。
- **结论**：文档描述构建及分享自定义 AVD 镜像，Android 13+ 给出 `make emu_img_zip`；Android 12 及以下给出 `make sdk sdk_repo`。打包目标应在所选分支源码核对。
- **限制**：文档的 `lunch sdk_phone_x86_64` 和 ZIP 名称与 r1 源码不同，见 A4、A6；ZIP 名中的 `linux` 不能单独用来证明 Windows 兼容或不兼容。指南不提供 Windows 产品级安装器、完整再分发许可或自动升级保证。**状态：官方文档已核对；Windows 自制镜像尚未实测。**

### A4. `lunch`、产品目标与 release 配置的版本差异

- **链接与维护者**：[r1 envsetup.sh](https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/envsetup.sh)、[r1 Goldfish AndroidProducts.mk](https://android.googlesource.com/device/generic/goldfish/+/refs/tags/android-15.0.0_r1/AndroidProducts.mk)、[r1 release_configs](https://android.googlesource.com/platform/build/release/+/refs/tags/android-15.0.0_r1/release_configs/)、[Goldfish 测试提交](https://android.googlesource.com/device/generic/goldfish/+/c207ad90f470bbc557a375534b28aaf06e3b36ef%5E%21/)，Google/AOSP；固定 tag 源码与历史提交。
- **版本/环境**：前三个是 Android 15 r1，提交是 2024-01 的特定变更；Linux 构建、Windows 运行待测。
- **解决问题**：避免照搬已过时的 `lunch` 命令。
- **结论**：r1 的 `lunch` 函数明确解析 `<product>-<release>-<variant>`，单项 `lunch sdk_phone_x86_64` 在此 tag 缺少 release 与 variant；同 tag Goldfish 产品列表含 `sdk_phone64_x86_64` 和 `sdk_slim_x86_64`。release 配置目录包含 `ap3a`、`trunk_staging`，但二者配置不同。该历史提交的测试记录使用 `sdk_phone64_x86_64-trunk_staging-userdebug`，可以作为后续调查候选，而不是说此项目已经运行通过。
- **限制**：其他分支可能改变命令与目标；`lunch2` 在该 tag 是另一个函数，接受不同参数形式，不应与 `lunch` 混为一谈。候选三元组实际完整解析、产物及补丁级别还要在完整固定源码树内验证，不能声称 `trunk_staging` 自动等同 AP3A 发布配置。**状态：官方源码核对 + 提交测试记录；本项目待实测。**

### A5. Goldfish 交互式与 ATD 精简目标

- **链接与维护者**：[r1 sdk_phone64_x86_64.mk](https://android.googlesource.com/device/generic/goldfish/+/refs/tags/android-15.0.0_r1/64bitonly/product/sdk_phone64_x86_64.mk)、[r1 sdk_slim_x86_64.mk](https://android.googlesource.com/device/generic/goldfish/+/refs/tags/android-15.0.0_r1/64bitonly/product/sdk_slim_x86_64.mk)、[r1 slim_handheld.mk](https://android.googlesource.com/device/generic/goldfish/+/refs/tags/android-15.0.0_r1/product/slim_handheld.mk)、[r1 slim/vendor.mk](https://android.googlesource.com/device/generic/goldfish/+/refs/tags/android-15.0.0_r1/slim/vendor.mk)、[Automated Test Devices](https://developer.android.com/studio/test/managed-devices#automated-test-devices)，Google/AOSP/Android Developers；产品源码和官方测试文档。
- **版本/环境**：产品源码 Android 15 r1；ATD 文档的 Gradle 示例明确写 API 30，不能当作对 Android 15 通用行为的承诺。Linux 构建，运行平台需验证。
- **解决问题**：为包体和低配性能优化寻找可复制的系统级基线。
- **结论**：`sdk_phone64_x86_64` 使用 `core_64_bit_only`、`emu64x` 板级详情与 phone 产品；`sdk_slim_x86_64` 标识 Android ATD，r1 的 slim 配置明确不引入完整的含 SystemUI、Settings 的 handheld system-ext，并加入 `FakeSystemApp`、关闭 HWUI 绘制。官方 ATD 文档也列出精简应用和服务、禁用硬件渲染的优化，并警告依赖硬件渲染的截图测试受限。
- **限制**：ATD 面向特定自动化场景，其差异不能直接移植到需要交互、摄像、电话、输入法和网页的通用 APP 测试产品；Android 15 r1 slim 构建、功能和体积均未实测。建议先以 phone 为对照，建立功能清单和逐项回归，再借鉴 slim 的构建选择，而非直接删除 SystemUI。**状态：官方源码/文档已核对；运行与性能待实测。**

### A6. Android 15 r1 镜像打包脚本与文件关系

- **链接与维护者**：[r1 Goldfish tasks/emu_img_zip.mk](https://android.googlesource.com/device/generic/goldfish/+/refs/tags/android-15.0.0_r1/tasks/emu_img_zip.mk)、[r1 emu64x/details.mk](https://android.googlesource.com/device/generic/goldfish/+/refs/tags/android-15.0.0_r1/board/emu64x/details.mk)、[r1 x86_64 kernel 配置](https://android.googlesource.com/device/generic/goldfish/+/refs/tags/android-15.0.0_r1/board/kernel/x86_64.mk)，Google/AOSP；固定 tag 构建源码。
- **版本/环境**：Android 15 r1，Linux 构建；打包的 guest 镜像在 Windows Emulator 的实际兼容性待测。
- **解决问题**：识别实际输出、配套内核/ramdisk 和不可随意混搭的分区。
- **结论**：r1 脚本的目标是 `$(PRODUCT_OUT)/sdk-repo-linux-system-images.zip`，而非 A3 页面示例的 `...eng.[username].zip`。脚本把 `system-qemu.img`、`ramdisk-qemu.img`、`vendor-qemu.img` 分别复制为 ZIP 内的 `system.img`、`ramdisk.img`、`vendor.img`，并纳入内核 `kernel-ranchu`、`advancedFeatures.ini`、`source.properties`、`NOTICE.txt`、`build.prop`、加密镜像与 data 内容；是否包含 `VerifiedBootParams.textproto` 取决于源码条件。x86_64 内核配置的默认 `TARGET_KERNEL_USE` 为 6.6，但允许上游/构建配置覆盖。
- **限制**：这是 r1 脚本定义，不保证未来版本、其他目标或修改后的产品拥有相同名称/格式；没有实际构建 ZIP，所以最终文件清单、哈希和运行情况均需实验核验。保留**整套同构建**产物，再通过运行日志确认装载项。**状态：固定 tag 源码已核对，构建、跨系统传输与启动待实测。**

### A7. OTA 约束：精确到产品和继承路径

- **链接与维护者**：[r1 sdk_phone64_x86_64.mk](https://android.googlesource.com/device/generic/goldfish/+/refs/tags/android-15.0.0_r1/64bitonly/product/sdk_phone64_x86_64.mk)、[r1 product_config.mk](https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/core/product_config.mk)、[r1 board_config.mk](https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/core/board_config.mk)、[r1 emu64x/BoardConfig.mk](https://android.googlesource.com/device/generic/goldfish/+/refs/tags/android-15.0.0_r1/board/emu64x/BoardConfig.mk)、[r1 BoardConfigCommon.mk](https://android.googlesource.com/device/generic/goldfish/+/refs/tags/android-15.0.0_r1/board/BoardConfigCommon.mk)、[r1 board/kernel/x86_64.mk](https://android.googlesource.com/device/generic/goldfish/+/refs/tags/android-15.0.0_r1/board/kernel/x86_64.mk)，Google/AOSP；固定 tag 构建源码。
- **版本/环境**：Android 15 r1、`sdk_phone64_x86_64` 默认板级选择；构建 Linux，客体以 Goldfish 模拟器为目标，Windows 尚未实测。
- **解决问题**：厘清该目标是否默认具备 A/B 系统 OTA。
- **源码路径**：产品文件设置 `PRODUCT_DEVICE := emu64x` → `product_config.mk` 设 `TARGET_DEVICE := $(PRODUCT_DEVICE)` → `board_config.mk` 搜索 `device/generic/goldfish/board/$(TARGET_DEVICE)/BoardConfig.mk` → `board/emu64x/BoardConfig.mk` 包含 `board/BoardConfigCommon.mk` → 后者标注 emulator Non-A/B 并设置 `AB_OTA_UPDATER := false`、`AB_OTA_PARTITIONS` 为空。另一路产品文件包含 `board/emu64x/details.mk`，它包含 `board/kernel/x86_64.mk`；后者注释“we do NOT support OTA”，将 `PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS` 设为 false 以抑制警告。
- **结论和限制**：这是**对该 tag、该产品默认依赖路径、未额外覆盖条件下的源码推断**；可客观否定“默认就有 A/B OTA”的说法，不能推断所有 Goldfish 版本和定制设备永远不能支持 OTA，也不能据此认定其他更新机制已经实现。需通过实际构建解析变量及启动试验复核。**状态：官方源码已核对；OTA 实现、更新安全、断电恢复和回滚待验证。**

### A8. 产品继承、安装 APK 与变体

- **链接与维护者**：[Add a new device](https://source.android.com/docs/setup/create/new-device)、[Build Android](https://source.android.com/docs/setup/build/building)，Google/AOSP；官方设备构建文档。
- **版本/环境**：动态文档，具体 Make/Soong 行为以固定源码分支为准；Linux 构建，Windows 模拟器运行待测。
- **解决问题**：形成可复现的产品配置，而不是启动后临时改系统。
- **结论**：可在自有 `device/<组织>/artemisos/` 下规划 `AndroidProducts.mk`、产品 `.mk`、必要的设备配置，以继承兼容的 Goldfish product 并添加受控模块；预装 Agent 使用适配该分支的 Soong/Make 模块和 `PRODUCT_PACKAGES`，必要静态文件通过产品配置放入正确分区。`userdebug` 适合开发诊断；`eng` 更偏工程调试；面向分发须评估 `user` 及正式密钥，并验证自动化接口的实际权限与功能。
- **限制**：以上路径是建议结构，尚未创建；派生产品名、放置分区、源码许可、AVD 元数据与 `emu_img_zip` 对自定义产品的适用条件必须按固定 tag 验证。`adb root`、永久关闭验证、`adb remount` 或运行时修改系统仅作受控实验，不是正式镜像的构建流程。**状态：官方文档支持产品配置；本产品路径和实现待设计、构建验证。**

### A9. 属性、资源覆盖与 init 服务

- **链接与维护者**：[Add system properties](https://source.android.com/docs/core/architecture/configuration/add-system-properties)、[Runtime resource overlays](https://source.android.com/docs/core/runtime/rros)、[r1 init README](https://android.googlesource.com/platform/system/core/+/refs/tags/android-15.0.0_r1/init/README.md)，Google/AOSP；官方文档与固定 tag 源码。
- **版本/环境**：属性/RRO 文档为当前文档，init 依据 Android 15 r1；客体 Android，Linux 构建、Windows 运行待测。
- **解决问题**：定制语言、界面和服务，保留可追踪及可恢复的构建过程。
- **结论**：属性应设计名称、分区、属性上下文与读写权限；RRO 仅能替换目标已有且允许覆盖的资源；新增 init 服务需要匹配执行文件、`.rc`、标签、服务域和启动条件。语言、`Asia/Shanghai` 时区及现有网络修复应分别核验首启、用户改动后重启、清数据与升级行为，不应把临时 ADB 设置当作完整方案。
- **限制**：不同系统版本的默认 locale、时区设置入口、资源覆盖规则与 SELinux policy 有差异；不能只声明 NFC/传感器等 feature 而没有相应行为实现，否则会误导被测应用。**状态：官方机制已核对；项目配置待设计验证。**

### A10. 权限、签名与 SELinux

- **链接与维护者**：[Privileged permission allowlist](https://source.android.com/docs/core/permissions/perms-allowlist)、[Android 15 signature permission allowlist](https://source.android.com/docs/core/permissions/signature-permission-allowlist)、[Customize SELinux](https://source.android.com/docs/security/features/selinux/customize)，Google/AOSP；官方安全文档。
- **版本/环境**：权限白名单按文档所述 Android 9+；签名权限白名单变化自 Android 15；Linux 构建、Android 客体执行。
- **解决问题**：让预装测试 Agent 或系统服务只获得运行所必需的权限。
- **结论**：priv-app 白名单必须和应用位于同一分区，vendor 应用权限受额外限制；Android 15 对平台签名的非系统应用在非 debuggable 构建引入平台签名权限白名单，平台签名系统应用的更新版本若新增原版未请求的平台签名权限，同样需要纳入白名单。debuggable 构建不强制这一白名单，同签名不等于各种权限自动可用。新增 init daemon 需要合适 SELinux 域和精确权限，并在 enforcing 下验证。
- **限制**：不要预设 Agent 需要 platform key 或全权限；仅配置权限名也不能绕过签名/保护级别。应分别验证 `user` 和 `userdebug`，避免开发版成功、正式版失效。**状态：官方机制已核对；权限清单和 SELinux 规则待实测。**

### A11. AVB、发布签名与系统 OTA 工具

- **链接与维护者**：[Sign builds for release](https://source.android.com/docs/core/ota/sign_builds)、[Android Verified Boot](https://source.android.com/docs/security/features/verifiedboot/avb)、[Build OTA packages](https://source.android.com/docs/core/ota/tools)、[Virtual A/B overview](https://source.android.com/docs/core/ota/virtual_ab)、[Dynamic partitions](https://source.android.com/docs/core/ota/dynamic_partitions)，Google/AOSP；官方安全和更新文档。
- **版本/环境**：各文档覆盖版本以正文为准；Linux 生成签名产物，Android 客体应用 OTA。
- **解决问题**：分清 APK/OTA/镜像信任链与更新能力。
- **结论**：发布签名不应使用公开 AOSP 测试密钥；APK 更新签名、OTA 包签名、AVB 分区验证密钥、Windows 安装包签名和更新源认证是不同的控制面。OTA 生成涉及与旧/新构建对应的 target-files、签名和设备更新路径。A7 已说明 r1 默认 Goldfish 是 Non-A/B，系统内 OTA 是研发项目，须先验证恢复机制、更新写入、签名链、意外中断及回滚。宿主侧停止实例后更新整套镜像是另一条方案，也需要原子替换、保留用户数据和失败回滚。
- **限制**：官方 A/B/Virtual A/B 文档不能证明我们的 AVD 现有 bootloader、分区、`update_engine`、宿主镜像文件和防回滚链路已支持该能力。不得在交付前声称系统内 OTA 已完成。**状态：官方机制与 r1 默认限制已核对；具体信任根和 OTA 实装未验证。**

### A12. Android Emulator 与 Cuttlefish 的边界

- **链接与维护者**：[Build Android](https://source.android.com/docs/setup/build/building)、[Cuttlefish overview](https://source.android.com/docs/devices/cuttlefish)、[Android Emulator command-line](https://developer.android.com/studio/run/emulator-commandline)、[r1 board_config.mk](https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/core/board_config.mk)，Google/AOSP/Android Developers；官方指南和源码。
- **版本/环境**：当前动态指南；r1 源码用于板级搜索；构建均可用 Linux，Android Emulator 用户端需验证 Windows 原生运行。
- **解决问题**：防止将 Cuttlefish 产品误认为 AVD 镜像，或把开发环境当成最终交付运行时。
- **结论**：当前构建文档示例 `aosp_cf_x86_64_only_phone-...` 是 Cuttlefish 目标；Goldfish `sdk_phone64_x86_64` 是另一条模拟器产品路径。两者在虚拟设备、分区、板级配置、镜像与启动器上有不同约定；不能将 Cuttlefish 产物按名字塞进 Android Emulator 并断定可工作。
- **限制**：源码中出现 Cuttlefish 仓库、复用某些组件，不意味着 Goldfish 最终用户依赖 Linux/WSL 或 Cuttlefish 运行时；共享代码不等于可互换产物。**状态：官方架构区分与代码入口已核对，具体跨版本兼容待实测。**

## 后续团队验证路线（本任务未执行）

1. **先固定基线**：选择仍受维护的 Android 15 tag 与 Windows Emulator 版本；保留官方原始镜像、runtime、AVD 及其版本、文件哈希和许可证清单。原始镜像在目标 Windows 电脑能启动并通过 ADB、基础网络/画面/应用安装后，再做源码变更。
2. **构建未修改 Goldfish**：在团队 Linux 开发机记录 manifest revision、`PRODUCT/RELEASE/VARIANT` 与构建环境；先检查源码目标，构建和按该 tag 的 `emu_img_zip` 打包并保存完整 ZIP；检查压缩包成员、`source.properties`、内核与映像哈希。不要把 r1 示例当最新安全版本。
3. **传到独立 Windows 环境**：使用固定的、获准分发的 Windows Emulator 运行时和独立 AVD 目录加载同一构建的整套镜像；记录 `-verbose` 选用的文件、内核/ramdisk、ADB 启动完成、API/ABI、网络、图形及兼容性。开发机可用不等于最终用户安装成功。
4. **最小系统改动**：先添加一个无特权测试 Agent 或可观察版本标记，编译并重复第 3 步；再逐项纳入中文、时区、网络、运营商模拟、分辨率和可用特性。对应用实际功能测试；声明功能前先确认行为实现。
5. **评估精简**：在相同构建、硬件和测试脚本下，对比 phone、精简候选的压缩下载体积、安装后磁盘、启动耗时、宿主内存/CPU 和自动化能力。每次仅删除可解释的模块并回归输入法、浏览器、媒体、设置、通知与摄像头；ATD 的默认约束不等于用户要求。
6. **系统更新单独立项**：保留原版/新版本的构建元数据、target-files、签名清单；先通过宿主层受控升级及失败回滚验证；如继续做客体系统 OTA，则先完成 A7、A11 所述板级、存储、信任链和中断恢复的架构及端到端验证。完成系统构建或启动一个 AVD 都不是产品发布验收。
