# 硬件 ANGLE/Vulkan 实施计划

> 面向 Agent 型工作者：使用现有执行流程逐项完成；用户已明确要求直接实现，无需再次询问既定路线。

**目标：** 添加可实际运行的硬件 Vulkan 渲染选项，部署并验证本机。

**架构：** 复用官方 ANGLE，逻辑偏好 vulkan 映射到经实测有效的运行时模式与进程环境；保持 host、软件路径及用户数据。先独立 AVD 集成验证，再修改产品选择与启动策略。

**技术栈：** Windows PowerShell 5.1、WinForms、Emulator 37.3.9、ANGLE、Vulkan、ADB、scrcpy。

**规格说明：** ../specs/2026-11-11-hardware-vulkan-design.md

## 全局约束

- 默认 host，软件快捷方式仍为一次性 CPU 覆盖。
- 不修改历史发布 SDK；所有库复用现有同版本文件，不混装。
- 不删除或重建原 AVD、SD 卡、应用和用户数据。
- 外部命令使用 rtk；后台进程隐藏窗口。
- 本轮不发布 OTA，不将短测说成长期稳定。

## 审查重点

- 父进程残留的软件 ICD 不得让硬件模式假成功。
- 模式设置与实际 renderer 必须一致，错误不静默回退。
- 新偏好在读写、界面、一次性覆盖及启动器中均保持一致。
- provider 缺失/版本不符应在启动前拒绝。
- 软件及原 host 的环境和偏好不得被新路径破坏。

## 实施步骤

- [x] 隔离运行时探针：核对 provider 选择源码，在独立实验 AVD 验证 Android renderer 为 ANGLE/Vulkan/NVIDIA；记录失败与必要适配。
- [x] 编写 tests/hardware-vulkan-environment.ps1，覆盖 vulkan 偏好持久化、逻辑选择、原 host 默认、软件覆盖和坏 provider 拒绝；运行确认现有实现失败。
- [x] 修改 stage/settings.ps1、stage/launch.ps1、stage/configure.ps1，添加选择、最小 provider 校验、子进程环境及有效启动参数；运行新测试与现有图形/软件环境回归。
- [x] 验证真实启动、模块、renderer 和短录屏，按证据调整；备份并部署本机脚本，保留 AVD。配置对话框确认新选项可选。
- [x] 记录 docs/history 的实现、证据、用户操作和已知限制；独立审查相关 diff，运行必要最终检查。

验收状态：完成本机实验选项接入与同屏操作、真实 GPU、19.899 秒 H.264 全帧解码验证。跨屏仍会崩溃，未计为修复；用户明确跨屏非本次必要条件。1.0.5 未发布，当前由用户手动启动和操作，保留所有数据。
