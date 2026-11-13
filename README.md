# ArtemisOS 15

**1.1.0 已发布：** 新增 AMD 集显/独显 Vulkan 实验支持，Intel/AMD 可选择具体渲染设备，按 PCI 厂商识别并核对实际渲染器。1.0.9→1.1.0 OTA 约 76 KiB，不换镜像；完整包保留数据覆盖升级。本机 Intel 启动通过，AMD 实机尚待验证。[下载与验收](docs/history/release-1.1.0-amd-vulkan.md)。

**1.0.9 已发布：** 修复自定义窗口的隐私页面黑屏，设置可切换自定义/Emulator 原生窗口；1.0.8→1.0.9 OTA 约 207 KiB，完整安装包约 1.23 GB，可直接保留数据覆盖升级。[下载与验收](docs/history/release-1.0.9-secure-display.md)。

**1.0.8 已发布：** 修复 Intel Graphics 等名称被误拒绝，支持保留数据覆盖升级；1.0.7→1.0.8 OTA 仅 46,474 字节，使用天翼云直连。[下载与验收](docs/history/release-1.0.8-intel-detection.md)。

**1.0.7-r2 安装器已发布：** 自动识别原安装目录并保留实例覆盖升级，无需卸载；沿用 1.0.7 的显示恢复修复和天翼云直连 OTA，系统镜像与应用数据格式不变。完整包约 1.23 GB，1.0.6→1.0.7 OTA 变化文件约 471 KB。旧下载器不作兼容迁移，无法自动更新时直接运行 r2 完整包。[下载与验收记录](docs/history/release-1.0.7-r2-native-upgrade.md)。

ArtemisOS 15 是基于 Android Emulator 的 Windows 内部测试环境。本仓库保存安装器、启动配置、安卓更新入口和更新服务源码。Android SDK、系统镜像、生成的安装包、模拟器用户数据及签名私钥不提交到 Git。

`assets/ArtemisOS15.png` 是透明背景的原始标志；`docs/history/` 保存早期版本验证和移动爱家兼容性排查记录。[技术资料库](docs/research/README.md) 收录自制系统镜像、Windows 交付、自动化、精简和 OTA 的研究资料。

2026-11-11，**1.0.4** 使用 Google 官方 **Android Emulator 37.3.9 Beta（build 16863232）**，完成 Windows 软件图形库装配与启动环境适配，实测接通 **GLES → ANGLE → Vulkan → SwiftShader**。硬件渲染继续作为默认选择；软件快捷方式及软件配置使用现代 Vulkan 实现。本机已保留原 Android 15 实例数据升级，并分别验证软件、硬件启动。构建、证据、适用范围和回退见 [1.0.4 Vulkan 适配记录](docs/history/release-1.0.4-modern-vulkan.md)；原始官方运行时的回退行为见 [37.3.9 Beta 升级记录](docs/history/emulator-37.3.9-beta-20261111.md)。

**1.0.3 → 1.0.4 OTA 已发布到 OpenList**，支持两种历史启动器。实际下载约 599 MB（571 MiB），不含 Android 系统镜像；保留应用数据与渲染偏好。两条真实旧更新器升级、迁移与 Android 软件渲染启动验证通过，线上旧客户端已读回同一签名清单。现有 OTA 按未压缩的完整变化文件传输，此次包含运行时升级；更早版本的更新路径和 1.0.2 更新修复工具说明见上述发布记录。

0.3.6 使用 Android Emulator 37.3.6 Canary 和经过独立测试的精简镜像，是全新安装版本；不提供从旧版的自动升级或自动数据迁移。本机数据已在备份和核验后复制到新版实例，其他安装环境仍需单独验证。该运行时为预览版，内部开发使用不等于已获得整包再分发授权。版本来源、测试及许可待确认事项见 [0.3.6 验证记录](docs/history/release-0.3.6-validation.md)。

## 现有功能

- Android 15 x86_64 Google APIs 镜像，不包含 Google Play 商店。
- 低、中、高三档配置，简体中文，默认 UTC+8；模拟中国移动、电信、联通可在配置中切换。
- 默认使用硬件图形加速，配置可切换现代 Vulkan 软件渲染；软件渲染仍使用 CPU。保留竖屏 9:16 和横屏 16:9 的 720p、1080p 预设，默认 720p。默认启用软件视频解码兼容模式，可在配置中关闭。
- 精简镜像不预装部分 Google 应用；旧镜像已有的可选应用可按需停用或恢复。
- 桌面快捷方式、窗口版本号和首次启动初始化。
- 实验性的更新入口：在模拟器内检查更新，确认后由 Windows 下载并安装已签名的变化文件，然后重启模拟器。

