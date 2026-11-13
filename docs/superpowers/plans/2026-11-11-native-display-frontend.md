# ArtemisOS 原生显示前端实施计划

> **面向 Agent 型工作者：** 必需的子技能：使用 superpowers:executing-plans 逐项实施；独立子任务可由子 Agent 完成，接口由主会话协调。

**目标：** 将已验证的独立显示方式接成有品牌外观、控制按钮和正确生命周期的 Windows 前端。

**架构：** C# WinForms 外壳 + 独立顶层 SDL 显示窗口；现有 PowerShell 启动和 OTA 管理 Emulator。前端与启动器通过 GUID 会话文件交接，与更新器通过当前用户限制的命名管道退出握手。

**技术栈：** .NET Framework 4.8、Windows 原生窗口 API、scrcpy 4.1 / SDL3、既有 ADB 和 Emulator。

**规格说明：** [原生显示前端设计](../specs/2026-11-11-native-display-frontend-design.md)

## 全局约束

- 保留现有 AVD、SD 卡、用户偏好及不可变发布基线。
- 前端文件放 `stage/update/frontend/**`；源码放 `desktop/frontend/`。
- 所有 ADB 命令明确 serial、无 shell 字符串拼接；不得 kill-server。
- 视频窗口不 SetParent；后台仅使用现有运行时和渲染配置。
- UI 现代、低常驻开销；默认不持续动画。
- 原有 Headless 测试语义不变；ExternalDisplay 保留 OTA bridge 和原音频。
- 当前是本机实现与验证，不自动发布。

## 审查重点

- PID 复用或同机其他安装：路径/创建时间/serial 不匹配时拒绝停止。
- OTA 请求退出：显示与前端退出后才能覆盖文件，updater 不被 Job 或普通关闭逻辑杀掉。
- 启动取消与失败：错误可见，不遗留本次已创建的后台或重复启动。
- 带空格、引号、Unicode 的文件参数：正确传递，不经过 cmd/shell。
- 跨屏与 DPI/缩放：视频 HWND 不被销毁重建，外壳和视频位置一致。

## Task 1：设备控制与进程策略

**文件：** `desktop/frontend/FrontendCore.cs`，`tests/frontend-core.ps1`，`tests/frontend-core-tests.cs`。

**接口：** `ArtemisOS.Frontend` 命名空间；`FrontendOptions.Parse(string[])`、`ProcessIdentity`、`ProcessRunner`、`DeviceClient`、`FrontendPaths`、`ViewerArguments`。具体公开接口由主会话交接。

- [x] 先写参数转义、serial 拒绝、进程归属和截图字节验证测试，运行确认失败。
- [x] 实现原生参数构造、超时命令执行、设备操作与归属校验。
- [x] 运行测试确认通过；不对真实用户数据执行文件安装/删除测试。

## Task 2：启动与 OTA 协议

**文件：** `stage/launch.ps1`、`stage/initialize.ps1`、`stage/update/apply.ps1` 及针对性测试。

**接口：** `-ExternalDisplay -SessionId <32位GUID>`；会话文件 `data/runtime/<SessionId>.json`；命名管道名称由安装根 SHA256 和会话 ID 决定。

- [x] 先验证 ExternalDisplay/Headless 分流、会话路径和错误状态，以及更新前端退出握手的失败行为。
- [x] 实现普通 launch 委派、GUID 会话写入、无 Qt 标题初始化、OTA 自退出和旧入口保持。
- [x] 运行启动和升级相关回归，确认数据/偏好保留及不存在误杀。

## Task 3：现代原生界面及本地构建

**文件：** `desktop/frontend/Program.cs`、`NativeWindow.cs`、`ShellForm.cs`、`FrontendSession.cs`、`frontend.manifest`，`tools/Build-Frontend.ps1`、`tools/Prepare-FrontendRuntime.ps1`。

- [x] 写比例布局、显示状态和退出状态转换测试，确认失败。
- [x] 实现原生品牌外壳、向量图标、透明 logo 和独立顶层视频窗口布局；不使用 SetParent。
- [x] 实现按钮异步队列、文件对话框、状态显示、启动/关闭/重连和更新退出。
- [x] 使用系统 csc 构建 WinExe，准备已安装的固定版本运行时和第三方来源说明。

## Task 4：集成验证与交付记录

- [x] 在隔离目录验证构建/入口；准备本机原安装脚本备份。
- [x] 使用原 AVD 运行，验证实际硬件渲染、基本按钮、截图与显示正常。
- [ ] 用户或 CUA 验证拖动、缩放、最小化、跨屏；如用户停止 CUA，尊重停止并记录手测范围。
- [x] 检查退出、重启和 OTA 对前端进程的处理；记录性能及未验证事项。
- [x] 更新使用与开发文档，提供当前可运行产物路径；不混入既有不相关修改或擅自发布。

## 执行记录与裁决

- 按用户要求沿用当前项目目录及现有工作分支，保留无关改动；未清除 AVD 或 SD 卡数据。
- 显示采用已验证的独立 SDL 顶层窗口与 owner 关系，不嵌入 Emulator Qt 窗口。
- 当前交付为本机预览，尚不发布 OTA；用户要求后续涉及 UI 验收时一次列出操作，由用户确认。
- 2026-11-12 用户确认连续调音量无侧栏闪烁、“更多 → 打开运行日志”无异常、横竖屏切换后的全部应用图标排列均正常；跨屏与不同 DPI 验收项保持待验证。
- 生命周期最终回归：11 场景通过，证据 `build/frontend-session-tests-515eb9d8f6c94ab2bc3d37d6cdf5b623`；真实启动/签名升级握手回归亦已通过。
- 使用、构建、协议及待验收事项见 [原生显示前端](../../native-display-frontend.md)。
