# OTA：天翼云 HTTPS 直连实现与验证

2026-11-12。完成代码和模板改造，12 个回归脚本全部退出 0；独立审查未发现阻断项。未构建新完整安装包、未生产发布，未修改 OpenList 全局代理或任何分享。用户本机模拟器与数据未更新或重启。

操作说明与一致性边界：[直连 OTA](../openlist-direct-ota.md)。

## 实现文件

| 文件 | 修改 |
|---|---|
| `stage/update/core.ps1` | 共用匿名 HTTPS 下载；最多 5 次指定跳转；循环、降级、凭据 URI、异常状态、HTML/分片拒绝；保留全部签名/大小/哈希/路径检查；保留 404 失败语义，避免异常输出临时签名 URL |
| `stage/update/server.txt` | 新默认 `https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/` |
| `tools/Publish-OpenList.ps1` | 新 PublicBase 参数，删除 ShareId；认证 API 与匿名读分离；检查目录映射；对象→目标标记→源清单，最后完整配对验签并对本地才报成功 |
| `installer.iss`、`installer-upgrade.iss` | 新配置打包；拒绝旧 OpenListServerFile 宏；接入安装后连接配置处理 |
| `tools/InstallerOtaConfig.iss` | 仅成功安装/覆盖事务后替换精确匹配的旧官方地址，自定义地址、偏好和 AVD 保持 |
| 三个历史 OpenList 迁移/修复发布工具 | 头部标注弃用，保留历史实现用于取证，不用于新入口 |

核心 SHA256：`9f1e3b7c26419a2af91459eac2e642e7ee8ee6abdfc63aeee0f87dddd748fe80`。

发布脚本 SHA256：`fddc7046c18b7651542462e628c5d9a90e390a087d21c09fcfee343ebb5a9c25`。

## 测试

测试均使用 Windows PowerShell 5.1。局部 TLS 服务只在当前测试进程钉住临时证书，不改机器信任。发布流程使用可控 TLS API/CDN 服务器测试；生产部署仅匿名只读，不用发布账户进行写操作。

| 回归脚本 | 退出码 |
|---|---|
| ota-https-download | 0 |
| openlist-direct-publish | 0 |
| openlist-sentinel-only | 0 |
| update-static-repository | 0 |
| ota-openlist-direct-live | 0 |
| future-update-integration | 0 |
| updater-headless-apply | 0 |
| updater-path-process-security | 0 |
| publish-no-update-sentinel | 0 |
| installer-ota-default | 0 |
| installer-identity-isolation | 0 |
| installer-existing-protection | 0 |

验证范围：五类跳转、相对地址/查询参数、恰好五跳与第六跳拒绝、循环、HTTP 降级和初始 HTTP 拒绝、跨主机 Cookie/认证隔离、异常状态、HTML MIME/正文/分片、元数据上限、错误签名、错误大小、同大小错误哈希、旧文件哈希；小文件通过 HTTPS 下载后实际两跳 apply，用户数据/应用/偏好标记保持；发布顺序、幂等、损坏和冲突、上传重定向、末尾配对失败不报成功。

真实生产只读验证：所有 1.0.2→1.0.3→1.0.4→1.0.5→1.0.6 清单签名有效，1.0.6 为无更新标记。28 字节对象完整校验；121,830,552 字节运行时对象只读 Range 0–1023，最终 HTTP 206，天翼云 `ctyunxs.cn`，没有做该大对象全量 SHA256。此处验证的是新客户端读取历史协议的下一跳，不表示未修改旧更新器已获得直连能力。

安装配置验证使用 tiny SDK 与独立身份，包含真实模板编译和静默调用；覆盖事务失败时两处旧连接文件不变。历史保护测试的 SwiftShader 默认断言已改为当前硬件优先 host，未改变产品默认。之前身份隔离测试主动弹出重复安装对话框，已删除可见 UI 用例，改为隐藏静默运行和日志断言；未影响真实安装。

RED 证据：旧代码将 301 HTML 当作文件；旧初始 loopback HTTP 未被策略拒绝；HTML 前缀跨读取块时漏检；旧发布代码缺少 PublicBase、接受损坏源签名以及 HTML 对象。对应修复后回归全部通过。

## 交付限制

- 固定路径 JSON 与签名无法原子发布；当前客户端验签失败停止，稍后重新检查完整配对，不跳过验签。必须单发布者，不能保证发布窗口无短暂失败或上游缓存立刻一致。
- 不提供旧更新器代理、引导或修复工具。旧客户端需安装后续含此代码的新完整版本。
- 当前正式安装器仍拦截同身份/原目录重复安装；覆盖事务仍是原型，不能据此宣称已发布保数据覆盖重装。不要直接卸载/清数据来处理更新连接。
- 冻结的旧 1.0.6/1.0.7 基线未改。原 1.0.7 候选不含本次下载代码，实际发行前必须重新准备基线和包。

证据：[下载测试](evidence/ota-direct-https-20261112/direct-ota-checks-Transport.json)、[升级测试](evidence/ota-direct-https-20261112/direct-ota-checks-Apply.json)、[安装测试](evidence/ota-direct-https-20261112/direct-ota-checks-Installer.json)、[真实匿名入口](evidence/ota-direct-https-20261112/ota-direct-live-result.json)。
