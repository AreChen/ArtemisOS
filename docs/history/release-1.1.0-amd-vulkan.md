# ArtemisOS 15 1.1.0：AMD Vulkan 与显卡选择

状态：2026-11-13 已发布完整安装包与 OTA。AMD 显卡为实验支持，尚未经过 AMD 实机验证。

## 变更与使用

- 配置新增“AMD 显卡 Vulkan（集显 / 独显，实验）”，复用 GLES → ANGLE → Vulkan → 宿主 GPU 链路。Android 镜像、Emulator 37.3.9 Beta、Windows 前端和安全显示服务二进制均未更换。
- AMD 按 PCI 厂商 `VEN_1002` 识别，Intel 按 `VEN_8086` 识别；不依赖 Radeon、UHD、Intel Graphics 等型号名称关键词。仅允许已启用且标识、名称有效的设备。
- 选择 AMD 或 Intel 专用 Vulkan 后，“渲染设备”可选择具体显卡。偏好保存 Windows PCI 实例 ID，启动时重新确认厂商、可用状态，并将当前完整设备名称传给 ANGLE。
- 自动选择仅在对应厂商只有一个可唯一定位的设备时生效。多卡需明确选择；名称完全相同的多个设备无法由当前 ANGLE 名称选择机制唯一定位，将提示改用通用硬件 Vulkan 或其他模式。
- 启动后核对实际 GLES/Vulkan 渲染器。软件回退、其他显卡或设备名称不匹配均拒绝，不会擅自改变用户选择。软件快捷方式仍只覆盖本次启动，并清除子进程的硬件设备约束。

AMD 用户需安装支持 Vulkan 的显卡驱动。Windows 显示名与驱动的 Vulkan 设备名称不一致时，专用选卡会安全停止；可手动切换通用“硬件 Vulkan”或其他渲染模式。AMD 驱动、实际画面、视频、多屏及长时稳定性仍待用户设备验证。

保存配置后，关闭整个模拟器并重新启动生效。原有图形模式、前端、应用和用户数据不会因升级自动切换或清除。

## 验证

- Windows PowerShell 5.1：49 项 AMD 合成设备测试通过，覆盖厂商伪装、禁用设备、独显/集显/通用名称、多卡指定、同名卡拒绝、偏好保存、环境隔离及实际渲染器核对。
- 原 Intel、通用硬件 Vulkan、60 项前端偏好测试、安全显示运行时与前端生命周期回归通过。
- 三份冻结 1.0.9 基线实际完成 OTA apply → 中断恢复 → 再次 apply → 最新无更新清单验签。原 `graphics_device`、native 前端、未知偏好及样本应用/用户文件逐字节保留。
- 旧文件修改、签名或清单篡改、对象大小/哈希异常均拒绝。
- 本机实际检测到 Intel UHD Graphics 770，未检测到 AMD 显卡。合成测试通过不等于 AMD 实机认证。
- 精确安装包在隔离标准用户账户完成 1.0.9→1.1.0 不指定目录的自动发现覆盖升级，532 个文件核对通过；用户数据逐字节保留、旧镜像复用、原生前端偏好及卸载保留数据通过。测试账户、profile 和目录已独立确认清理。
- 本机 `E:\ArtemisOS15` 使用同一安装包保留数据覆盖为 1.1.0；偏好和 8 份 AVD/用户配置元数据不变，Android 启动完成，Intel UHD 770 硬件 Vulkan 初始化通过，窗口标题为 `ArtemisOS 15 v1.1.0`。未使用 computer-use，也未人工确认该次启动后的应用画面。
- 已匿名验证线上 1.0.2 起的逐级签名链至 1.1.0，以及最新版本无更新清单；5 个新对象完整大小/SHA256 均通过。完整安装包和校验文件已上传并匿名完整回读，实际下载主机为 `media-qhxn-fj-person.qh6oss.ctyunxs.cn`，不是 OpenList 文件代理。

## 交付与协议

1.0.9→1.1.0 OTA 共 5 个文件，77,416 字节（约 76 KiB），无镜像或 SDK 下载。保留签名、对象大小/SHA256、旧文件 SHA256 校验，升级链仍按当前版本逐级推进，支持 minor 版本跨越。

完整安装包另更新中文“使用说明.txt”；旧更新器的根文件白名单不允许该中文路径，因此不将此说明文件混入 OTA，也不放宽安全路径规则。完整包与 OTA 的程序代码相同；从 OTA 升级的说明文件可能仍为旧版，以配置界面及本发布说明为准。三份新冻结基线分别记录这一差异。

完整安装包 1,233,393,659 字节，SHA256：`2631dd6eb013d749e6c574986ba90fd4cb3e1e3ccad6db73fdb84ba58a15c2b9`。原目录覆盖升级，无需先卸载。旧更新器若无法访问新下载入口，可直接使用完整安装包覆盖，保留原实例。

- [完整安装包](https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/installers/ArtemisOS15-Offline-Installer-1.1.0.exe)
- [SHA256](https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/installers/ArtemisOS15-Offline-Installer-1.1.0.exe.sha256)
- [OTA 验收](evidence/release-1.1.0/ota-test-result.json) · [完整包验收](evidence/release-1.1.0/installer-smoke-result.json) · [发布记录](evidence/release-1.1.0/publication.json)
- [本机升级](evidence/release-1.1.0/local-install-result.json) · [本机 Intel 初始化](evidence/release-1.1.0/local-intel-initialize.log) · [隔离账户清理](evidence/release-1.1.0/smoke-cleanup-evidence.json)

继续使用 `/d/CLOUD/Footage/EAPIL/Artemis/ota/` 永久入口，302 跳转至天翼云直连，临时下载 URL 不写入配置，不修改 OpenList 全局代理或分享设置。沿用 [1.0.9 的专用显示服务源码及重建证据](release-1.0.9-secure-display.md)，不重新声称已构建或验证该未修改组件。
