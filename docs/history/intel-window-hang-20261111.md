# 2026-11-11 Intel Vulkan 窗口移动后停住

## 事件与结论

1.0.5 发布后，本机原生模拟器窗口继续被拖动，用户再次报告整体无响应。此前一次跨屏短测不足以证明稳定性，**Intel 模式也不能宣称解决了窗口移动故障**。

实际故障是宿主原生异常，不只是 Android 应用页面卡住：PID `18192` 的 CPU 累计值多次保持在 149.21875 秒，窗口无响应；ADB 设备仍显示在线，但 `getprop sys.boot_completed` 和 `dumpsys activity` 分别在 8/10 秒后超时。

对仍存活的进程采集小型线程转储，Windows DbgHelp `StackWalk64` 展开 121 个线程、1199 帧。异常线程 `37976` 的调用方向为：

`gfxstream → ANGLE GL_WaitSync → igvk64.dll+0x142981 → KiUserExceptionDispatcher → UnhandledExceptionFilter`

从该线程捕获栈中恢复出布局匹配的 `EXCEPTION_RECORD64` 和 AMD64 `CONTEXT`：`0xC0000005`，读取地址 `0xC`，`RBX=0`。模块为 Intel Vulkan 驱动 `32.0.101.7088`。本次 NVIDIA 线程处于等待；不能用 NVIDIA DLL 被加载来认定本次仍是 NVIDIA 故障。

异常发生在驱动中，不足以区分驱动本身、ANGLE 调用或 gfxstream 图形对象生命周期的责任；更不能据此认定自动化工具或测试应用造成了崩溃。Windows 同时记录了 `crashpad_handler.exe` 的 `0x80000003`，该异常是崩溃收集器自身的问题，不能替代恢复出的原始异常。

## 源码交叉核对

- `build/hardware-vulkan-source-20261111/emulator-qt-window.cpp`、`window.c`：跨屏及部分窗口刷新会请求 `show_opengles(deleteExisting=true)`，销毁并重建原生子窗口和 EGL surface。触发条件不能只限定为更换显卡，也不能简单限定为 DPI 改变。
- `angle-SyncVk.cpp`：`GL_WaitSync` 的实现会检查完成状态、必要时提交共享 context 的延迟命令。此栈不等于普通的同步等待超时。
- `angle-CommandProcessor.cpp`：检查完成批次会查询 Vulkan fence。原生访问冲突不能由后续的 `VkResult` 错误处理恢复。
- 未发现可确认修复这次 Windows/Intel 故障的官方配置开关；此前 NVIDIA 上禁用异步队列、固定 DPI 和 D3D11 尝试也没有成为有效修复。

## 本机隔离与恢复

保存现场后只终止已核对路径和启动时间的故障 PID。通过既有 `launch.ps1 -Headless -Port 5554` 启动同一份可写 AVD；偏好仍为 `graphics=vulkan_intel`。未删除或重建应用、userdata 和 SD 卡。

后台为 `qemu-system-x86_64-headless.exe`，启动完成后 SurfaceFlinger 再次确认 `Intel(R) UHD Graphics 770`、ANGLE Vulkan `1.4.323`，不是 CPU 渲染器。

临时显示端使用本机已安装的官方 scrcpy 4.1，固定使用本安装的 ADB；H.264 `c2.android.avc.encoder`、最大 1280、20 fps、4 Mbit/s、SDL `direct3d`、关闭音频转发。没有启用录屏文件保存。这里的视频编码/显示与 Android 的 GPU 渲染是不同环节，不能据 H.264 编码器推断已改成 CPU 图形渲染。

独立窗口曾经由 Win+Shift+Right 跨屏后显示 Android 桌面，用户随后反馈“好像没问题了”。进一步自动连续移动因检测到用户正在操作而未执行，**没有十次跨屏通过的证据**。目前是短时隔离成功，尚未覆盖长时间视频、所有用户显卡或完整应用回归。

独立窗口是本机临时诊断方式，尚未接入正式启动/退出生命周期；关闭显示端不等于后台模拟器退出。1.0.5 OTA 没有包含这个前端，原有桌面入口也尚未切换。

## NVIDIA 独立实例补充验证

用户进一步询问独显是否可以采用同样结构。尝试在当前可写 AVD 旁增加同 AVD 只读实例时，Emulator 主动拒绝并退出，未改原实例；随后改用工作区内全新的 `ArtemisOS_NV_Headless` AVD，端口 `5576`、只读启动。

该独立实例实际启动完成，SurfaceFlinger 确认 `NVIDIA GeForce RTX 3080 Ti`、ANGLE Vulkan `1.4.357`、驱动 `621.14.0.0`。显示端仍为 scrcpy H.264/SDL direct3d，标题 `ArtemisOS NVIDIA isolated test`。原 Intel 实例 `emulator-5554` 与原有应用数据未切换。

新窗口打开后，用户反馈“非常流畅而且跨屏幕没问题”。用户按物理 Escape 停止自动界面控制，因此仅记录手动反馈，不声称完成了自动十次跨屏。此证据支持继续产品化独立显示层，不能代替视频负载、长期运行和不同显卡的回归验证。

这台主机枚举到两个不同 PCI 设备地址、同名的 RTX 3080 Ti。当前按设备名称选择 ANGLE NVIDIA，无法单凭 SurfaceFlinger 的同名结果判断实际选中了其中哪张卡；暂不能推广为所有多 GPU 组合已兼容。

最小证据为 `docs/history/evidence/intel-window-hang-20261111/independent-viewer-feedback.json`。用户提出可在独立窗口旁加控制按钮；目前仅讨论正式前端方向，尚未将显示程序或控制栏加入 OTA。

## 原始证据

本机 `build/intel-hang-20261111-223142/` 保存捕获脚本、小型转储、解析结果、全部线程栈、恢复出的异常结构、Windows 事件和独立窗口日志。转储含进程内存，仅留本机；可提交的最小摘要保存在 `docs/history/evidence/intel-window-hang-20261111/exception-summary.json`。
