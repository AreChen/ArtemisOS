# ArtemisOS 15 1.0.8：显卡名称识别修复

状态：2026-11-12 已上传发布。安装包和 OTA 对象均通过天翼云匿名直连完整读回校验，线上签名升级链与 1.0.8 无更新清单已验证。

## 变更

修复 Intel 定向 Vulkan 模式因显卡名称不含 HD/UHD/Iris 而拒绝启动的问题。改用已启用的 PCI VEN_8086 标识识别 Intel 显卡，设备名称原样交给 ANGLE；保留组件校验、启动后实际渲染检查和软件回落拒绝。配置中改称“Intel 显卡”，不再靠名称区分核显与独显。

Intel Graphics、Intel(R) Graphics、Arc 等名称已由可控输入覆盖。本机 UHD 770 的检测和环境生成也通过；未将这些结果当作所有新型号、驱动的实机 Vulkan 兼容认证。Windows 与 Vulkan 驱动的名称若不同，仍可能被现有启动后精确匹配拒绝。

NVIDIA、AMD 的通用硬件模式没有型号名称白名单；GeForce、RTX、Quadro、Radeon 等名称样本已补充回归验证。没有改变用户渲染偏好或默认改为软件渲染。

## 交付与升级

- 完整安装器沿用 1.0.7-r2 的原生覆盖升级、原目录/AppId、卸载日志追加、相同镜像跳过和失败恢复机制；关闭模拟器后运行，不需要先卸载。
- 完整包的 523 个交付文件中，仅 configure.ps1、initialize.ps1、settings.ps1、version.ini 四个发生变化。
- Android 15 镜像、Emulator 37.3.9 Beta、ANGLE/SwiftShader、显示前端及用户数据格式保持不变。
- 本地签名 OTA 为 1.0.7→1.0.8，四对象合计 46,474 字节，无 SDK、镜像和用户数据。压缩仓库只供发布工具使用，不能直接双击当作安装程序。
- 完整安装包及 1.0.7→1.0.8 OTA 已上传到现有天翼云直连入口。未修改 OpenList 代理或分享设置，未上传系统镜像；旧下载器的兼容政策保持不变。

## 验收

显卡识别与硬件环境回归通过。签名 OTA 已在三份冻结的 1.0.7 基线（完整安装、历史 OTA、从完整包开始的历史 OTA）分别执行真实升级、恢复回滚、再次升级与无更新清单验签；用户文件及未知偏好保留，未知修改过的 settings.ps1 被拒绝且不创建文件替换事务。

最终完整包已通过真实 1.0.7-r2→1.0.8 自动原目录覆盖安装：523 项交付文件、样本用户数据逐字节保留、系统镜像哈希/大小/时间戳不变、单一卸载日志、卸载后保留数据、8 个 Vulkan 组件全部通过。临时标准用户及目录已安全清理。未将文件与卸载测试当作 Android 应用实机测试。

背景见 [识别缺陷调查](intel-gpu-name-detection-20261112.md)。


## 本地文件

- [完整安装包](../../dist/ArtemisOS15-Offline-Installer-1.0.8.exe)：1233906697 字节。
- SHA256：fc29b0b9adf64ae4143ca3de3c7e4aa3b5511d168da2ab9e739f3a4aec47689c。
- [完整包验收](evidence/release-1.0.8/installer-smoke-result.json)、[OTA 验收](evidence/release-1.0.8/ota-test-result.json)、[构建记录](evidence/release-1.0.8/build-result.json)。

## 线上下载

- [1.0.8 完整安装包](https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/installers/ArtemisOS15-Offline-Installer-1.0.8.exe)，1233906697 字节。
- [SHA256 校验文件](https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/installers/ArtemisOS15-Offline-Installer-1.0.8.exe.sha256)。安装包 SHA256：fc29b0b9adf64ae4143ca3de3c7e4aa3b5511d168da2ab9e739f3a4aec47689c。
- 关闭模拟器后直接运行完整包，自动原目录覆盖升级，保留数据；使用新直连更新器的 1.0.7 客户端也可以在检查更新中升级，变化文件共 46,474 字节。
- 线上检查覆盖新更新器读取 1.0.2→1.0.8 的签名逐级清单，以及最新版本无更新标记；这不等于为旧下载器增加兼容迁移。
- EXE 与四个补丁对象均经完整匿名读回验证大小/哈希；最终响应来自天翼云 ctyunxs.cn，未使用 OpenList 文件代理。
- 清单和签名仍为两个固定路径文件，发布切换期间可能短暂不一致，客户端需停下或重取完整配对后验签，绝不跳过验签。

[发布记录](evidence/release-1.0.8/publication.json) · [线上验证](evidence/release-1.0.8/live-after-publication.json)