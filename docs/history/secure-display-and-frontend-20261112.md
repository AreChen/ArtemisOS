# 安全页面显示与前端切换（开发修复）

状态：修复已随 [1.0.9 安装包和 OTA 发布](release-1.0.9-secure-display.md)。本页保留开发过程与验证边界；公开 1.0.8 产物和历史基线未修改。

## 根因与实现

上游 scrcpy 4.1 的默认 DisplayManager 镜像只含 AUTO_MIRROR，缺少 SECURE；Android 15
因此遮黑应用的 FLAG_SECURE 窗口。原生 Emulator 直接显示模拟屏幕。本次合成 APK
对照确认了此原因，与宿主 GPU 型号或 Vulkan 后端无关。

- `stage/settings.ps1` 增加 `frontend=artemis|native`，旧配置默认 artemis。
  旧位置参数写入保留前端偏好，同时保留未知配置键。
- `stage/configure.ps1` 增加“显示前端”下拉；关闭整个模拟器，再从桌面启动生效。
  命令行支持 `-NoGui -SetFrontend native` / `artemis`。
- `stage/launch.ps1` 先读偏好，再选择窗口。native 不委托自定义窗口，自动化 Headless
  和带身份校验的 ExternalDisplay 协议保持有效。
- `third-party/artemis-scrcpy-display` 提供专用 Java server 的补丁和新增源码，
  `tools/Build-SecureDisplayServer.ps1` 使用固定哈希的上游归档重建。
- 专用服务通过 AOSP `su 0` 仅提升自己的进程权限，为默认屏幕创建 SECURE | AUTO_MIRROR。
  没有执行 adb root、修改应用 FLAG_SECURE、放宽 SELinux 或系统截图策略。
  父进程监测和 10 秒握手期限负责异常退出；Windows 客户端、SDL、FFmpeg、镜像及渲染后端不改。
- `tools/Prepare-FrontendRuntime.ps1` 校验 server、上游归档、补丁、policy 和构建工具哈希，
  复制派生产物及源码、构建说明、许可。缓存过期报错，不会静默装回非 secure 服务。

## 实机证据

合成包 `com.artemisos.securedisplaytest` 只显示固定颜色和文字，不含密码或个人数据。
构建入口 `tests/Build-SecureDisplayFixture.ps1`，输出 `build/secure-display-fixture/`。

| 场景 | 画面中心 RGB | 结果 |
| --- | --- | --- |
| 普通页面，官方 scrcpy | 30, 95, 217 | 蓝色页面正常 |
| FLAG_SECURE 页面，官方 scrcpy | 0, 0, 0 | 复现遮黑 |
| FLAG_SECURE 页面，专用 server | 15, 178, 82 | 绿色页面正常 |
| 专用服务工作后，普通 ADB 截图 | 0, 0, 0 | 系统截图继续遮黑 |

自定义窗口和原生窗口均实际显示绿色安全测试页。native 启动时没有自定义前端，
关闭原生窗口后 Emulator 和更新 bridge 随之退出，随后恢复 artemis 偏好。

检查入口：

- `tests/frontend-preference.ps1`：60 项配置保留、分流和身份校验。
- `tests/frontend-launch-lifecycle.ps1`：启动、状态及真实有签名更新 fixture。
- `tests/secure-display-server.ps1`：源码约束和真实 Java policy，由构建自动执行。
- `tests/frontend-secure-runtime.ps1`：派生产物来源、源码材料、宿主二进制保持原样。
- `tests/secure-display-lifecycle-live.ps1`：reverse/forward 连接完成后强杀测试客户端，
  以及无客户端的 forward 服务有限超时；只操作测试连接。

曾发现额外边界：forward 握手未完成时杀客户端，host ADB 和 Android shell 包装仍可能
存活，单靠父 PID 无法收尾。10 秒握手期限修复此项，超时必须明确报错。

## 范围与限制

测试覆盖自有 Android 15 镜像的 FLAG_SECURE 默认屏幕；具体业务 APP 的原始密码页仍需用户
复测，不能据此推断 DRM/protected-buffer 视频支持。本次未重做 Sunshine / 多屏长时测试。

安全窗口会作为编码帧送到 Windows，宿主截图或使用派生服务另行录制时可能保存这些帧，
不能声称“只能看、不能记录”。普通 shell 截图仍按原安全策略处理。
上游 root 模式的剪贴板兼容风险仍需双向实测，不把 scrcpy ACK 当成写入成功。

JDK / Android SDK 仅为开发端重建依赖，最终用户无需安装。既有 Android 用户数据、应用、
登录状态及文件保留。本机覆盖前的脚本与 server 备份位于
`build/secure-display-integration-backup/`。配置窗口的新增行需人工复核多种 DPI 下的布局。
