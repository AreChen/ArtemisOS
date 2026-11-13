# Sunshine 虚拟显示器切换：前端画面恢复

## 现象与证据

2026-11-12，已发布的 ArtemisOS 1.0.6 经 Sunshine 切换虚拟显示器或 Windows 显示环境后，视频冻结在窗口左上角，外壳仍显示已连接，布局留下大片黑区。

原会话 `7a909f0150674645a15fc8e0036a6b1c`，frontend PID 57192，Emulator wrapper PID 48320，QEMU PID 53864。前端日志 `E:\ArtemisOS15\data\logs\frontend\frontend-20261112-013413-7a909f01.log` 自 09:46:20.916 起连续报告 `ERROR: Frame update failed`。scrcpy 使用 `Renderer: direct3d`，原 Texture 为 576×1280。

故障时 ADB、Android 时钟、启动完成属性和系统截图正常，Android 崩溃缓冲未见输出。仅执行“更多 → 重新连接画面”，未重启 Android，画面与布局即恢复；用户也确认“重新连接画面OK了”。

结论：本次直接故障位于 Windows 显示前端的渲染恢复；这与 Android 后台的 NVIDIA / ANGLE / Vulkan 是不同层。日志未记录 Direct3D HRESULT，不能据此宣称具体驱动错误码或所有卡死均已定位。SDL D3D9 的设备丢失与重置路径是源码线索，仍需真实 Sunshine 切换验证新策略。

调查证据保存在本机忽略目录 `build/sunshine-display-20261112`；包含原日志、会话、Android 截图和回归输出，不随公开补丁分发。

## 修复范围

- `DisplayRecovery.cs`：仅统计明确的帧更新错误，2 秒内连续 3 条才触发；静止画面不触发。每轮至多自动尝试 3 次，另有每分钟至多 3 次的限流；慢失败跨越分钟窗口也不能无限重试。
- `FrontendSession.cs`：自动恢复只重建本会话的 scrcpy，保留 Android 后台、应用与数据；不抢焦点。重连与失败清理共用串行锁，旧进程回调不能影响替代进程。故障检查、Ready 发布和恢复任务交接使用同一状态锁；关闭或 OTA 交接会终止恢复。
- `ShellForm.cs`：显示器变化、分辨率与 DPI 消息合并延迟 1 秒，重新计算布局、定位显示窗口并请求重连。恢复失败显示明确的手动重连入口，不再把停住的旧画面当作已连接。

不变更用户保存的 GPU/渲染偏好，不替换 Emulator、SDL、驱动或系统镜像。未改用未经验证的 D3D11 后端。

## 验证与发布状态

TDD 证据：旧代码在 `renderer-reset` 场景失败；替代窗口启动即报错曾暴露漏重试；慢失败策略在 0/31/62/93 秒复现无界重试，均有对应 RED/GREEN 日志。审查发现的失败清理与并发手动重连竞态也已修复，并加入真实进程场景。

最终 17 个隔离生命周期场景全部通过（`frontend-session-tests-092db0c6c3ed49ce8c59e5f268723deb`，退出码 0）；策略与 5 次 DPI 消息测试通过；候选原生前端成功构建，EXE SHA-256 为 `dd30ead542c75b8424bc64544f2adad85e11243c775ec5a9df0eed9c6771dbfd`。隔离场景不操作真实 AVD。真实 Sunshine 切换仍需用户完成，不以模拟 Windows 消息代替硬件环境验收。

本次为本机修复候选，尚未上传或替换公开 1.0.6。候选与本机安装/备份 SHA 记录分别见 `build/sunshine-display-20261112/frontend` 和安装后生成的 `local-install.json`。本机替换前备份原 EXE/PDB，保留 AVD 与配置。未来公开发布须基于冻结基线生成补丁；本机预览文件需单独恢复或迁移，不能放宽 OTA 基线哈希检查。

10:11 本机安装候选并从原 `start-auto.vbs` 入口启动，备份为 `E:\ArtemisOS15\data\backups\frontend-display-recovery-20261112-101118`。`preferences.ini` 与 `setup-state.ini` 的 SHA-256 安装前后相同。新会话 `2dc2fc02a5a94a8c9b9d31cf25343813`，前端 PID 41452，仍使用 NVIDIA RTX 3080 Ti / ANGLE / Vulkan；10:12 可视检查桌面完整填充视频区域、工具栏与底栏正常。用户后续在真实 Sunshine 切换中确认“自动恢复正常，就是恢复有点慢”，约 2 秒防抖及稳定等待加视频初始化是当前预期，并要求发布 [1.0.7 OTA](release-1.0.7-display-recovery.md)。
