# 系统更新、发布与回滚研究

核查日期：2026-10-31。本文是路线研究，不代表已构建、已集成或已验证 Android 系统 OTA。Windows 最终用户仍使用本机 Android Emulator；Linux 仅用于开发团队构建和签名。

**关键源码发现**：Android 15 的 `android-15.0.0_r1` 原始 `sdk_phone64_x86_64` 目标沿设备 `emu64x` 继承 [Goldfish 的 BoardConfigCommon.mk](https://android.googlesource.com/device/generic/goldfish/+/refs/tags/android-15.0.0_r1/board/BoardConfigCommon.mk)，其中 `AB_OTA_UPDATER := false`；该目标的 [x86_64 内核配置](https://android.googlesource.com/device/generic/goldfish/+/refs/tags/android-15.0.0_r1/board/kernel/x86_64.mk) 也注释不支持 OTA。因此该固定 tag 的默认配置不能直接宣称支持 Android A/B 系统 OTA；若需实现，须自行适配并验证完整链路。此结论基于源码继承路径，未编译或运行，不代表所有 Goldfish 版本及自定义产品都相同。完整继承路径见 [AOSP 构建与系统定制](aosp-build-and-customization.md)。

## 已有实现与三种更新的边界

| 更新对象 | 触发和执行位置 | 当前项目状态 | 与 Android 原生系统 OTA 的关系 |
|---|---|---|---|
| Windows 启动器、配置与更新组件 | Windows 更新程序下载并替换宿主文件 | 已有本地更新原型；签名清单、文件 SHA-256、备份和恢复逻辑可在仓库中核查 | 不是 Android 系统 OTA |
| Emulator 运行时或 Android 镜像文件 | Windows 下载、停止相关实例并替换或切换文件 | 发布脚本可选择包含 SDK 文件；按文件发送，不是已实现的二进制差分 | 可以从 Android 界面发起，但实际仍是宿主镜像更新 |
| Android 分区及系统服务 | 本文优先研究的 A/B 或 Virtual A/B 路线由 Android 内 `update_engine` 等组件更新设备分区，重启、验证并按机制合并 | 此项目的 Goldfish + Windows Emulator 组合尚未验证 | Android 原生系统 OTA 的一种；依赖设备、分区、引导和持久化支持 |

当前 `tools/Publish-Update.ps1` 的 `-IncludeSdk` 控制是否递归纳入整个 SDK 目录；即使不指定该开关，只要目标存在 `carrier-operators.xml`，脚本也会将其作为 SDK 下的 `numeric_operator.xml` 目标文件纳入比较。`stage/update/core.ps1` 与 `stage/update/apply.ps1` 按对象哈希下载、校验并部署文件。文件未变化可以跳过，但变化的大文件不是自动变成小差分包。以上是对现有源码的只读检查，不能推广为全部场景已完成故障测试。

发行基线必须包括**完整内容身份**：现有 0.3.4 新装可使用精简 system 镜像，而从旧版升级可保留完整镜像，二者版本号相同但镜像不同。发布更新时应使用实际基线哈希、镜像变体、运行时版本、架构及构建标识匹配；不满足差分基线时提供受支持的完整更新或明确停止，不能只看 UI 版本号。详见 [0.3.4 发布验证](../history/release-0.3.4-validation.md)。

## 推荐顺序

1. **先验证宿主管理的镜像更新**：镜像和运行时按版本只读保存；每实例保留独立数据；在新位置下载、验证并准备目标版本，停止受影响实例后切换版本引用，启动并完成健康检查，失败时恢复原引用与受保护的数据状态。Windows 文件锁、多实例共同使用镜像、断电和用户数据迁移都要测试。版本引用和安全的磁盘提交方式属于待设计方案，并非现有实现的保证。
2. **再验证差分传输**：以确切的源文件哈希产生及应用差分，校验目标完整哈希；实测下载字节、峰值磁盘、CPU、内存及所需时间；找不到基线或差分过大时回退完整对象。差分算法及其许可证尚未选型，不承诺每个变更都显著变小。
3. **并行研究真正的 Android OTA**：确认 Android 15 所选 Goldfish 目标的分区、引导、持久化能力；仅在必要前置条件满足后尝试构建同源的新旧 `target-files`，生成并在 Windows 本机 Emulator 内应用 OTA。不得将 Cuttlefish 测试成功推断为 Goldfish 成功。正式路径要覆盖断电、失败引导、回退、快照和多实例隔离。

上面第 1、2 项即使由 Android 设置页发起，仍称为“宿主镜像更新”。第 3 项成功后才可宣称支持所验证配置下的 Android 系统 OTA。

## 原生 OTA 的关键阻塞项和验收

以下主要分析 A/B 和 Virtual A/B。Android 历史上也有通过 recovery 执行的 Non-A/B 系统 OTA，官方现已将其列为弃用的旧机制；Goldfish r1 默认关闭 A/B，不等于已验证该镜像的 recovery OTA，亦不证明未来通过定制一定不可能实现其他机制。

- **可更新的实际块设备**：列出所选镜像的 boot、vendor、system、动态分区、`metadata`、userdata、fstab 和相应 Windows 宿主文件；验证目标在正常重启和完全关闭 Emulator 后持久存在。官方命令行文档指出默认系统镜像可由 AVD 共享；`-writable-system` 的临时副本在退出后销毁，因此不能把它直接当成持久 OTA 实现。
- **引导与分区能力**：确认是否启用 A/B 或 Virtual A/B、`boot_control` HAL、槽标记及失败引导回退；如采用 Virtual A/B，核对动态分区、COW 快照、`snapuserd`/相关设备映射与合并支持。每一项均以所选 Android tag 和运行时组合为准。
- **端到端流程**：为新旧版本保存同源 `target-files.zip` 和构建清单；根据所选分支工具生成完整或增量 OTA，并使用对应发布密钥签名。客户端需具备适当的系统权限，实际调用 `update_engine`、报告进度并安排重启；官方示例并不自动提供完整服务。
- **可信与恢复**：区分 Android 系统/OTA 密钥、AVB 密钥、Windows 安装程序签名、宿主更新清单签名；评估密钥轮换、服务端 HTTPS、版本重放与回滚策略。AVB 可信根、回滚计数存储及宿主侧文件替换的威胁模型需在模拟器架构下单独验证，不能仅因有哈希或启用 AVB 就认定全部成立。
- **实例和存储**：并行实例更新时不能破坏共用基础镜像；验证镜像和 userdata 之间的版本配对、快照失效、磁盘不足、宿主进程异常和强制关机；统计临时空间与下载量。失败时须能恢复到可启动状态且不误删用户数据。

## 原始资料条目

以下状态里的“官方资料已核查”仅表示阅读了官方文档或源码；并不表示本项目已经实测。文档如与固定源码 tag 冲突，应以该 tag 源码和实际产物为准，并记录差异。

### OTA-01：Build OTA packages

- **链接与维护者**：[AOSP Build OTA packages](https://source.android.com/docs/core/ota/tools)，Google / AOSP；**类型**：官方文档。
- **适用版本**：当前网页，需对照选定 Android 15 tag 的 releasetools；**构建环境**：Linux AOSP 构建及签名环境；**运行环境**：支持对应 OTA 机制的 Android 设备或虚拟设备。
- **问题与结论**：说明从 `target-files.zip` 生成完整和增量 OTA；增量需要准确的旧、新构建输入，完整包也须满足目标设备及安装条件。
- **限制**：不能把包生成成功等同于 Windows Emulator 可应用；具体命令和参数须以固定 tag 为准。
- **验证状态**：官方资料已核查；本项目未生成或应用。

### OTA-02：Virtual A/B overview

- **链接与维护者**：[AOSP Virtual A/B overview](https://source.android.com/docs/core/ota/virtual_ab)，Google / AOSP；**类型**：官方架构文档。
- **适用版本**：Virtual A/B，网页覆盖多个 Android 版本；**构建环境**：AOSP 设备产品构建；**运行环境**：已适配该机制的 Android 设备。
- **问题与结论**：解释 A/B 更新、动态分区快照和合并的工作方式，可用于评估系统级 OTA。
- **限制**：镜像必须有匹配的引导、持久化和分区实现；不能由此推断 Android 15 Goldfish 在 Windows 具备完整支持，也不能保证固定压缩率。
- **验证状态**：官方资料已核查；本项目待实测。

### OTA-03：Implement Virtual A/B

- **链接与维护者**：[AOSP Implement Virtual A/B](https://source.android.com/docs/core/ota/virtual_ab/implement)，Google / AOSP；**类型**：官方适配文档。
- **适用版本**：网页按 Android 版本分别给出配置；**构建环境**：对应版本的 AOSP 产品构建；**运行环境**：设备端动态分区、引导和快照栈。
- **问题与结论**：给出设备配置、内核和启动配置等实施入口，可作为 Goldfish 可行性核查表。
- **限制**：通用设备指南不是现成的 Windows Emulator 配方；逐项配置需要核实所选版本源码。
- **验证状态**：官方资料已核查；本项目待实测。

### OTA-04：A/B seamless system updates

- **链接与维护者**：[AOSP A/B system updates](https://source.android.com/docs/core/ota/ab)，Google / AOSP；**类型**：官方实现说明。
- **适用版本**：A/B 设备与对应 Android 版本；**构建环境**：AOSP 设备产品；**运行环境**：支持 A/B 引导的 Android。
- **问题与结论**：介绍 `update_engine`、`boot_control` 和槽状态；更新、重启及成功标记需要配合。
- **限制**：Virtual A/B 和旧式物理双槽并不完全相同；模拟器能否提供全部机制待实测。
- **验证状态**：官方资料已核查；本项目未接入。

### OTA-05：Emulator 命令行与镜像文件

- **链接与维护者**：[Android Emulator command-line reference](https://developer.android.com/studio/run/emulator-commandline)，Google / Android Developers；**类型**：官方运行时文档。
- **适用版本**：当前文档及对应 Emulator 版本；**构建环境**：不要求最终用户构建 AOSP；**运行环境**：Windows、macOS 或 Linux 版 Android Emulator。
- **问题与结论**：说明 system image、AVD 用户数据和 `-writable-system` 等选项；后者创建临时可写系统镜像，退出即销毁。
- **限制**：文档并未保证采用该选项即可实现重启持久化或 Goldfish OTA；项目交付必须验证具体版本和配置。
- **验证状态**：官方资料已核查；本项目 OTA 场景待实测。

### OTA-06：update_engine 源码

- **链接与维护者**：[AOSP system/update_engine README](https://android.googlesource.com/platform/system/update_engine/+/refs/heads/main/README.md)，Google / AOSP；**类型**：官方源码与 README。
- **适用版本**：入口是持续变动的主分支；正式实验须切到选定 Android 15 tag；**构建环境**：AOSP；**运行环境**：适配 update_engine 的 Android 系统。
- **问题与结论**：提供系统更新引擎实现及开发示例；示例涉及 Cuttlefish，是独立的设备目标和运行环境。
- **限制**：Cuttlefish 示例不能证明 Goldfish 或 Windows Emulator 的分区、引导与持久化可用。
- **验证状态**：官方源码入口已核查；本项目未构建、未实测。

### OTA-07：SystemUpdaterSample

- **链接与维护者**：[AOSP SystemUpdaterSample](https://android.googlesource.com/platform/bootable/recovery/+/main/updater_sample/README.md)，Google / AOSP；**类型**：官方示例源码。
- **适用版本**：main 分支示例，实验时以所选 Android 15 tag 为准；**构建环境**：AOSP；**运行环境**：具备所需权限和 update_engine 的 Android 系统。
- **问题与结论**：展示客户端向 `update_engine` 提交更新、接收进度和处理权限的接口。
- **限制**：示例不是完整生产级更新服务器或安全策略；不能直接用于证明目标镜像可更新。
- **验证状态**：官方示例已核查；本项目未集成。

### OTA-08：Sign builds for release

- **链接与维护者**：[AOSP Sign builds for release](https://source.android.com/docs/core/ota/sign_builds)，Google / AOSP；**类型**：官方发布指南。
- **适用版本**：多版本通用概念，具体参数须核对目标 tag；**构建环境**：受控的 AOSP 发布构建与签名环境；**运行环境**：验签并接受对应密钥的 Android 系统。
- **问题与结论**：说明测试密钥与发布密钥的区别以及构建、OTA 包签名过程。
- **限制**：Android 发布签名不能替代 Windows 安装程序签名、宿主更新清单签名及密钥管理。
- **验证状态**：官方资料已核查；本项目自制系统镜像发布签名尚未完成。

### OTA-09：Android Verified Boot

- **链接与维护者**：[AOSP Android Verified Boot](https://source.android.com/docs/security/features/verifiedboot/avb)，Google / AOSP；**类型**：官方安全文档。
- **适用版本**：AVB 2.0 及设备具体实现；**构建环境**：AOSP 和设备发布签名环境；**运行环境**：具备正确可信根、引导和回滚元数据支持的 Android 设备。
- **问题与结论**：说明分区签名、可信启动链和防回滚元数据；引导程序需要提供平台相关实现。
- **限制**：本项目宿主机可控的虚拟设备需要单独定义威胁模型，不能仅凭源码存在而宣称安全启动或防回滚有效。
- **验证状态**：官方资料已核查；本项目待实测。

### OTA-10：Android 15 r1 Goldfish 默认 OTA 配置

- **链接与维护者**：[BoardConfigCommon.mk](https://android.googlesource.com/device/generic/goldfish/+/refs/tags/android-15.0.0_r1/board/BoardConfigCommon.mk)、[x86_64 内核配置](https://android.googlesource.com/device/generic/goldfish/+/refs/tags/android-15.0.0_r1/board/kernel/x86_64.mk)，Google / AOSP；**类型**：固定 tag 官方源码。
- **适用版本**：仅 `android-15.0.0_r1`、`sdk_phone64_x86_64` 默认继承且无覆盖的构建；**构建环境**：AOSP Linux；**运行环境**：拟用于 Android Emulator 的 Goldfish Android 客体。
- **问题与结论**：依据该产品的 `emu64x` 继承链可见默认 `AB_OTA_UPDATER := false`，x86_64 内核配置中亦写明不支持 OTA；需要改变、适配并验证实现，不能当成已支持。
- **限制**：源码推断不代替实际构建测试；其他 Android tag、运行时与自定义产品可能不同。两份文件的上游适用条件和继承路径见 [AOSP 构建条目](aosp-build-and-customization.md)。
- **验证状态**：固定 tag 官方源码已核对；本项目未构建、未运行 OTA。

### OTA-11：历史 Non-A/B recovery 更新

- **链接与维护者**：[AOSP Non-A/B system updates](https://source.android.com/docs/core/ota/nonab)，Google / AOSP；**类型**：官方历史机制文档。
- **适用版本**：文档将该方法列为已弃用的旧设备方案；**构建环境**：相应设备版本的 AOSP OTA 工具；**运行环境**：具备配套 recovery、分区和更新能力的 Android 设备。
- **问题与结论**：说明系统 OTA 不全都通过 `update_engine`；历史 Non-A/B 路线由 recovery 验签并应用更新。
- **限制**：该历史文档不能证明 Android 15 Goldfish 或 Windows Emulator 默认有可工作的 recovery 更新；本项目不以其为首选实现。
- **验证状态**：官方文档已核查；本项目未构建、未验证。
