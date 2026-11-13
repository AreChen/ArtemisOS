# ArtemisOS 15 1.1.1：可配置前端帧率

状态：2026-11-13 发布 OTA。本次不构建完整安装包，不替用户升级本机正在运行的 1.1.0 实例。

## 使用

通过现有“检查更新”入口，将 1.1.0 升级至 1.1.1。应用、Android 用户数据、渲染设备及前端偏好继续保留。

配置新增“显示帧率上限”：

- 20 FPS：省资源。
- 30 FPS：均衡。
- 60 FPS：流畅，默认上限。
- 自定义：整数 1–240 FPS。

保存后重新启动模拟器生效。该设置只控制 ArtemisOS 自定义前端的画面采集帧率上限；选择 Emulator 原生前端时，相关控件禁用，原数值保留。

此前自定义前端固定传入 `--max-fps=20`，即使 Android 显示刷新率为 60 Hz，也会限制采集帧率。现在每次启动或重新连接显示窗口时读取 `data/preferences.ini` 中的 `max_fps`，缺失或无效时使用 60。原有调用方保存其他配置时，会保留此值与未知偏好。

60 是上限，不保证每个应用达到 60 FPS。Android 显示刷新率、应用绘制、视频源和编码性能均可能限制实际帧数；自定义超过 60 不会自动提高 Android 刷新率。继续使用 H.264 软件编码、4 Mbps 及原有最大画面尺寸，提高上限可能增加 CPU 占用。性能较弱的电脑可以选 20 或 30。

## OTA 与验证

1.1.0→1.1.1 共 4 个完整变化文件，300,805 字节（约 294 KiB）：

- `configure.ps1`
- `settings.ps1`
- `version.ini`
- `update/frontend/ArtemisFrontend.exe`

Android 镜像、Emulator、图形库、安全显示服务及其他运行时不变。不下载或上传镜像，不删除用户数据，不更新调试符号。保持清单签名、对象大小和 SHA256、旧文件 SHA256 校验，仍按当前版本逐级升级。

已完成：

- Windows PowerShell 5.1 偏好和配置测试 384 项，覆盖严格整数范围、默认值、旧调用方、自定义值及原有偏好保留。
- 纯 C# core 24 组，包含动态 FPS 参数、边界和非法值、每次读取偏好；完整前端编译成功。
- 原有前端偏好 60 项、AMD 合成设备回归 49 项通过。
- 隔离构造且不显示的 WinForms 配置 UI 测试 24 项通过：预设、自定义 77、原生前端切换、数值同步、当前宿主字体和 DPI 下的说明文字及按钮布局。
- 三份冻结 1.1.0 基线实际执行升级、中断恢复、前端程序回滚、再次升级及最新无更新清单验签；旧偏好无 FPS 字段和自定义 144 均逐字节保留，样本应用及用户文件保留。
- 旧设置/前端文件冲突、清单篡改、错误签名、对象哈希或大小错误均拒绝。

未对正在运行的本机实例做 60 FPS 性能测量，未重启或升级该实例。上述自动化使用隔离目录，不启动 Android；实际画面流畅度、CPU 变化和 OTA 交互由用户在本机自行升级后确认。隐藏 UI 测试不等于所有 DPI 的视觉验收。

永久 OTA 地址仍为 `https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/`。匿名 HTTPS 跳转至天翼云，临时签名 URL 不写入配置，不修改 OpenList 全局代理或分享设置。发布顺序为验证对象、最新无更新清单、最后发布旧版本升级清单与签名；固定路径配对仍非原子，客户端配对验签失败会停止或重新获取，不会跳过验签。

本地生成记录位于 `build/release-1.1.1/`，不提交 Git：`product-verification.json`、`ota-test-result.json`、`live-after-publication.json`、`publication.json`、`live-preservation.json`。公开仓库保存测试源码与本说明，不提交运行证据、构建产物或用户数据。

本次没有 1.1.1 完整安装包。全新用户可以安装 [1.1.0 完整包](https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/installers/ArtemisOS15-Offline-Installer-1.1.0.exe)，再检查 OTA 升级。
