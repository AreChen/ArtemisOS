# ArtemisOS 15 1.0.7：显示恢复与天翼云直连更新

> 安装器已由 [1.0.7-r2 保留实例覆盖升级修订](release-1.0.7-r2-native-upgrade.md) 取代。下文保留首次 1.0.7 发行事实；现行安装请使用 r2，无需卸载。

2026-11-12 14:53（UTC+8）发布完成。完整包及校验文件均经天翼云匿名直连完整读回，大小与 SHA256 一致；最后发布并验签 1.0.6→1.0.7 更新及 1.0.7 无更新清单。真实新客户端逐版本检查 1.0.2→1.0.7 通过；未改动旧更新器，也未改变 OpenList 全局或分享设置。

## 下载与适用范围

- [完整安装包](https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/installers/ArtemisOS15-Offline-Installer-1.0.7.exe)，1,233,962,420 字节。
- [安装包 SHA256](https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/installers/ArtemisOS15-Offline-Installer-1.0.7.exe.sha256)：`89b6dd845b077dfd206738068bea8abd9108f619799f2accdedd7079493caf28`。
- [对应显示运行时源码](https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/sources/ArtemisOS15-Display-Sources-1.0.6.zip)，与 1.0.6 相同的 scrcpy/FFmpeg 等对应源码，无需随安装包强制下载；新直连地址已完整读回验哈希。
- 1.0.6→1.0.7 变化文件 OTA：6 文件，471,010 字节；不含系统镜像、SDK 或用户数据。

正式完整安装器沿用新装流程：同 AppId 已安装或目标非空会拒绝，**不是覆盖升级安装器**。不包含 `Find-ArtemisInstallations.ps1` 或覆盖安装事务原型。不要为更新连接直接卸载/清空数据；现有安装的保数据换装不是本次发行已实现的能力。

按用户决定，不为旧下载器提供代理、桥接或修复工具。旧客户端的分享入口和下载器可能无法自动升级，不能承诺所有 1.0.2/1.0.4/1.0.6 客户端直接更新。新更新器通过直连入口逐版本更新；可读取历史下一跳协议，已升级的版本再读取自己的无更新标记。

## 本次修改

修复 Sunshine、虚拟显示器、DPI/分辨率变化后的冻结和局部画面；仅重连显示端，保留 Android 实例与渲染偏好。实际 Sunshine 切换先前已由用户确认恢复正常；本次重新运行显示恢复回归通过。

更新器和 OpenList 发布器共享匿名安全 HTTPS 下载器：最多 5 跳指定 HTTP 跳转，拒绝 HTTP 降级、循环、跨主机认证/Cookie、异常状态和 HTML。清单签名、对象大小和 SHA256、旧文件 SHA256 检查保留。固定清单 JSON/签名的两文件发布不具备原子性；不一致时停止，不能跳过验签。[协议与边界](../openlist-direct-ota.md)。

永久 OTA 基础地址：`https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/`。未修改 OpenList 代理或分享配置。Android 15 镜像、Emulator 37.3.9 Beta / build 16863232、硬件优先配置保持。

## 验证及基线

- 新 HTTPS 下载与发布流程的 12 脚本回归此前通过；本轮重新运行 HTTPS 安全、发布失败处理及显示恢复测试，通过。
- 最终签名补丁在 `1.0.6`、`1.0.6-ota`、`1.0.6-ota-from-full` 三条冻结来源使用实际 apply 安装；6 个对象、旧哈希、备份、无更新标记核对通过，数据及配置标记保持，修改过的前端被拒绝。
- 同一正式 EXE 在独立临时标准账户中完成新装，核对注册版本、前端/更新器/服务器地址、8 个现代渲染提供程序文件，并通过真实匿名直连获得签名无更新结果；未启动 Android。账户、系统配置文件和安装测试目录已清理。
- 发布对象先完整回读大小和 SHA256，再写目标及源签名清单；最后两对文件均验签并与本地逐字节一致。安装包完整读回 1,233,962,420 字节，最终主机为 `media-qhxn-fj-person.qh6oss.ctyunxs.cn`。历史大运行时对象仅追加 1 KiB Range 探测，不重复全量下载；不把这个样本当作大对象完整哈希验证。
- 首次清理检查保守停止，原因是 WinINet 下载检查在临时测试 home 内创建 `Content.IE5` 目录联接；核对仅有这一个联接且目标也在测试根内，删除联接条目后再次执行无联接遍历并清理。原失败报告保留，成功结果附单独恢复证据，没有重跑或跳过产品断言。
- 安装包未做 Authenticode 签名。用户提供的火绒日志是测试原型从临时目录带 `ExecutionPolicy Bypass` 执行发现脚本，记录为“已允许”，不是正式包病毒检测证据。[调查](huorong-installer-fixture-20261112.md)。不关闭防护、不加排除，不能保证其他行为告警不会出现。

最终发行工作目录 `build/release-1.0.7-direct`，完整基线 `releases/1.0.7-direct`，OTA 来源分别 `releases/1.0.7-direct-ota`、`releases/1.0.7-direct-ota-from-full`；小文件独立，SDK 只读硬链接复用。**旧 `build/release-1.0.7` 与 `releases/1.0.7*` 中无 direct 后缀的候选仍是废弃历史证据，不可用于后续补丁基线。**

签名更新清单 SHA256：`8366dfe687134137afea0f18277e165a9b900bc996f1414b454f42a14ba2cf46`。

[发行证据](evidence/release-1.0.7-direct)。
