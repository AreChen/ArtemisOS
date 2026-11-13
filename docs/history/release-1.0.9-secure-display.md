# ArtemisOS 15 1.0.9：安全页面显示与前端切换

状态：2026-11-12 已发布安装包和 OTA，使用天翼云直连下载。发布及在线验收证据见下文。

## 变更

- 修复自定义窗口通过普通镜像显示 FLAG_SECURE 页面时黑屏的问题。派生的 scrcpy 4.1 Android 服务为本机窗口建立安全镜像；不清除应用安全标记，不修改 ADB 权限或 SELinux。普通 shell 截图继续遮黑。
- 设置新增“显示前端”：ArtemisOS 自定义窗口 / Android Emulator 原生窗口。旧用户默认保留自定义窗口；保存后关闭整个模拟器，再从桌面重新启动生效。
- 修复显示服务在连接尚未建立时可能残留的问题，增加 10 秒握手期限和父进程退出清理。独立的 forward / reverse 定向实机测试通过。
- 修正开发端构建脚本在嵌套 Git 目录下可能静默跳过补丁的问题，并在编译前检查补丁已实际生效。发布的最终源码 ZIP 可独立完整重建，产物与实机使用的服务逐字节相同。

系统镜像、Android 15、Emulator 37.3.9 Beta、Windows 显示客户端、图形后端和默认渲染策略保持原样。最终用户不需要安装开发端 JDK 或 Android SDK。

## 升级和数据

1.0.8→1.0.9 的 OTA 共 15 个文件，211,717 字节（约 207 KiB），包括 6 个替换文件和 9 个新增源码/许可文件；不下载系统镜像或 SDK。仍逐级升级并校验清单签名、对象大小、对象 SHA256 和旧文件 SHA256。

完整安装包继续自动识别原安装目录及身份，关闭模拟器后直接覆盖升级，无需卸载。保留 Android 应用、用户数据、登录状态、分辨率、渲染及前端偏好。新直连更新器可逐级升级；旧下载器若无法访问新入口，应直接运行完整安装包覆盖升级。

## 验证与边界

- 合成安全页：普通官方镜像遮黑，专用服务正常显示，独立 ADB 截图仍遮黑；原生和自定义窗口均已确认。用户随后确认原问题已无异常。
- 60 项前端偏好/分流检查通过；启动生命周期、身份绑定及带前端替换的真实签名更新 fixture 通过。
- 三份冻结 1.0.8 基线均通过实际 OTA apply、中断恢复、再次升级和最新无更新清单验签。native 前端偏好、未知设置、样本用户文件逐字节保留；新增文件回滚后删除。
- 签名、旧文件、补丁篡改和新增文件碰撞均拒绝升级。
- 精确公开源码 ZIP 的 14 项编译前检查、14 项编译后检查和 Java policy 测试通过，完整重建服务 SHA256：`a18a94bf9042dd496dc3d714d788146ef3eaf0f08d9c8c2e518c838e7f697dfc`。
- 最终安装包以标准用户完成 1.0.8→1.0.9 原目录覆盖升级；532 项交付文件匹配，前端偏好、未知配置和样本用户数据保留，系统镜像未重写。卸载保留数据，临时测试账户与目录已清理。
- 本机 `E:\ArtemisOS15` 已使用同一安装包升级到 1.0.9 并恢复运行，原偏好及 8 项 AVD 元数据在安装阶段逐字节保留，`sys.boot_completed=1`。初始化日志确认 Intel UHD 770 硬件 Vulkan，前端已建立显示纹理。

本次没有把 FLAG_SECURE 页验证扩展为 DRM/protected-buffer 视频支持认证，也没有重新进行多屏/Sunshine 长时测试。root 模式双向剪贴板兼容性仍未单独验证。安全镜像帧会进入 Windows，宿主截图或另行录制可能保存这些帧。

## 下载与记录

- [完整安装包](https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/installers/ArtemisOS15-Offline-Installer-1.0.9.exe)：1,233,315,546 字节；匿名完整回读的大小及 SHA256 与本地一致：`414de6c38d2381cf64ab69c1950500883f74f695342fe7d9a20151e1b3aa6648`。
- [SHA256 文件](https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/installers/ArtemisOS15-Offline-Installer-1.0.9.exe.sha256)
- [最终专用服务源码 ZIP](https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/sources/ArtemisOS15-Secure-Display-Sources-1.0.9-r2.zip)：516,863 字节，SHA256 `2dad5c6861dadde64700ba65174f8bc8d6c99275a9db16b59a8392b4d7df4a45`。
- [原始调查](secure-display-and-frontend-20261112.md)
- [OTA 验收](evidence/release-1.0.9/ota-test-result.json) · [安装包验收](evidence/release-1.0.9/installer-smoke-result.json) · [发布记录](evidence/release-1.0.9/publication.json)
- [安装包直连回读](evidence/release-1.0.9/installer-publication.json) · [本机保留数据升级](evidence/release-1.0.9/local-install-result.json) · [临时测试环境清理](evidence/release-1.0.9/installer-smoke-cleanup-result.json)

使用既定 `/d/CLOUD/Footage/EAPIL/Artemis/ota/` 永久入口，由 OpenList 302 跳转到天翼云下载；不将临时签名 URL 写入配置，不修改代理或分享设置。固定路径清单与签名的发布仍不具备原子性；切换期间不一致时客户端停止或重取完整配对验签，绝不跳过签名验证。