图片或其他文件可以从 Windows 拖到模拟器屏幕，然后在安卓“文件”应用的“下载”目录中查找。

## OpenList 更新通道

更新器使用 `https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/`，安全跟随 HTTPS 跳转直连天翼云，不使用旧分享或服务器代理。1.0.7-r2 及以后的完整安装包已包含直连更新器；旧下载器无法访问时，直接运行新完整包覆盖原目录并保留数据。发布、配对一致性和安装保护见 [直连 OTA](docs/openlist-direct-ota.md)。

## 本机更新试验

以下为历史 HTTP 开发流程，不能用于要求全程 HTTPS 的新更新器。当前测试使用 [隔离 TLS 夹具](docs/openlist-direct-ota.md#验证与证据)。

下面的本机测试服务只监听 `127.0.0.1`，不会随 Windows 自动启动，其他电脑无法访问。启动前需安装 Node.js；模拟器使用者不需要 Node.js。

在项目目录运行 Windows PowerShell：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Start-LocalServer.ps1 -InstallRoot 'E:\AndroidOfflineEmu'
```

服务默认使用 `http://127.0.0.1:18765/`。`-InstallRoot` 指定本机 ArtemisOS 安装目录并写入本机服务器地址；若已有不同的地址，确认后可加 `-Force`。若端口已被占用，可使用 `-Port 其他端口`。运行 `tools\Stop-LocalServer.ps1` 停止该服务。重新开机后需再次运行启动脚本。

在模拟器里打开“ArtemisOS 更新”并检查更新。发布了适用当前版本的包时，界面会显示新版本及说明；确认安装后模拟器会自动重启。没有配置服务器、服务未运行或当前版本的清单缺失时，界面会提示检查失败；只有有效签名的同版本空清单才表示没有更新。

## 发布更新

发布前保留上一发行版的完整、未修改的安装文件快照，并准备新的目标版本目录。两者的 `version.ini` 分别写旧版与新版版本号；已安装文件必须与旧版快照的内容一致。项目自带的本机发布工具会对变化文件计算 SHA-256，生成签名清单，并将文件写入 `server\repository\`：

本机的 `releases/` 不提交到 Git，用于保存发行基线。`0.3.2` 和 `0.3.3` 快照包含完整 SDK，`0.3.4` 和 `0.3.6` 为对应精简包的安装基线；`0.3.0` 和 `0.3.1` 快照不含 SDK，只适用于默认的启动器和更新组件发布。快照应视为只读文件，删除或改动会影响后续版本的补丁制作。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-Update.ps1 -BaseRoot '.\releases\0.3.3' -TargetRoot '.\build\target-0.3.4' -Notes '修复和体验改进'
```

清单按旧版本存放，例如 `manifests/0.3.3.json` 和对应的 `.sig`；文件放在 `objects/`。默认检查启动器、更新组件和可选的运营商映射文件；需要递归检查整个 SDK 或发布系统镜像时加 `-IncludeSdk`。当前按变化的**整个文件**传输，系统镜像变化仍可能需要下载数 GB，尚不支持二进制差分或原生 Android 分区 OTA。清单不支持删除旧文件；受保护的恢复程序和信任公钥也不能通过此通道更换。

覆盖安装 0.3.4 会保留旧系统镜像，新装 0.3.4 使用精简镜像。因此相同版本可能存在不同的 SDK 文件；发布前须核对清单所含每个文件的实际基线，尤其是系统镜像和运营商映射。当前服务不能按同一旧版本的镜像差异自动分发不同清单。

客户端验证签名、目标路径、旧文件哈希、新文件大小和哈希。安装过程中会备份受影响文件并记录恢复信息；中断后下次启动时先尝试恢复。更新范围不包含安装目录的 `data/` 用户数据目录。OpenList 试运行的发布和接入流程另见 [OpenList 更新通道](docs/openlist-ota.md)。

## 本地构建

准备 Inno Setup 6、JDK、Android SDK Platform 35 和 Build Tools 35.0.0，并将完整的 Android Emulator、platform-tools 和 `android-35/google_apis/x86_64` 镜像放在 `stage\sdk\`。仓库不包含这些大型文件，可从已有安装或另行准备的 SDK 复制。请检查所使用 Google 组件的适用许可。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Initialize-Keys.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-UpdaterApp.ps1
# 使用 Inno Setup 编译 installer.iss；老版 0.2.3 安装可使用 bootstrap.iss 构建更新组件安装包
```

`Build-UpdaterApp.ps1` 默认读取当前用户 Android SDK 目录，也可通过 `-AndroidSdk` 指定。`stage\version.ini` 是安装包和窗口标题共用的版本号。完整安装包为新安装提供更新入口；若未配置可用服务器，更新检查会提示尚未配置。

构建精简包时，先准备并独立验证与原镜像布局相同的精简镜像（参见 `docs/history/系统参数对比与镜像实验-20261031.md`），再生成只包含 x86_64 虚拟机后端的 SDK 构建输入：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Prepare-SlimSdk.ps1 -SystemImage '.\build\image-lab\sysimg\system.img' -Output (Join-Path (Get-Location) 'build\slim-sdk')
$image = '.\build\slim-sdk\system-images\android-35\google_apis\x86_64\system.img'
$sha256 = (Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash.ToLowerInvariant()
& 'C:\Path\To\Inno Setup 6\ISCC.exe' '/DSdkSource=build\slim-sdk' "/DSparseImageSha256=$sha256" installer.iss
```

构建输入通过硬链接复用原 SDK 和精简镜像，打包期间不能原地修改输入文件。此工具不会生成或验证精简镜像；更换镜像后须重新验证启动、应用兼容性和安装升级。安装器默认使用 `lzma2/max` 减少分发体积，开发时可以通过 `/DPackageCompression=lzma2/fast` 换取更短的构建时间。

需要独立指定模拟器运行时时，可给 `Prepare-SlimSdk.ps1` 增加 `-EmulatorDirectory <解压后的 emulator 目录>`，然后验证其版本、来源和哈希。正式版构建还使用固定的 `/DReleaseAppId=ArtemisOS15-Release`、`/DReleaseShortcutName=ArtemisOS 15 x64` 和 `/DReleaseDefaultDirName=ArtemisOS15-Release`；快捷方式名称不包含补丁版本，窗口标题读取 `version.ini`。通过 `VersionSource` 指定独立的版本文件时，`AppVersion` 必须与该文件一致。

后续精简与性能对比均在独立目录进行：[镜像可选组件实验](tools/image-lab/app-test-profile.md)、[运行时重复资源实验](tools/runtime-lab/README.md)和[隔离实例体积与性能测量](tools/benchmark-lab/README.md)。`RuntimeReuseInclude` 是显式的实验性编译选项；使用前必须按实验说明对所选 SDK 生成并校验清单，并在整个构建过程中保持输入不变，不能将未经完整安装与兼容性验证的结果视为正式发布。

指定 `SparseImageSha256` 后，仅全新安装会尝试把经过校验的系统镜像转为 NTFS 稀疏文件，回收连续全零区域的实际磁盘占用，并在处理前后检查 SHA-256；文件逻辑长度与内容不变。安装时仍需先有足够空间解压完整镜像，完成优化后才回收空间。不支持 NTFS 稀疏文件或无法独占文件时会跳过优化；如果完整性无法确认，安装会终止，保留未完成标记，并阻止继续使用该目录安装。覆盖已有目录不会执行这一步。Windows 普通复制工具可能将稀疏文件重新展开。实现依据是微软的[稀疏文件操作说明](https://learn.microsoft.com/en-us/windows/win32/fileio/sparse-file-operations)；独立标准用户账户上的完整安装流程仍需复测。

发布签名私钥和 Android 应用签名材料默认保存在当前用户的 `%LOCALAPPDATA%\ArtemisOS-Dev\signing\`，敏感内容使用当前 Windows 用户的 DPAPI 保护。它们不能提交到仓库；单纯复制 DPAPI 文件到其他电脑并不能保证解密。更换开发机前须通过安全方式迁移或备份密钥，否则无法为已安装客户端继续签发可信更新。`stage\update\trusted-key.xml` 是可公开的验证公钥。

`tests\updater-security.ps1` 为签名、版本、路径和中断恢复提供本机回归检查。`tests\bridge-disconnect.ps1` 使用隔离的临时安装和测试服务器检查下载时断开连接的行为，需要 Node.js 和本机签名密钥。实际运行中的模拟器数据存放在安装目录的 `data\`，不要复制进源码仓库。
