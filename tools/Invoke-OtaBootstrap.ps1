param(
    [Parameter(Mandatory=$true)][string]$Target,
    [Parameter(Mandatory=$true)][string]$BaselineInventory,
    [Parameter(Mandatory=$true)][string]$TargetInventory,
    [Parameter(Mandatory=$true)][string]$FromVersion,
    [Parameter(Mandatory=$true)][string]$ToVersion,
    [string]$ResultFile = ''
)
# Experimental template. The caller must authenticate the installer containing
# this script, its pinned versions and both complete product inventories.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'ArtemisInstallDiscovery.psm1') -Force -ErrorAction Stop
function Read-Inventory([string]$File) {
    $rows = [IO.File]::ReadAllText($File, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $map = @{}
    foreach ($row in $rows) {
        if ($row.path -isnot [string] -or $row.path.Length -gt 1000 -or $row.path -match '[\x00-\x1f<>:"\\|?*]' -or
            $row.path.StartsWith('/') -or $row.path.EndsWith('/') -or $row.path.Contains('//') -or
            $row.path -match '(^|/)\.\.?(/|$)' -or $row.sha256 -notmatch '^[0-9a-f]{64}$') { throw '受管文件清单无效。' }
        $key = $row.path.ToLowerInvariant()
        if ($map.ContainsKey($key)) { throw '受管文件清单包含重复路径。' }
        $map[$key] = [string]$row.sha256
    }
    if ($map.Count -lt 1) { throw '受管文件清单为空。' }
    return $map
}
function Get-ManagedFiles([string]$InstallRoot) {
    $found = New-Object 'System.Collections.Generic.List[string]'
    function Walk([string]$Directory, [string]$Prefix) {
        foreach ($child in @(Get-ChildItem -LiteralPath $Directory -Force)) {
            $relative = if ($Prefix) { $Prefix + '/' + $child.Name } else { $child.Name }
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '安装目录中包含链接或重解析点。' }
            if (-not $Prefix -and $child.Name -ieq 'data' -and $child.PSIsContainer) { continue }
            # The 0.3.6 data migration retained the original fresh AVD here.
            # This is user state, never part of the product update or cleanup.
            if (-not $Prefix -and $child.Name -imatch '^\.data-fresh-before-migration-[0-9a-f]{32}$' -and $child.PSIsContainer) { continue }
            if (-not $Prefix -and $child.Name -imatch '^unins\d{3}\.(exe|dat)$' -and -not $child.PSIsContainer) { continue }
            if ($relative -ieq 'update/server.txt' -and -not $child.PSIsContainer) { continue }
            if ($child.PSIsContainer) { Walk $child.FullName $relative } else { $found.Add($relative) }
        }
    }
    Walk $InstallRoot ''
    return @($found.ToArray())
}
function Assert-Tree([string]$InstallRoot, [hashtable]$Expected) {
    $files = @(Get-ManagedFiles $InstallRoot)
    if ($files.Count -ne $Expected.Count) { throw '安装目录文件清单与支持的版本不一致。' }
    foreach ($relative in $files) {
        $key = $relative.ToLowerInvariant()
        if (-not $Expected.ContainsKey($key)) { throw "存在未识别的产品文件：$relative" }
        $path = Join-Path $InstallRoot ($relative.Replace('/', '\'))
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Expected[$key]) {
            throw "产品文件与支持的版本不一致：$relative"
        }
    }
}
function Assert-NotRunning([string]$InstallRoot) {
    $prefix = $InstallRoot.TrimEnd('\') + '\'
    $candidates = @(Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe' OR Name='qemu-system-x86_64-headless.exe' OR Name='emulator.exe'" -ErrorAction Stop)
    foreach ($process in $candidates) {
        if (-not $process.ExecutablePath) { throw '无法核实运行中的模拟器进程，请关闭模拟器后重试。' }
        if ($process.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw '模拟器正在运行，请先关闭后重试。' }
    }
}
function Assert-UpdateStateSafe([string]$InstallRoot) {
    # The updater reads server.txt and writes staging, pending and log files
    # under data\update. Never follow an existing junction in this subtree.
    $data = Join-Path $InstallRoot 'data'
    $update = Join-Path $data 'update'
    $updateExists = $false
    foreach ($directory in @($data, $update)) {
        try { $item = Get-Item -LiteralPath $directory -Force -ErrorAction Stop }
        catch [System.Management.Automation.ItemNotFoundException] { continue }
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw '更新数据路径不是普通目录。'
        }
        if ($directory -ceq $update) { $updateExists = $true }
    }
    function Check-Children([string]$Directory) {
        foreach ($child in @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction Stop)) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '更新数据包含链接或重解析点。' }
            if ($child.PSIsContainer) { Check-Children $child.FullName }
        }
    }
    if ($updateExists) { Check-Children $update }
}
function Get-Registration([string]$InstallRoot) {
    $reg = Get-ArtemisRegistryRegistrations
    $discovery = Get-ArtemisInstallCandidates -Registrations $reg.Records -InitialIssues $reg.Issues
    $choice = Resolve-ArtemisInstallTarget -Discovery $discovery -ExplicitPath $InstallRoot -TargetVersion $ToVersion
    if ($choice.Status -ne 'selected' -or $choice.Candidate.Version -cne $FromVersion) { throw '安装信息发生变化，或当前版本不支持自动升级。' }
    foreach ($record in $choice.Candidate.Registrations) {
        if ($record.Hive -cne 'CurrentUser' -or $record.AppId -cne 'ArtemisOS15-Release') {
            throw '该安装的 Windows 登记方式不受自动升级支持。'
        }
    }
    return $choice.Candidate.Path
}
try {
    if ($FromVersion -notmatch '^\d+\.\d+\.\d+$' -or $ToVersion -notmatch '^\d+\.\d+\.\d+$' -or
        [version]$ToVersion -le [version]$FromVersion) { throw '升级版本参数无效。' }
    $Target = Get-Registration $Target
    $base = Read-Inventory $BaselineInventory
    $expected = Read-Inventory $TargetInventory
    if ($base.Count -ne $expected.Count -or -not $base.ContainsKey('version.ini') -or -not $expected.ContainsKey('version.ini')) {
        throw '版本清单不匹配。'
    }
    $changed = @()
    foreach ($key in $base.Keys) {
        if (-not $expected.ContainsKey($key)) { throw '自动升级不支持删除产品文件。' }
        if ($base[$key] -cne $expected[$key]) {
            if ($key -in @('update/recovery.ps1','update/trusted-key.xml','update/server.txt')) {
                throw '现有 OTA 机制不能更新恢复程序、公钥或服务器配置。'
            }
            $changed += $key
        }
    }
    if ($changed.Count -lt 1 -or $changed.Count -gt 1000 -or 'version.ini' -cnotin $changed) {
        throw '目标版本文件差异无效。'
    }
    Assert-NotRunning $Target
    Assert-Tree $Target $base
    Assert-UpdateStateSafe $Target
    # This code and the embedded public key are trusted only after matching the
    # immutable baseline, not just a mutable installed version number.
    . (Join-Path $Target 'update\core.ps1')
    $mutex = New-Object Threading.Mutex($false, (Get-UpdateMutexName $Target))
    $held = $false
    try {
        try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw '另一个更新正在进行。' }
        if ((Get-Registration $Target) -ine $Target) { throw '安装位置发生变化。' }
        Assert-NotRunning $Target
        Assert-UpdateStateSafe $Target
        $offer = Get-UpdateOffer $Target
        if ($null -eq $offer -or $offer.Manifest.from -cne $FromVersion -or $offer.Manifest.to -cne $ToVersion -or
            @($offer.Manifest.files).Count -ne $changed.Count) {
            throw '服务器没有提供与安装包一致的签名更新。'
        }
        $manifestPaths = @{}
        foreach ($file in @($offer.Manifest.files)) {
            $key = $file.path.ToLowerInvariant()
            if ($key -cnotin $changed -or $manifestPaths.ContainsKey($key) -or
                $file.base_sha256 -cne $base[$key] -or $file.sha256 -cne $expected[$key]) {
                throw '签名更新与发行清单不一致。'
            }
            $manifestPaths[$key] = $true
        }
        Assert-UpdateStateSafe $Target
        $staging = Stage-UpdateOffer $Target $offer
        Assert-NotRunning $Target
        Assert-UpdateStateSafe $Target
        # Same-thread named mutex acquisition in apply.ps1 is reentrant. Its
        # existing journal, recovery and signature checks remain in force.
        & (Join-Path $Target 'update\apply.ps1') -Staging $staging -Serial 'emulator-5554' -NoRestart
        if ((Get-UpdateVersion $Target) -cne $ToVersion) { throw '更新未达到目标版本。' }
        Assert-Tree $Target $expected
        $registryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ArtemisOS15-Release_is1'
        $displayVersion = (Get-ItemProperty -LiteralPath $registryPath -Name DisplayVersion -ErrorAction Stop).DisplayVersion
        if ([string]$displayVersion -cne $ToVersion) { throw '程序已更新，但 Windows 应用列表的版本未同步。' }
        if ($ResultFile) { [IO.File]::WriteAllText($ResultFile, ('ArtemisOS 15 ' + $ToVersion + ' 更新完成。'), [Text.UTF8Encoding]::new($true)) }
        Write-Output ('ArtemisOS 15 ' + $ToVersion + ' 更新完成。')
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
} catch {
    if ($ResultFile) {
        try { [IO.File]::WriteAllText($ResultFile, $_.Exception.Message, [Text.UTF8Encoding]::new($true)) } catch { }
    }
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
