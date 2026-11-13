# product 分区精简实验

`prepare-product-removal.py` 只读取独立导出的 product 分区，校验文件大小、ext4 标识及实验所用版本的 SHA-256，然后生成 18 个文件对应的 debugfs 命令。它不执行命令，不修改镜像，也不构建或发布安装包。

在 WSL 中从项目根目录运行，指定一个尚不存在、位于 `build/` 下的输出文件：

```bash
rtk proxy python3 tools/image-lab/prepare-product-removal.py \
  --product-image build/image-lab/product-original.img \
  --output build/image-lab/removal-commands.debugfs
```

输入应是本次实验记录中从原始 system.img 导出的分区副本，不能换成其他版本。生成的命令只能用于另一份独立的、可丢弃的分区副本；执行后还需要修复并检查 ext4 分配信息，再做空闲块清理和启动测试。原始镜像可能与其他路径硬链接，绝不能对其直接写入。完整的实验结果和限制记录在 `docs/history/系统参数对比与镜像实验-20261031.md`。

## 进一步精简实验

`build-extra-slim.py` 从现有 0.3.4 镜像生成**独立的实验副本**，移除 Google 搜索、设备智能与个性化、数字健康、Android Auto 存根及图片标注。它保留 Google Play services、WebView、ARM64 转译、输入法、短信和文字转语音。这些删减会影响对应功能，仍须完成兼容性、许可及产品发布检查。

该构建脚本仅接受本文实验所用的特定 product 哈希，逐字节检查其在 system 镜像中的位置；镜像版本变化时不得沿用偏移。它通过复制创建文件，不修改输入，在新目录中留下 `manifest.json`、debugfs 命令及 ext4 检查日志。使用 `shared_blocks` 的 ext4 不可直接调用 `debugfs rm`。以下命令在 WSL Debian 的项目根目录中执行；输出目录必须尚不存在、且位于 `build/` 下：

```bash
rtk proxy python3 tools/image-lab/build-extra-slim.py \
  --disk build/slim-sdk-0.3.4/system-images/android-35/google_apis/x86_64/system.img \
  --product build/image-lab/product-experiment.img \
  --output build/image-refine-20261031/rebuild \
  --rtk /root/.local/bin/rtk --debugfs /usr/sbin/debugfs --e2fsck /usr/sbin/e2fsck \
  --zerofree build/image-lab/zerofree-root/usr/sbin/zerofree
```

构建依赖本机已有的 WSL e2fsprogs 和 zerofree；这只是开发时构建环境，不是 Windows 用户运行依赖。产物 `system.img` 的原始文件长度不变，新空闲区域归零后才能在压缩传输时体现节省。可使用 `measure-xz.py` 对两个 product 分区做相同的 XZ 参数对照；结果是分区压缩流的测量，不等于安装包大小。

`Build-X86Probe.ps1` 和 `webview-probe/Build-Probe.ps1` 使用已安装的 SDK/NDK 构建探针。前者默认生成 x86_64 探针，使用 `-Abi arm64-v8a` 可从同一新版源代码生成包含运行令牌的 ARM64 探针；旧 APK 若不含令牌，不能用于本脚本。`Test-Candidate.ps1` 在新的独立 AVD 目录和用户指定端口中复制完整同源镜像目录与候选 `system.img`，再检查冷启动、设置、两种 ABI 的 JNI、WebView、Google Play services 的基础绑定、DNS/TCP 以及时区和语言；完整结果以运行生成的 `test-results.json` 为准。目录中的 `data/empty_data_disk` 等同源文件不可遗漏，测试 AVD 不读取既有用户数据。该测试并不等于所有应用、Google 账号登录或 Google API 已通过验证，也不能代替安装包在全新环境下的首启验证。

本机 Windows 上的候选测试示例（输出目录和 AVD 名必须未被占用，端口需保持空闲）：

```powershell
rtk proxy pwsh -NoProfile -NonInteractive -File tools/image-lab/Test-Candidate.ps1 `
  -CandidateImage E:\Project\CodeProject\ArtemisOS\build\image-refine-20261031\candidate-a\system.img `
  -BaseImageDir E:\Project\CodeProject\ArtemisOS\build\image-lab\sysimg `
  -RuntimeSdk E:\AndroidOfflineEmu\sdk `
  -ArmApk E:\Project\CodeProject\ArtemisOS\build\image-refine-20261031\arm64-probe-token\arm64-v8a-probe.apk `
  -X86Apk E:\Project\CodeProject\ArtemisOS\build\image-refine-20261031\x86-probe\x86_64-probe.apk `
  -WebApk E:\Project\CodeProject\ArtemisOS\build\image-refine-20261031\webview-probe-v2\webview-probe.apk `
  -Output E:\Project\CodeProject\ArtemisOS\build\image-refine-20261031\candidate-test-new `
  -Port 5582 -AvdName ArtemisCandidateLab
```

对照基线时将 `-CandidateImage` 换成 `build\image-lab\sysimg\system.img`，添加 `-ExpectedRemovals present`，并使用另一组新输出目录、AVD 名和端口。脚本对每项必需检查逐一断言：结果 JSON 的 `required_failures` 为空、`accepted` 为 `true` 且退出码为 0 才代表全部这些冒烟项目通过；依然不代表全面兼容或正式发行资格。

如需避开项目盘 I/O 压力，`-Output` 也可指定 `%TEMP%\ArtemisOS-image-lab` 下**不存在的直接子目录**；其 `sysdir` 和 AVD 均位于该子目录。可同时指定一个不存在的项目 `build/` 子目录作为 `-ResultArchive`，自动回存结果 JSON、启动日志及相关崩溃日志，不复制测试 AVD 的用户数据。脚本拒绝临时根目录为重解析点。系统服务启动计数、包管理器和设置 Activity 连续就绪次数会分别记录；若观察到 system_server 重启，保留 crash 日志，不能将重启隐藏为正常首次启动。
