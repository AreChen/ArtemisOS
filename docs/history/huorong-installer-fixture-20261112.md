# 火绒告警：安装测试的 PowerShell 调用

2026-11-12，用户提供火绒行为防护日志。防护项目为“利用 PowerShell 执行可疑脚本”，操作结果为“已允许”；未提供恶意文件检测名称，也没有证据证明正式安装包被隔离。

父进程是临时测试包 `ota-default.exe`，路径包含 `artemisos-fixture-ota-default-…`；调用 Inno 临时目录中的 `Find-ArtemisInstallations.ps1`，带 `-NoProfile -NonInteractive -ExecutionPolicy Bypass`。目标是测试目录的 `failed` 分支，`TargetVersion 1.0.0` 属于合成测试参数，不是发布版本。

这与 `tests/installer-ota-default.ps1` 的受保护覆盖安装原型负例一致：测试包解压脚本并运行只读安装目录发现，失败事务须保持旧配置。行为触发机制可信，但不能从这一条日志推断火绒对所有产品文件的扫描结果。

正式 1.0.7 使用 `installer.iss`，不包含或调用 `Find-ArtemisInstallations.ps1`、覆盖安装事务原型。后续正式包验收使用独立临时标准账户和隐藏静默模式。没有添加杀毒排除，没有关闭防护，也没有修改全局 PowerShell 策略。

正式安装器首次稀疏镜像优化及产品启动仍使用 PowerShell，因此不能保证其他行为告警永远不会出现。此前 1.0.6 完整安装包和前端本来就没有 Authenticode 签名；该日志不能归因于新版本“签名失效”。1.0.7 不使用其他项目的本地证书冒充受信任发布者。
