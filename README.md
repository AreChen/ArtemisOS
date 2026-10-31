# ArtemisOS 15

ArtemisOS 15 是基于 Android Emulator 的 Windows 内部测试环境。本仓库保存安装器、启动配置与更新工具源码；Android SDK、系统镜像、安装包、用户数据和签名私钥不提交到 Git。

## 现有功能

- Android 15 x86_64 Google APIs 镜像，不包含 Google Play 商店。
- 低、中、高三档配置，简体中文，默认 UTC+8。
- 自动或软件渲染启动，可选停用部分 Google 预装应用。
- 桌面快捷方式、窗口版本号和首次启动初始化。

## 本地构建

在 Windows 上准备 Inno Setup 6，并将完整的 Android Emulator、platform-tools 和 `android-35/google_apis/x86_64` 镜像放在 `stage/sdk/`。仓库不包含这些大型文件；可从已有安装或另行准备的 SDK 复制。打开 `installer.iss`，使用 Inno Setup 编译即可生成离线安装包。请检查所使用 Google 组件的适用许可。

`stage/version.ini` 是安装包和窗口标题共用的版本号。实际运行中的模拟器数据存放在安装目录下的 `data/`，不要复制进源码仓库。
