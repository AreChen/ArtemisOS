# OpenList / 天翼云直连 OTA

2026-11-12，含本改造的 1.0.7 完整安装包和签名 OTA 已发布，见 [正式发行记录](history/release-1.0.7-direct-ota.md)。旧的无 direct 后缀 1.0.7 冻结候选仍含旧下载器，仅保留历史取证；后续使用 `releases/1.0.7-direct*` 作为本次发行基线。

## 地址与下载

永久基础地址：`https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/`。

保留 `manifests/<当前版本>.json`、对应 `.sig`、`objects/<SHA256>`。OpenList 返回 302，Windows 直接从天翼云获取文件；不使用 `/sd/YCsIY2UB/` 分享，不保存临时签名 URL，不修改全局代理或其他分享。

更新器与发布器共用 `stage/update/core.ps1` 的匿名下载实现：

- 最多 5 次 301/302/303/307/308，支持相对 Location 和临时 URL 的查询参数。
- 起点、每跳均 HTTPS，包括本机入口也拒绝 HTTP；拒绝循环、缺少 Location、超限、URL 用户凭据、片段及其他协议。
- 每跳新建匿名 GET，不使用默认 Windows 身份、发布登录、Authorization、Cookie。最终普通下载须 HTTP 200，仅显式 Range 探测允许 206。
- 拒绝 HTML MIME、伪装成 octet-stream 的 HTML 以及跨网络读取块的 HTML 前缀。空元数据、错误状态和超限元数据均失败。
- 保持清单 RSA/SHA256 签名、对象长度与 SHA256、旧产品文件 SHA256、路径及版本检查。只有有效签名的同版本空清单表示「无更新」。

继续按当前版本取得下一跳，正常完成并重启后再检查下一跳。Android 数据、已装应用、AVD 与偏好不是更新目标。手动修改产品文件触发旧哈希不一致时必须停止，不能关闭校验。

这是变化文件的 Windows 产品 OTA，不是 Android 分区 `update_engine` 或二进制差分；若更新 `system.img`，仍需下载整个变化文件。

## 发布

新参数 `-PublicBase` 默认上述直连地址；已移除 `ShareId` 和分享 API。发布器确认 PublicBase 的 `/d/` 路径等于受限账户 `base_path + RemoteRoot`，避免上传和匿名回读落在不同仓库。

```powershell
rtk proxy powershell.exe -NoProfile -File tools/Publish-Update.ps1 `
  -BaseRoot <旧版目录> -TargetRoot <新版目录> -Repository <本地签名仓库>

$credential = Get-Credential
./tools/Publish-OpenList.ps1 -Repository <本地签名仓库> `
  -FromVersion <旧版本> -TargetVersion <新版本> -RemoteRoot /ota `
  -PublicBase https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/ `
  -Credential $credential
$credential = $null
```

使用非管理员、非根目录、仅有目标目录发布权限的账户。认证 API/上传用独立 HttpClient，禁用跳转、Cookie 和默认身份；不会将上传请求或登录凭据转向网盘。密码、令牌、私钥不得进入永久配置、安装包、仓库或日志。

顺序：验证本地清单/对象 → 上传并匿名完整回读所有对象，核对长度/SHA256 → 上传目标版本无更新标记并完整验签 → 最后更新源版本 JSON/签名 → 完整回读源、目标两对文件，验签且与本地逐字节一致 → 输出 `Published`。

仅发布独立版本的无更新标记时，先用 `tools/New-UpdateSentinel.ps1` 生成，再用 `-SentinelOnly -TargetVersion <版本>` 发布，不传 `FromVersion`。相同文件可幂等重试；不同目标清单、已存在的不同前向更新或损坏的完整源配对会停止，不自动覆盖修复。失败可能留下已上传文件，不能当作整体成功或自动回滚。

正式发布时的对象回读仍完整流式校验哈希；只读排障对大文件使用响应头/Range，不能把 Range 样本当作完整哈希验证。

## JSON / 签名配对不能原子发布

固定路径 JSON 和 `.sig` 是两个独立文件，OpenList 不提供配对原子替换或 CAS。发布窗口或上游缓存不一致时，客户端可能读到不同发布代次的配对。

当前客户端每次完整取两份文件并验签，不一致立即停止，不安装、不报无更新；不自动重试，稍后重新检查会重新取完整配对。请求禁用本机 HTTP 缓存，但不能保证上游缓存同步。完整且有效但过期的签名清单也可能暂时显示无更新。

能保证：无有效签名与哈希就不应用更新，发布器最后发现不一致不会报成功。不能保证：发布瞬间连续可用、立刻看到最新版本、并发发布自动解决冲突。必须单一发布者。若未来需要更强的一致性，应设计不可变发布目录和签名版本指针，不能跳过验签。

## 安装与旧版影响

`stage/update/server.txt` 是新默认，两安装模板拒绝旧 `OpenListServerFile` 构建宏。仍优先读取 `data/update/server.txt`，显式自定义地址保留，但必须是 HTTPS。

不为旧更新器开发代理、引导迁移或修复工具。旧客户端无法自动更新时，关闭模拟器后直接运行 [1.0.8 完整安装包](https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/installers/ArtemisOS15-Offline-Installer-1.0.8.exe)，自动使用原目录和 AppId 覆盖升级，保留实例、应用与偏好。无需先卸载。

**正式 `installer.iss` 的 r2 修订已支持保留数据覆盖安装**，采用原生 Inno 发现、哈希比较、备份恢复与原卸载日志追加，不调用覆盖事务原型。只迁移已知旧官方 OTA 地址，保留自定义地址；未注册且已有内容的目录、多个真实安装及降级仍被拒绝。验收范围和恢复边界见 [r2 发布记录](history/release-1.0.7-r2-native-upgrade.md)。原始不带 r2 的 1.0.7 包仅作历史记录，不作为现行下载入口。

## 验证与证据

在 Windows PowerShell 5.1 运行：

```powershell
rtk proxy powershell.exe -NoProfile -File tests/ota-https-download.ps1
rtk proxy powershell.exe -NoProfile -File tests/openlist-direct-publish.ps1
rtk proxy powershell.exe -NoProfile -File tests/openlist-sentinel-only.ps1
rtk proxy powershell.exe -NoProfile -File tests/update-static-repository.ps1
rtk proxy powershell.exe -NoProfile -File tests/ota-openlist-direct-live.ps1
```

TLS 夹具只在测试进程信任新生成证书，不改系统信任。客户端测试包含各类跳转错误、认证隔离、HTML 分片、签名/大小/哈希失败及小文件两跳真实应用，检查数据标记保持。发布测试包含实际 TLS API 上传、匿名 CDN 回读、顺序、完整配对、损坏与冲突、失败不报告成功。

真实匿名只读验证：1.0.2→1.0.3→1.0.4→1.0.5→1.0.6 清单验签通过，1.0.6 是签名无更新标记；28 字节对象完整核对长度及哈希；121,830,552 字节大对象最终来自天翼云 `ctyunxs.cn`，206，`Content-Range: bytes 0-1023/121830552`，只读 1 KiB，没有验证整个大对象的哈希。证据：`build/ota-direct-live-result.json`。

安装配置测试 `tests/installer-ota-default.ps1` 使用独立身份/tiny SDK；静默执行。旧 `Start-LocalServer.ps1` 仍提供 loopback HTTP，不能用于新客户端；使用隔离 TLS 夹具或有效 HTTPS 测试服务。旧分享连接组件及迁移脚本只供历史取证，不用于当前发布。
