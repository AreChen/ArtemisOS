# ArtemisOS 15

ArtemisOS 15 是基于 Android Emulator 的 Windows 内部测试环境。本仓库保存安装器、启动配置、安卓更新入口和更新服务源码。Android SDK、系统镜像、生成的安装包、模拟器用户数据及签名私钥不提交到 Git。

## 现有功能

- Android 15 x86_64 Google APIs 镜像，不包含 Google Play 商店。
- 低、中、高三档配置，简体中文，默认 UTC+8。
- 自动或软件渲染启动，可选停用部分 Google 预装应用。
- 桌面快捷方式、窗口版本号和首次启动初始化。
- 实验性的更新入口：在模拟器内检查更新，确认后由 Windows 下载并安装已签名的变化文件，然后重启模拟器。

## 本机更新试验

当前实现用于本机验证：测试服务只监听 `127.0.0.1`，不会随 Windows 自动启动，其他电脑无法访问。启动前需安装 Node.js；模拟器使用者不需要 Node.js。

在项目目录运行 Windows PowerShell：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Start-LocalServer.ps1 -InstallRoot 'E:\AndroidOfflineEmu'
```

服务默认使用 `http://127.0.0.1:18765/`。`-InstallRoot` 指定本机 ArtemisOS 安装目录并写入本机服务器地址；若已有不同的地址，确认后可加 `-Force`。若端口已被占用，可使用 `-Port 其他端口`。运行 `tools\Stop-LocalServer.ps1` 停止该服务。重新开机后需再次运行启动脚本。

在模拟器里打开“ArtemisOS 更新”并检查更新。发布了适用当前版本的包时，界面会显示新版本及说明；确认安装后模拟器会自动重启。没有配置服务器或服务未运行时，界面会提示连接失败。

## 发布更新

发布前保留上一发行版的完整、未修改的安装文件快照，并准备新的目标版本目录。两者的 `version.ini` 分别写旧版与新版版本号；已安装文件必须与旧版快照的内容一致。项目自带的本机发布工具会对变化文件计算 SHA-256，生成签名清单，并将文件写入 `server\repository\`：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Publish-Update.ps1 -BaseRoot 'E:\releases\0.3.1' -TargetRoot 'E:\releases\0.3.2' -Notes '修复和体验改进'
```

清单按旧版本存放，例如 `manifests/0.3.1.json` 和对应的 `.sig`；文件放在 `objects/`。默认只检查启动器与更新组件；需要同时发布 SDK 或系统镜像时加 `-IncludeSdk`。当前按变化的**整个文件**传输，系统镜像变化仍可能需要下载数 GB，尚不支持二进制差分或原生 Android 分区 OTA。清单不支持删除旧文件；受保护的恢复程序和信任公钥也不能通过此通道更换。

客户端验证签名、目标路径、旧文件哈希、新文件大小和哈希。安装过程中会备份受影响文件并记录恢复信息；中断后下次启动时先尝试恢复。更新范围不包含安装目录的 `data/` 用户数据目录。本项目的本机服务只是静态测试服务；为其他电脑提供更新还需要部署 HTTPS 服务、配置每台客户端的服务器地址及设计正式发布流程。

## 本地构建

准备 Inno Setup 6、JDK、Android SDK Platform 35 和 Build Tools 35.0.0，并将完整的 Android Emulator、platform-tools 和 `android-35/google_apis/x86_64` 镜像放在 `stage\sdk\`。仓库不包含这些大型文件，可从已有安装或另行准备的 SDK 复制。请检查所使用 Google 组件的适用许可。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Initialize-Keys.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-UpdaterApp.ps1
# 使用 Inno Setup 编译 installer.iss；老版 0.2.3 安装可使用 bootstrap.iss 构建更新组件安装包
```

`Build-UpdaterApp.ps1` 默认读取当前用户 Android SDK 目录，也可通过 `-AndroidSdk` 指定。`stage\version.ini` 是安装包和窗口标题共用的版本号。完整安装包为新安装提供更新入口；若未配置可用服务器，更新检查会提示尚未配置。

发布签名私钥和 Android 应用签名材料默认保存在当前用户的 `%LOCALAPPDATA%\ArtemisOS-Dev\signing\`，敏感内容使用当前 Windows 用户的 DPAPI 保护。它们不能提交到仓库；单纯复制 DPAPI 文件到其他电脑并不能保证解密。更换开发机前须通过安全方式迁移或备份密钥，否则无法为已安装客户端继续签发可信更新。`stage\update\trusted-key.xml` 是可公开的验证公钥。

`tests\updater-security.ps1` 为签名、版本、路径和中断恢复提供本机回归检查。`tests\bridge-disconnect.ps1` 使用隔离的临时安装和测试服务器检查下载时断开连接的行为，需要 Node.js 和本机签名密钥。实际运行中的模拟器数据存放在安装目录的 `data\`，不要复制进源码仓库。
