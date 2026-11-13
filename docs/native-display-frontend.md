# Windows 原生显示前端

安全页面显示修复及“ArtemisOS 自定义窗口 / Android Emulator 原生窗口”切换已随
[1.0.9 发布](history/release-1.0.9-secure-display.md)。这里的 Windows 原生桌面壳与 Emulator 自带窗口是两种前端；在设置中选择后，关闭整个模拟器并重新启动生效。

原生前端已随 1.0.6 发布，详见 [1.0.6 发布记录](history/release-1.0.6-native-frontend.md)。后续未发布修复与冻结发行文件分开维护。

## 结构与入口

普通桌面快捷方式继续调用 `start-auto.vbs`。`launch.ps1` 读取 `frontend` 偏好：`artemis` 将交互启动委派给 `update/frontend/ArtemisFrontend.exe`，前端再请求 `-ExternalDisplay` 启动原 Android 实例；`native` 直接打开 Emulator 自带窗口。`-Headless` 保持自动化测试原有行为。

后台 Android Emulator 使用既有镜像、AVD、图形偏好与数据目录。WinForms 外壳负责品牌、工具栏和状态；独立 SDL3 顶层窗口负责 scrcpy H.264 画面。两个窗口使用 owner 关系，不执行 `SetParent`。显示窗口可用后按实际视频宽高比定位；收到新 Texture 尺寸时重新适配横竖屏。

前端当前复用安装目录的 ADB，固定指定 serial，不管理共享 ADB server。普通关闭会先停止显示，再关闭其持有的后台实例；开发参数 `--attach-serial` 不接管已有后台的生命周期。重连只接受原 QEMU 的路径与精确创建时间。

## 控制行为

- 返回、主屏、最近任务、音量、亮灭屏和旋转在后台队列执行，不因单击而禁用整条侧栏；短操作最多保留 16 项，旋转执行期间忽略重复旋转。
- 截图保存到 Windows“图片/ArtemisOS”。APK 安装和文件导入使用原生文件选择器。导入位置为 Android 的 `Download`。
- 每次实际执行 ADB 命令前重新核对原 QEMU 身份；选择文件期间后台退出或端口被复用时拒绝执行。
- 旋转查询默认 display 0 的实际 `mRotation`，忽略 scrcpy 编码镜像屏和嵌套 `overrideConfig` 字段；手动方向需要 WindowManager 固定方向并锁定横屏/竖屏，随后检查实际方向。
- “更多 → 恢复应用方向控制”恢复 WindowManager 默认策略并解除用户方向锁定。应用自身声明的竖屏布局仍可能由 Android 以兼容方式显示。
- 内置 Pixel 桌面必须允许主屏幕旋转。本机已验证关闭此设置时，横屏显示虽然是 1600×720，桌面却被限制在 540×720 的竖屏兼容窗口，应用抽屉图标重叠；启用 `pref_allowRotation` 并重新加载桌面后，桌面获得完整横屏尺寸，应用列表恢复正常。初始化按一次性迁移处理，仅调整该布尔设置，保留其他桌面数据并备份原文件。后续用户自己修改该设置时不在每次启动强制覆盖。
- 菜单由外壳持有并复用，关闭弹出菜单时不立即释放；Windows 完成菜单点击派发后才处理退出请求，避免 `ContextMenuStrip` 已释放异常。

桌面旋转偏好的源码依据是 [AOSP Android 15 RotationHelper](https://android.googlesource.com/platform/packages/apps/Launcher3/+/refs/heads/android15-release/src/com/android/launcher3/states/RotationHelper.java)。内置 NexusLauncher 的实际偏好文件、Activity 配置及截图已在本机交叉验证；这里不把 AOSP 源码等同于闭源 Pixel 桌面的完整实现。

## 构建和验证

开发机使用 Windows 自带 .NET Framework 编译器，无需安装 .NET SDK。最终用户需 .NET Framework 4.8 和既有模拟器宿主依赖。

```powershell
rtk proxy powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\Prepare-FrontendRuntime.ps1
rtk proxy powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\Build-Frontend.ps1
rtk proxy powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\frontend-core.ps1
rtk proxy powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\frontend-controls.ps1
rtk proxy powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\frontend-menu.ps1
rtk proxy powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\launcher-layout.ps1
rtk proxy powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\frontend-render.ps1
rtk proxy powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\frontend-layout.ps1
rtk proxy powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\frontend-session.ps1
rtk proxy powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\frontend-display-recovery.ps1
rtk proxy powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\frontend-launch-lifecycle.ps1
```

设备控制测试使用 fake ADB；生命周期测试使用独立临时安装目录中的真实进程和命名管道，覆盖启动取消、失败、后台/显示崩溃、重连、其他安装隔离、OTA 和用户关闭并发。测试不需要重置真实 AVD。

## 会话与 OTA

`data/runtime/<GUID>.json` 保存安装根目录、serial、Emulator/frontend PID、精确 UTC 创建时间、就绪状态、实际渲染器和日志路径。命名管道使用安装根目录哈希和会话 GUID，仅当前用户及 SYSTEM 可访问。

更新器先校验补丁，再请求 `prepare-update:<GUID>`。前端停止显示后回复 `ready:<GUID>` 并退出，后台由更新器接管。用户恰好同时关闭前端时，普通关闭会等待交接结果；成功后保留后台，失败则执行普通关闭。前端未确认退出时不覆盖程序文件。

安装脚本和启动器的本机原件已备份在 `E:\ArtemisOS15\data\backups\frontend-20261111-234531`。SDK 文件可能与发布基线硬链接，更新文件须采用替换文件操作，禁止原地覆盖共享 DLL 或镜像。

## 验证记录与发布前事项

2026-11-11 至 12 日已通过原快捷方式启动原 AVD，实际渲染为 Intel UHD 770 / ANGLE / Vulkan；真实截图按钮已生成 PNG，画面、透明 Logo 和工具栏基础绘制已检查。本次音量修复回归曾复现单击禁用全部 12 个工具按钮，修复后不再发生。新增 OTA/用户关闭并发场景已确认旧代码失败、修复后通过，完整 11 个生命周期场景通过，主会话独立运行证据位于 `build/frontend-session-tests-18ccf37e858944bf9551d538982ed194`。21 项核心测试、真实菜单关闭/复用回归均通过。

2026-11-12 00:22 已在本机更新菜单修复并通过原入口重新启动，使用原 AVD，session 为 `817898059d4243f3bcfa052d2b8aa36f`。初始化脚本和桌面旋转迁移模块已原子替换；在该实例上再次执行初始化，已确认 `launcher_rotation=1`、原桌面偏好为 true 时不重启桌面。迁移纯 XML 与有界执行/安全跳过测试通过。桌面原始偏好备份留在 Android 原文件旁，此次更新前的前端备份位于 `E:\ArtemisOS15\data\backups\frontend-20261112-002215`。

2026-11-12 用户确认三项手工验收均正常：连续点击音量时侧栏不闪烁；“更多 → 打开运行日志”不报错；横竖屏切换后全部应用图标排列正常。

当前未宣称已完成长时运行性能测试。1.0.6 捆绑组件及对应源码分发见发布记录和 `update/frontend/third-party`。

2026-11-12 Sunshine 切换虚拟显示器后出现连续帧更新失败，重连显示端即可同时恢复画面与布局。自动恢复候选及验证边界见 [调查记录](history/sunshine-display-recovery-20261112.md)；本机测试修复尚未公开发布，真实 Sunshine 切换需单独验收。
