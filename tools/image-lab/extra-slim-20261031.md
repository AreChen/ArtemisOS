# 0.3.4 附加精简实验

此为本机独立候选，不是正式发行镜像。输入为 0.3.4 实验镜像及其已导出的 product；产品分区 SHA-256 为 `866b6f259100e8d56f911832be2f7756cd716a86281bf4f9e116cc98e37aea96`。脚本先校验该文件与 system 镜像中偏移 `1,232,076,800` 起的内容完全一致，之后只修改新副本。源镜像存在硬链接，不能原地修改。

候选 `build/image-refine-20261031/candidate-a/system.img` 为 3,576,692,736 字节，SHA-256 为 `ab633cc0504a61c6006cd39d2b371dff8e341f0176e70384597692d7d90a2752`。`candidate-a/manifest.json` 和 `removal.debugfs` 保存了精确路径及命令；构建步骤见 [README](README.md)。

| 移除目录 | 文件逻辑长度之和，字节 | 可预见的影响 |
|---|---:|---|
| `priv-app/Velvet` | 286,117,481 | Google 搜索、助手、语音搜索及相关桌面入口 |
| `priv-app/DevicePersonalizationPrebuiltPixel2021-aiai_20240329.00_RC16` | 105,010,367 | 设备智能和个性化功能 |
| `priv-app/DeviceIntelligenceNetworkPrebuilt-astrea_20240329.00_RC02` | 25,633,925 | 与设备智能相关的网络能力 |
| `priv-app/WellbeingPrebuilt` | 22,403,014 | 数字健康 |
| `priv-app/AndroidAutoStubPrebuilt` | 4,171,198 | Android Auto 入口 |
| `app/MarkupGoogle_v2` | 6,786,206 | 图片标注 |
| 合计 | 450,122,191 | 长度不是可直接回收的物理块数 |

保留 Google Play services、WebView、ARM64 转译、短信、电话、日历、联系人、输入法及文字转语音。保留文件并不证明对应功能全面可用；上述删除也可能影响调用这些系统入口的第三方 APP。

product 的 ext4 块大小为 4096 字节；空闲块由 163,836 增至 270,955，增加 438,759,424 字节（418.43 MiB）。修复后 `e2fsck -fn` 成功，已对空闲块归零，原始 image 长度保持不变。同机以相同 XZ `-0 -T4` 测量 product 压缩流：原版 681,722,896 字节，候选 531,292,684 字节，减少 150,430,212 字节（143.46 MiB）。这是分区压缩流的对照，不是整个安装包大小，也不是运行内存或速度改善的证明。

## 验证状态

- 文件系统检查及下述候选 Windows 冒烟测试通过；具体安装包和全面应用兼容性仍需另行验证，不能单凭此实验宣布可发布。
- 首次测试脚本只复制了系统镜像目录的顶层文件，遗漏同源 `data/empty_data_disk`，导致基线与候选的 QEMU 报缺少 userdata；已修正脚本复制完整目录。该失败不代表正式安装包缺少该文件。
- 先前并行基线与候选首启在脚本时限内未完成；其结果分别保存在 `baseline-test-v2` 和 `candidate-test-v2`。
- 隔离基线 `baseline-test-v3` 冷启动到 Android 15 并获取 `zh-CN`、`Asia/Shanghai`，随后包管理服务出现 `Broken pipe`。该同一测试 AVD 另行冷重启后，包列表、ARM64 与 x86_64 JNI、WebView 本地页面和 JavaScript、Google Play services 基础服务绑定及指定站点 DNS/TCP 诊断均成功；这不等于首次启动全项通过。
- 隔离基线 `baseline-test-v4` 首次启动到 `sys.boot_completed=1` 的宿主计时 291,017 ms，实际观察到 `sys.system_server.start_count=2`；设置 Activity 返回 `PermissionPolicyInternal` 空指针，整轮失败。宿主当时 I/O 繁忙，但目前没有证据证明这就是服务重启原因。
- 将独立 sysdir 与 AVD 放在 C 盘后，基线 `baseline-c-1` 所有设定的冒烟项目通过：两次冷启动、包管理器与 Activity 连续就绪、Settings、两种 JNI、WebView 本地 HTML/JS、Google Play services 基础服务绑定、指定站点 DNS/TCP、`zh-CN` 和 `Asia/Shanghai`。两次启动均观察到 system_server 启动计数由 1 增至 2；该现象与 `-change-locale` 的关系尚未定论。原始 JSON 及日志回存在 `build/image-refine-20261031/baseline-c-1-evidence/`。宿主当时负载变化，这些数字不能用于性能对比。
- 同条件 C 盘隔离候选 `candidate-c-1` 所有设定的冒烟项目通过，两次冷启动后均完成服务连续就绪，六项指定系统包均不再列出，保留项、两种 JNI、WebView、GMS 基础服务绑定、DNS/TCP、语言和时区检查均为真。两个启动周期的 system_server 启动计数同样为 1 增至 2；原因尚未确认。结果 JSON 和日志回存在 `build/image-refine-20261031/candidate-c-1-evidence/`。探针不覆盖 Google 登录、所有 GMS API、真实 APP、图形媒体能力及所有主机配置。
- 后续测试应记录 system_server 启动次数，要求包管理器和设置 Activity 连续就绪，并在服务重启时保存 crash 日志。服务发生重启必须向评审说明，不能只记录 `boot_completed=1`。
