# Android 15 APP 测试镜像：第二阶段精简实验

此实验是 `0.3.5-pilot` 的独立候选，不会修改现有安装，也不构成新的发布版。源 `system.img` 与 SDK 构建输入有硬链接，**不能原位修改**。脚本严格校验固定的源镜像与 product 哈希、两者的字节对应关系，并只在 `build/image-slim-exp/` 内一个此前不存在的目录创建输出。

本次候选已在独立 AVD 通过两次启动、两种 64 位 JNI、WebView、基础 Google 服务绑定、联网和语言时区探针。单机结果、资源采样与完整安装包比较见[实验记录](../../docs/history/image-runtime-slim-experiments-20261031.md)；这不代表全部应用或低配置电脑已经验证。

## 按文件系统核查的体积

`inspect-pilot-layout.py` 通过 GPT CRC 和 Android 动态分区元数据 SHA-256 检验后，读取各 ext4 超级块；数值是文件系统块分配，不等于压缩安装包或 NTFS 实占。当前候选对应：

| 内容 | 逻辑分区大小（字节） | ext4 已使用（字节） | ext4 空闲（字节） |
|---|---:|---:|---:|
| system | 998,658,048 | 915,640,320 | 67,178,496 |
| system_ext | 221,691,904 | 217,456,640 | 655,360 |
| product | 2,144,882,688 | 1,001,123,840 | 1,109,831,680 |
| super 内 vendor | 114,139,136 | 111,890,432 | 360,448 |

另有 `system_dlkm` 分区和 GPT、metadata 等；这里不将非 ext4 内容误报为空白。单独的 `vendor.img` 是 116,391,936 字节 GPT 磁盘镜像，vendor 的 ext4 分配数与 super 内 vendor 相同；尚未完成逐字节比较，也未证明能删除其中任何一份。安装包固实压缩可能消除重复内容，不能把文件长度直接视为下载收益。GPT 与动态分区表格式参照 [AOSP liblp metadata_format.h](https://android.googlesource.com/platform/system/core/+/refs/heads/main/fs_mgr/liblp/include/liblp/metadata_format.h)。

```powershell
rtk proxy python.exe .\tools\image-lab\inspect-pilot-layout.py `
  --system .\build\image-refine-20261031\candidate-a\system.img `
  --vendor .\build\slim-sdk-0.3.5-pilot\system-images\android-35\google_apis\x86_64\vendor.img
```

## 实验删减与风险

| 文件组 | 原始逻辑文件大小 | 已确认的用途或影响 |
|---|---:|---|
| `SafetyHubPrebuilt`，`com.google.android.apps.safetyhub` | 23,695,902 B | APK 标签为“个人安全”；涉及紧急联络与个人安全相关功能，删除后此类功能不可用，相关设置入口需单独检查。 |
| `GoogleRestorePrebuilt-v526684`，`com.google.android.apps.restore` | 15,358,683 B | APK 标签为“数据恢复工具”；涉及从其他设备迁移/恢复数据的流程，不能承诺这些流程继续工作。 |

其余大组件如 Google Play 服务、短信、电话、输入法、文字转语音、WebView、浏览器、日历、联系人、TalkBack 和 ARM64 转译均未刻意移除。保留不等于其所有功能已验证。两组目标文件的逻辑长度合计 **39,054,585 B**；ext4 经校正后空闲块从 270,955 增至 280,437，块长 4096 字节，增加 **38,838,272 B**。这不等于安装包大小变化，也不代表运行速度或内存一定改善。

## 在开发 WSL 中重现

候选会修改独立复制的 product 文件系统，`shared_blocks` 必须使用清除 inode 后修复位图的方法，不得使用未经验证的 `debugfs rm`。脚本对 11 个重要 APK 在删除前后计算 SHA-256，确认内容不变，再执行 `e2fsck -fn`；这只是静态证据，还需在独立 AVD 做首次启动、设置、语言时区、DNS、WebView、两种 ABI、Google 服务、软件渲染和典型应用测试。

```bash
rtk proxy python3 tools/image-lab/build-app-test-profile.py \
  --disk build/image-refine-20261031/candidate-a/system.img \
  --product build/image-refine-20261031/candidate-a/product.img \
  --output build/image-slim-exp/candidate-new \
  --rtk /root/.local/bin/rtk --debugfs /usr/sbin/debugfs --e2fsck /usr/sbin/e2fsck \
  --dumpe2fs /usr/sbin/dumpe2fs \
  --zerofree build/image-lab/zerofree-root/usr/sbin/zerofree
```

不要将软件删除当成手机安全功能仍然存在，不能仅凭 APP 能启动就声称被删除功能兼容；用户的最终 Windows 运行环境不需要安装 WSL。正式交付前还需验证 Google 镜像及其组件的再分发条件。
