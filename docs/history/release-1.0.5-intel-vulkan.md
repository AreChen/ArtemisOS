# 1.0.5 OTA：Intel 核显 Vulkan

**2026-11-11 22:24（UTC+8）已发布到现有 OpenList 更新通道。** 1.0.4 完整安装用户和此前 OTA 升级用户均可检查并安装。补丁为 5 个脚本/版本文件，内容下载总计 **61,254 字节（59.8 KiB）**，另有小型签名清单请求；不含 SDK、系统镜像或用户数据。本次没有发布新的完整安装 EXE。

## 用户启用

1. 在 Android 的 ArtemisOS“系统更新”中检查并安装 1.0.5。
2. 打开 Windows 桌面的“ArtemisOS 15 - 配置”，图形渲染选择 **Intel 核显 Vulkan（HD / UHD / Iris，实验）**。
3. 保存，关闭并重新启动模拟器。标题应显示 `ArtemisOS 15 v1.0.5`。

升级不会自动改写已有渲染偏好。没有对应 Intel 核显的电脑仍使用原配置；新安装的硬件 OpenGL 默认值也保留。软件快捷方式仍只对当次启动选择软件渲染。本机已按用户要求保存为 Intel 核显模式。

## 实现与限制

新增配置键 `graphics=vulkan_intel`。Windows 启动器筛选已启用、PCI 厂商为 `8086` 的 Intel HD/UHD/Iris 设备，将完整设备名称传入子进程 `ANGLE_PREFERRED_DEVICE`。复用 1.0.4 已有的 Emulator 37.3.9 Beta/build 16863232、ANGLE 及驱动组件，不下载或混装额外 DLL。

仍使用现有 `-gpu swiftshader -feature -Vulkan` 的 ES 分类，由 ANGLE 使用所选 Intel 设备的宿主 Vulkan。初始化程序必须检查实际 SurfaceFlinger GLES 行与完整设备名称一致，拒绝其他显卡或 CPU 回退。未检测到设备、存在多个不同候选、驱动命名不一致或渲染器不匹配时明确报错；没有自动退回软件。覆盖仅作用于子进程，不更改 Windows 全局显卡设置。

本机实测 UHD 770，Windows 驱动 `32.0.101.7088`、Vulkan `1.4.323`。从正式启动器启动原可写 AVD，Android 启动完成、初始化确认 Intel、原生窗口画面正常；一次跨屏移动后仍正常且 ADB 有响应。此前只读实例已关闭，当前不是只读测试实例。

**发布后故障复现：** 用户继续拖动后，Intel Vulkan 驱动也发生原生异常，整个模拟器停住。此前一次移动通过仅为短测结果，不能认定核显模式已修复窗口移动或跨屏问题。通过无窗口后端与独立显示端已暂时恢复本机使用，但这套前端尚未包含在 1.0.5 OTA 中。详见 [本机异常与隔离记录](intel-window-hang-20261111.md)。

本次没有验证所有 HD/UHD/Iris 型号、其他 Intel Arc 设备或长时间直播。通用硬件 Vulkan 仍作为实验选项保留，NVIDIA 跨屏故障未宣称修复。Android 原生 Vulkan API 和视频硬件编解码的限制沿用 [硬件 Vulkan 调查](hardware-vulkan-1.0.5.md)。

## 补丁与兼容性验证

变化路径仅为 `configure.ps1`、`initialize.ps1`、`launch.ps1`、`settings.ps1`、`version.ini`。两种 1.0.4 来源在这五条路径上完全一致；各自 VBS 入口及旧迁移 sidecar 不同，全部原样保留。

使用冻结的真实 1.0.4 core/apply，对两条来源执行签名验证、五个基线哈希验证和实际 `apply -NoRestart`。升级后版本及五个对象正确，偏好和 AVD 标记逐字节保留，旧文件回滚备份正确。OTA 来源的旧 `launch-current.ps1 -NoLaunch` 连续运行两次，没有覆盖新版根启动器或恢复日志。篡改 settings 的负例拒绝更新，所有原脚本、偏好和数据保留。

新增 Intel 配置/设备筛选/环境隔离/精确 renderer 验证测试先失败后通过；原硬件 Vulkan、现代软件 Vulkan、显示配置、SD 卡保护及 ADB 共存回归通过。独立代码审查未发现阻断问题。上述自动测试不替代各驱动型号的实际兼容性验证。

发布脚本对全部五个对象匿名读回并校验 SHA-256，再发布来源清单。随后以两份冻结旧 core 匿名检查，两条 1.0.4 来源均收到与本地测试完全相同的 1.0.5 签名清单；实际 1.0.5 客户端正确得到“暂无更新”。用户端不需要 OpenList 账号。

## 证据与后续基线

- 不可变签名仓库：`build/ota-1.0.5-intel-vulkan/repository`。
- 清单 SHA-256：`36cb1ba9b0a430a5546ef19fb498d702b3f9e1c01cc762d775d47595cd882e84`。
- 可提交证据目录：[release-1.0.5-intel-vulkan](evidence/release-1.0.5-intel-vulkan)。包含签名清单、真实更新回归、原生启动、OpenList 发布及匿名客户端读回摘要，不含视频或账号凭据。
- 后续发布基线：`releases/1.0.5-ota-from-full` 与 `releases/1.0.5-ota`，分别在对应 1.0.4 基线上叠加这五个签名对象。SDK 原样硬链接，仅用于不可变发行快照，禁止原地修改。两者的 VBS/旧 sidecar 差异继续保留。
- 本机更新前脚本和配置备份：`backups/before-intel-vulkan-1.0.5-20261111-222011`。没有删除 AVD、应用、用户数据或旧发行包。

历史 1.0.3 等用户沿既有通道先完成 1.0.4，再检查 1.0.5。脚本被本地修改或尚未完成旧启动器迁移的安装仍可能被基线检查拒绝；本次没有关闭签名或放宽文件校验。
