# ArtemisOS 本机 secure 显示服务（scrcpy 4.1 派生版）

此目录提供专用 Android Java server 的源码补丁和新增源码。Windows 的官方
scrcpy 4.1 C client、SDL/FFmpeg 和控制/视频协议不变。不是官方 scrcpy 新版本。
上游源码继续使用 `third-party/scrcpy-4.1/source-archives/scrcpy-4.1.tar.gz`，
SHA256 `537b2ade623cb94b6edddfa5c61bf0b0af21484aa8365ea2531b686ea573249a`。
现有上游源码包、公开 manifest 和其他运行时文件不由本工具修改。

## 目的及边界

Android 15 密码等 `FLAG_SECURE` 窗口在普通非 secure 虚拟显示器上为黑色。
本专用服务只用于 ArtemisOS 自有、本机可控的 Android 系统的本机显示。
它为默认 display 0 创建 `SECURE | AUTO_MIRROR`（4 | 16）虚拟显示，
保留应用自己的 `FLAG_SECURE`，不执行 `adb root`、不修改系统属性、
不切换全局 SELinux 模式，不修改全局截屏/录屏策略。

**这仍然是有意提高本服务的采集权限。** 密码等 secure 窗口会作为编码帧到达
Windows 进程；在 Windows 端截图/录屏或改用客户端 `--record` 都可能保存这些内容。
不能声称“只是显示，所以敏感内容不可记录”。不要将本专用 jar 当成通用远程录屏
工具分发或用于不受信的设备/观看端。它不保证 DRM / protected-buffer 内容能显示。
标准 `adb shell screencap` 仍走 Android 自己的权限检查，预期继续遮黑 secure 页面；
必须通过独立测试 APK 实测确认，不能由编译成功推断。

## 实现

- `Server.main` 在 shell UID 下使用独立 argv 的 `ProcessBuilder` 运行
  `su 0 /system/bin/app_process / com.genymobile.scrcpy.Server <原参数>`。
  `CLASSPATH` 和标准输入输出保持传递，shell 包装进程 `waitFor` 并转发退出码。
  环境中的重启标记防止 `su` 未授予 UID 0 时无限重启；失败明确报告。
- root 子进程不执行上游 `dropRootPrivileges()`。不会修改 adbd UID。
- AOSP `su` 直接 exec app_process。root 子进程每 500 ms 检查 PPID；包装进程
  消失时退出，避免握手前或 socket accept 阶段留下 root 服务。
  另设 10 秒有限握手期限：只有 `DesktopConnection.open` 完成全部视频/控制
  socket 连接后才通过 volatile 标记解除期限。若 client 在连接前消失，而宿主
  adb shell 与包装进程仍活着，仍会明确记录超时错误并退出；检查间隔 500 ms。
  已经以 UID 0 直接启动、没有包装进程的服务也执行同一握手期限，只跳过 PPID 检查。
  这只是初始连接期限，不会在正常播放达到 10 秒时断开；连接后继续依靠 socket
  EOF 与父进程监测清理。启动极慢、无法在该期限完成连接的客户端需要重新连接。
  保留官方 socket EOF、编码器停止和 CleanUp 清理流程；退出期间短暂出现单独
  CleanUp 子进程是设计行为。其他 su 实现可能 fork；不在支持范围内。
- Android 15 的静态 DisplayManager 五参数 helper 只传 AUTO_MIRROR，不能沿用。
  改用已有的 Context / FakeContext 实例 API，显式传 secure mirror flags。
  仅支持默认 display 0；其他镜像 display ID 明确拒绝。兼容 SurfaceControl 的
  回退也要求 secure=true；若两个 API 都不支持，报错，不静默转成非 secure 镜像。
- 需要系统具备可用的 AOSP `su`（本项目 userdebug/eng 系统）。普通 user 系统或
  无 root 的真机不支持。AOSP userdebug/eng 的 su 使用独立 permissive SELinux
  domain；这与全局关闭 SELinux 不同，但服务自身权限确实更大。

### 剪贴板限制

上游故意降权的原因是 root 运行时剪贴板互通问题（上游 #6224）。本版本为显示
保留 root，因此**不能承诺剪贴板双向同步可用**。不能把镜像成功当成剪贴板成功；
要分别测试 Android→Windows、Windows→Android 和文本输入。不要通过移除应用
secure 标志或全局放宽 AppOps 来修复。需要时在产品层明确禁用/提示不支持的剪贴板
功能，或后续将 shell 控制服务与 root 显示服务拆开；本补丁没有增加这套架构。

## 在 Windows 重建

需要 JDK 21、Android SDK platform 36、build-tools 36.0.0、Git、tar 和 RTK。
不需要 AOSP、Gradle、WSL 或联网下载依赖。由项目根目录执行：

```powershell
rtk proxy powershell.exe -NoProfile -File tools/Build-SecureDisplayServer.ps1
```

可用 `-AndroidSdk`、`-JavaHome`、`-OutputDirectory` 指定已有工具路径。
工具先校验上游 tar 的固定 SHA256，在唯一 build 工作目录解包并应用补丁，
按上游 `server/build_without_gradle.sh` 的 AIDL→javac→D8 流程构建。
为避免 Windows AIDL 相对 import 问题使用绝对路径；D8 输入为临时 classes.jar。
SDK、原始 tar 和已安装模拟器均不修改。

