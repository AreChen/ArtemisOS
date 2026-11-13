# 隔离实例体积与性能测量

这些工具只读取已有文件或指定的隔离 QEMU 进程，不启动、关闭或修改实例。它们与 `tools/image-lab/Test-Candidate.ps1` 配合使用；后者负责创建独立 AVD、运行功能探针和清理进程。先用同一安装器和两组完整 SDK/镜像分别准备独立目录，不要原位更改通过硬链接共享的镜像。

## 体积

为每个安装包与 SDK 各运行一次（输出文件必须不存在）：

```powershell
rtk proxy powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\benchmark-lab\Measure-Footprint.ps1 `
  -SdkRoot '<独立 SDK 目录>' -Installer '<完整安装包.exe>' `
  -Output '<已存在的结果目录>\footprint.json' -HashInstaller -HashSystemImage
```

结果将 Windows 安装包的实际字节数、SDK 按一级目录统计的文件逻辑大小、`system.img` 的逻辑大小和 `GetCompressedFileSizeW` 结果分开记录。后者可体现 NTFS 稀疏/压缩文件的空间，但不包含所有文件系统开销，也不去重硬链接；重解析点不递归并记录在跳过清单。测试的是传入目录，若传入构建输入，不能称作用户的安装后占用。要测安装占用，请指向独立全新安装得到的 SDK，并单独记录用户数据、快照及安装高峰占用。

安装包以 Inno Setup 固实压缩：**只有比较实际完整安装包才能得出下载体积的变化**。各文件原始长度或各自单独压缩的结果不能直接相加计算安装包体积。两次打包须固定 Inno 版本、压缩参数、输入和排除规则，并记录 SHA-256、构建耗时和解压耗时。

## 独立 QEMU 采样

准备两个终端。目录 `build\benchmark-lab` 事先创建；下面的 `case-baseline-01` 必须是尚未被 `Test-Candidate.ps1` 使用的目录。先在终端 1 启动监测：

```powershell
$root = 'E:\Project\CodeProject\ArtemisOS'
$runtime = Join-Path $root 'build\slim-sdk-0.3.5-pilot'
$case = Join-Path $root 'build\benchmark-lab\case-baseline-01'
rtk proxy powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$root\tools\benchmark-lab\Monitor-IsolatedQemu.ps1" `
  -TestRoot $case -QemuExecutable "$runtime\emulator\qemu\windows-x86_64\qemu-system-x86_64-headless.exe" `
  -AvdName 'ArtemisBenchBaseline01' -Port 5578 `
  -Output "$root\build\benchmark-lab\baseline-01-metrics.json" `
  -IntervalSeconds 5 -WaitSeconds 300 -DurationSeconds 1200
```

在终端 2 使用完全相同的测试目录、AVD 名称、端口和运行时启动 `Test-Candidate.ps1`；下例使用当前已准备的探针路径，应先确认文件仍存在：

```powershell
$root = 'E:\Project\CodeProject\ArtemisOS'
$runtime = Join-Path $root 'build\slim-sdk-0.3.5-pilot'
$case = Join-Path $root 'build\benchmark-lab\case-baseline-01'
rtk proxy powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$root\tools\image-lab\Test-Candidate.ps1" `
  -CandidateImage "$runtime\system-images\android-35\google_apis\x86_64\system.img" `
  -BaseImageDir "$runtime\system-images\android-35\google_apis\x86_64" -RuntimeSdk $runtime `
  -ArmApk "$root\build\image-refine-20261031\arm64-probe-token\arm64-v8a-probe.apk" `
  -X86Apk "$root\build\image-refine-20261031\x86-probe\x86_64-probe.apk" `
  -WebApk "$root\build\image-refine-20261031\webview-probe-v2\webview-probe.apk" `
  -Output $case -AvdName 'ArtemisBenchBaseline01' -Port 5578 -ExpectedRemovals absent
```

监测仅接受 `build/` 或专用 `ArtemisOS-image-lab` 临时目录下的测试目录，并按 QEMU 可执行文件完整路径、AVD 名称、端口和隔离 `sysdir` 同时匹配；还检查控制台端口本地绑定的 PID 属于该 QEMU 或其已验证的 emulator 父进程。部分 Windows 版本上 CIM 的监听状态可能为空，因此这里不声称独立验证了端口的监听状态；测试脚本负责验证 ADB 目标。发现多个匹配或端口归属其他进程时停止。

两次冷启动分别形成独立 PID 的采样会话，测试的 `test-results.json` 出现且 QEMU 退出后结束；默认要求观察到两次启动，否则采样不完整。超时也标记为不完整；`complete` 表示采样结束而非兼容性测试通过，应另查 `test-results.json` 的 `accepted`。监测输出位于测试目录外，不能占用测试尚未创建的目录。

QEMU 进程工作集反映其在宿主中的驻留内存，私有字节反映其私有提交量；它们不是完整模拟器或安卓系统的总内存。CPU 百分比同时给出以一个逻辑核为 100% 和以整机逻辑核容量为 100% 的口径，采样窗口使用单调时钟并记录实际时长，第一条样本没有可计算的 CPU 百分比。峰值是各离散样本中的最大值，可能低于瞬时峰值。以上数值均不包含其他 emulator 进程、GPU/驱动及 Windows 可能单独归属的虚拟化开销。采样覆盖启动和运行测试探针的阶段，不能直接当作空闲功耗或负载。启动耗时、系统服务稳定性和兼容性以同一次 `test-results.json` 为准。

## 比较方法

- 对基线和候选使用相同的宿主、Windows 电源模式、Emulator 版本、虚拟 CPU/内存、图形后端、分辨率、磁盘及探针；串行运行，记录宿主当时其他负载。
- 交替进行基线与候选，至少重复三组；分别报告全新数据的首次启动和沿用同一数据目录的第二次冷启动，保留每次完整结果及范围，不把最好的数字当平均表现。
- 在待测低配置笔记本上另外实测可用内存、页文件压力、启动完成与持续就绪时间、图形后端及应用操作。高性能台式机的结果不能替代低配置电脑结论。
- 用户体验还应覆盖有窗口与无窗口、硬件与软件渲染、ARM64/x86_64、WebView、网络、摄像和代表性 App；以上采样脚本本身不证明这些能力通过。

`tests/benchmark-monitor-selftest.ps1` 使用两个同名、不同路径的短寿命合成进程检查监测器只采集精确目标；它不启动 Android 模拟器。
