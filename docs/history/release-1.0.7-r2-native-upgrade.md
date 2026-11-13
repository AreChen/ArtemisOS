# 1.0.7-r2：保留原实例的安装器修订

状态：2026-11-12 已发布并通过天翼云匿名完整读回验哈希。产品版本仍为 1.0.7；r2 是安装程序修订号。

## 问题与范围

原 1.0.7 安装程序在发现相同 AppId 时直接拒绝运行。这是安装策略缺陷，不是这次 OTA 地址变化造成 Android 数据不兼容。

r2 沿用已发布 1.0.7 的全部产品文件、Android 15 镜像、Emulator 37.3.9 Beta 和图形组件。没有改变 OTA 版本链或签名清单，也没有重新上传镜像。

## 安装行为

- 自动识别当前用户的正式安装记录，使用原目录和原 AppId；支持历史 GUID 与 `ArtemisOS15-Release`，交由 Inno 追加原卸载日志。
- 关闭模拟器后直接运行新安装包，无需先卸载。相同版本可修复安装；拒绝降级、多个安装身份、机器级/不同位数注册及错误目标目录。
- 不重写 `data/preferences.ini`，包括未知字段；不初始化、删除或重建 AVD，不覆盖已安装应用、登录状态或用户文件。
- 对镜像和 SDK 比较 SHA256，相同文件跳过，变化的程序文件先备份。此次 1.0.6→1.0.7-r2 不重写系统镜像。
- 保留两级自定义 OTA 地址；仅将已知旧官方分享地址替换为 `https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/`。
- 不调用 `Find-ArtemisInstallations.ps1` 或原型 `Upgrade-Transaction.ps1`。原生安装流程未关闭或绕过杀毒防护；首次镜像优化及模拟器启动仍使用 PowerShell。

## 中断恢复与边界

替换文件、卸载程序和卸载注册值具有校验备份。升级失败恢复旧程序；独立注册定位指针让安装程序在卸载注册键重建期间中断后仍能找到原目录。重新运行安装程序可先恢复再重试，失败时保留恢复材料。

备份位于安装目录的 `.artemis-install-backups`，不包含整份 Android 用户数据。不要手动删除尚有 pending 标记的恢复材料。安装过程持有现有启动、前端和 OTA 锁，并检查分离的无窗口后端；不能据此宣称绕过启动管理器直接运行底层 EXE 没有并发风险。

旧版 OTA 下载器仍不作兼容迁移；它无法检查更新时，直接运行此完整安装程序可保留实例升级。对更早版本的实际 Android 启动兼容不能仅凭合成文件测试作保证。

## 验证

`tests/installer-native-upgrade.ps1` 使用唯一安装身份、小型合成 SDK 和真实 Inno 注册/卸载流程，分别验证普通与历史安装身份。覆盖数据字节、未知偏好、自定义服务器、空格目录、中文文件、完整卸载注册值、互斥、同版修复、拒绝降级、失败回滚、进程硬退出后恢复，以及卸载注册键缺失时恢复。它不等于 Android 应用启动测试。

净化证据见 [普通身份，364 项断言](evidence/release-1.0.7-r2/native-upgrade-normal.json) 与 [历史身份，187 项断言](evidence/release-1.0.7-r2/native-upgrade-legacy.json)。独立代码评审未发现阻塞项，评审源码与最终编译输入哈希一致。


本机原安装实测：E:\ArtemisOS15 已用同一最终完整包从 1.0.6 原地升到 1.0.7。重启前，除已知官方 OTA 地址迁移外，原 383 个数据文件的大小/时间戳一致，偏好文件 SHA256 不变；随后前端与 Android 启动成功，sys.boot_completed=1。没有执行真实账号重新登录测试。[结果](evidence/release-1.0.7-r2/local-upgrade-result.json)

真实完整包验收：在独立临时标准用户下先装正式 1.0.6，再不指定目录直接运行最终 r2 完整包。验证 523 个交付文件、原目录及 AppId、AVD/应用与登录资料/图片/偏好样本字节保持、镜像 SHA256 与时间戳均不变、8 个现代 Vulkan 组件，以及原生卸载日志追加和卸载后保留数据。测试账户及目录已清理；没有将合成登录样本测试冒称真实 App 登录或 Android 开机测试。[验收结果](evidence/release-1.0.7-r2/installer-smoke-result.json)

## 下载与交付

- [1.0.7-r2 完整安装包](https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/installers/ArtemisOS15-Offline-Installer-1.0.7-r2.exe)：1,233,948,425 字节，约 1.23 GB / 1.15 GiB。
- [SHA256 校验文件](https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/installers/ArtemisOS15-Offline-Installer-1.0.7-r2.exe.sha256)：2c1b399668b95c6b1ab19a516bc6e325a8a91409a0c263266183202445e9f328。
- 关闭现有模拟器，再直接运行此安装包；不需要卸载或清理数据。安装中若报告多个真实安装，先核对目录，不要删除数据。
- 仅目录已不存在的旧卸载登记可被忽略，不删除登记本身；无法访问或仍存在的旧目录仍按冲突处理。
- 安装器修订源与构建清单保存在 releases/1.0.7-r2-installer；产品文件继续使用原 1.0.7 基线。
- 安装包仍未做 Authenticode 签名。原生发现和覆盖安装不执行临时发现脚本；不能承诺不会触发其他行为防护提示。

发布结果见 [记录](evidence/release-1.0.7-r2/publication.json)；EXE 与校验文件均经匿名天翼云直连完整读回。此次不更新 OTA 清单，不重新上传 Android 镜像，不修改 OpenList 代理或分享设置。