输出：

- `build/secure-display-server/scrcpy-server`：包含 classes.dex 的 zip/jar。
- `manifest.json`：variant、revision、server / upstream archive / patch / policy SHA256。
- `build-record.json`：工具版本、构建输入、源码工作目录及构建时间；不表示实机通过。
- `work-<GUID>/scrcpy-4.1/`：本次应用补丁后的完整源码，可直接审阅。

源码分发应包含本目录（含 LICENSE、NOTICE、patch、src）、构建工具与现有上游
4.1 源码归档。原有 Windows client 和 FFmpeg 等许可证要求继续适用；本目录没有
替代它们的 source/notice 包。

安装目录附带的 `third-party/artemis-display` 是轻量重建材料，而非完整项目。
重建时将该目录复制为项目的 `third-party/artemis-scrcpy-display`，将其中
`Build-SecureDisplayServer.ps1` 放到项目 `tools/`，`secure-display-server.ps1` 放到
项目 `tests/`，并从既有公开源码包恢复上述固定哈希的上游 tar 路径。Java policy
测试源码已在此目录的 `tests/` 中。所有这些工具只在开发端运行。

## 验证

`tests/secure-display-server.ps1` 会验证实际构建源码的安全约束，并以 JDK 运行
真实纯 Java policy 测试：secure flags、shell 重启、root 不重启、su 失败不递归、
原 client argv 完整保留。测试由构建工具自动运行，也可单独执行。

已经验证：未修改的上游源码首先在“不能降回 shell”断言失败（RED）；
修改后源码约束、policy 测试、Android 36 javac/AIDL/D8 编译通过（GREEN）。
集成方已在本机对最终 r2 构建（server SHA256
`a18a94bf9042dd496dc3d714d788146ef3eaf0f08d9c8c2e518c838e7f697dfc`）实测：

- reverse 和强制 forward 两种连接：建立连接并开始播放后强杀独立测试 client，
  主 Server 和 CleanUp 最终均无遗留。
- 单独启动强制 forward 服务且没有 client 连接：出现 10 秒握手超时错误后退出，
  主 Server 和 CleanUp 均无遗留。

这些结果覆盖定向测试场景，不表示所有应用、su 实现或启动负载都已经验证。
最终 revision `artemis-secure-display-r2` 另修正了无 wrapper 的直接 UID 0 启动也
执行期限；该版本已通过构建、定向源码测试及上述三项实机回归。
以下实机项目由集成方执行，本目录的构建步骤不连接或重启模拟器：

1. 普通测试 APK 的显示/输入/旋转与此前一致，client 版本仍是 4.1。
2. 独立 APK 打开 FLAG_SECURE：专用镜像可见；标准 shell screencap 仍遮黑。
   关闭 FLAG_SECURE 后二者都正常。不得使用真实密码作为测试素材。
3. root 服务退出后应用 FLAG_SECURE 仍在；普通 scrcpy 仍遮黑。
4. 正常关闭、强制关闭 client、连接建立前关闭 client、快速重连：无遗留主 Server、
   编码器或 socket；CleanUp 最终退出。需要分别覆盖 forward 和 reverse 连接。
5. su 不存在/拒绝、root 子进程失败：明确报错、非零退出、不无限启动、不静默降级。
6. 单屏、跨屏、Windows DPI/分辨率变化：继续使用原 SDL Direct3D 显示链路，
   但仍需回归；本补丁不能单独证明跨屏稳定性。
7. 剪贴板双向传输单独验证；任何受限操作不得给用户显示虚假的成功状态。

## 依据（均核对 Android 15 / scrcpy 4.1 源码）

- [scrcpy 4.1 Server / 上游降权](https://github.com/Genymobile/scrcpy/blob/v4.1/server/src/main/java/com/genymobile/scrcpy/Server.java)
- [scrcpy 4.1 DisplayManager wrapper](https://github.com/Genymobile/scrcpy/blob/v4.1/server/src/main/java/com/genymobile/scrcpy/wrappers/DisplayManager.java)
- [Android 15 DisplayManager flags / helper](https://android.googlesource.com/platform/frameworks/base/+/android-15.0.0_r1/core/java/android/hardware/display/DisplayManager.java)
- [Android 15 DMS 权限与 root package 验证](https://android.googlesource.com/platform/frameworks/base/+/android-15.0.0_r1/services/core/java/com/android/server/display/DisplayManagerService.java)
- [Android 15 VirtualDisplayAdapter](https://android.googlesource.com/platform/frameworks/base/+/android-15.0.0_r1/services/core/java/com/android/server/display/VirtualDisplayAdapter.java)
- [SurfaceFlinger secure virtual display 限制](https://android.googlesource.com/platform/frameworks/native/+/android-15.0.0_r1/services/surfaceflinger/SurfaceFlinger.cpp)
- [AOSP su 参数、环境和 exec](https://android.googlesource.com/platform/system/extras/+/android-15.0.0_r1/su/su.cpp)
- [AOSP su SELinux domain](https://android.googlesource.com/platform/system/sepolicy/+/android-15.0.0_r1/private/su.te)

## 对应源码下载

本版本专用源码与固定上游归档：
https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/sources/ArtemisOS15-Secure-Display-Sources-1.0.9-r2.zip
