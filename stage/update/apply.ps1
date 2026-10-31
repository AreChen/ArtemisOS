param(
    [Parameter(Mandatory = $true)][string]$Staging,
    [Parameter(Mandatory = $true)][string]$Serial,
    [int]$EmulatorPid = 0,
    [ValidateSet('auto','swiftshader')][string]$Graphics = 'auto',
    [switch]$NoRestart
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'core.ps1')
$dataRoot = Join-Path $root 'data\update'
$pending = Join-Path $dataRoot 'pending'
$log = Join-Path $dataRoot 'update.log'
[void][IO.Directory]::CreateDirectory($dataRoot)
$mutex = New-Object Threading.Mutex($false, (Get-UpdateMutexName $root))
$lockHeld = $false
function Write-UpdateLog([string]$Message) {
    Add-Content -LiteralPath $log -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message" -Encoding UTF8
}
function Restart-Artemis {
    if ($NoRestart) { return }
    $shortcut = if ($Graphics -eq 'swiftshader') { 'start-software.vbs' } else { 'start-auto.vbs' }
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + (Join-Path $root $shortcut) + '"') -WindowStyle Hidden | Out-Null
}
try {
    try { $lockHeld = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $lockHeld = $true }
    if (-not $lockHeld) { throw '另一个更新正在进行。' }
    $stageRoot = [IO.Path]::GetFullPath($dataRoot).TrimEnd('\') + '\'
    $stagePath = [IO.Path]::GetFullPath($Staging)
    if (-not $stagePath.StartsWith($stageRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $stagePath) -notmatch '^staged-[0-9a-f]{32}$' -or
        ((Get-Item -LiteralPath $stagePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw '暂存目录无效。'
    }
    $manifestBytes = [IO.File]::ReadAllBytes((Join-Path $stagePath 'manifest.json'))
    $signature = [IO.File]::ReadAllBytes((Join-Path $stagePath 'manifest.sig'))
    $manifest = Verify-UpdateManifest $root $manifestBytes $signature
    foreach ($item in @($manifest.files)) {
        $target = Get-UpdateTarget $root $item.path
        $source = Join-Path $stagePath $item.sha256
        if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or
            (Get-Item -LiteralPath $source).Length -ne [long]$item.size -or
            (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $item.sha256) {
            throw "暂存文件校验失败：$($item.path)"
        }
        if ($item.base_sha256 -eq '-') {
            if (Test-Path -LiteralPath $target) { throw "更新前文件已存在：$($item.path)" }
        } elseif (-not (Test-Path -LiteralPath $target -PathType Leaf) -or
            (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $item.base_sha256) {
            throw "更新前文件与预期版本不符：$($item.path)"
        }
    }
    if ($Serial -notmatch '^emulator-(\d+)$') { throw '模拟器编号无效。' }
    $port = $matches[1]
    $sdk = (Join-Path $root 'sdk\emulator\')
    $running = @(Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe'" |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($sdk, [StringComparison]::OrdinalIgnoreCase) })
    if ($running.Count -gt 0) {
        if ($running.Count -ne 1 -or $running[0].CommandLine -notmatch ("-port\s+" + $port + "(\s|$)")) {
            throw '无法唯一确认当前模拟器，未关闭或更新。'
        }
        $adb = Join-Path $root 'sdk\platform-tools\adb.exe'
        & $adb -s $Serial emu kill | Out-Null
        if ($LASTEXITCODE -ne 0) { throw '无法正常关闭模拟器。' }
        $until = [DateTime]::UtcNow.AddSeconds(60)
        while ((Get-Process -Id $running[0].ProcessId -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $until) {
            Start-Sleep -Milliseconds 500
        }
        if (Get-Process -Id $running[0].ProcessId -ErrorAction SilentlyContinue) { throw '模拟器尚未关闭，已取消更新。' }
    }
    if (Test-Path -LiteralPath (Join-Path $pending 'applying.flag')) { & (Join-Path $PSScriptRoot 'recovery.ps1') }
    if (Test-Path -LiteralPath $pending) {
        $archive = Join-Path $dataRoot ('previous-' + [Guid]::NewGuid().ToString('N'))
        $pendingFull = [IO.Path]::GetFullPath($pending)
        $archiveFull = [IO.Path]::GetFullPath($archive)
        $prefix = [IO.Path]::GetFullPath($dataRoot).TrimEnd('\') + '\'
        if (-not $pendingFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
            -not $archiveFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw '备份路径无效。' }
        Move-Item -LiteralPath $pending -Destination $archive
    }
    [void][IO.Directory]::CreateDirectory($pending)
    $entries = @()
    $index = 0
    $ordered = @($manifest.files | Where-Object { $_.path -ne 'version.ini' }) + @($manifest.files | Where-Object { $_.path -eq 'version.ini' })
    foreach ($item in $ordered) {
        $target = Get-UpdateTarget $root $item.path
        $existed = Test-Path -LiteralPath $target -PathType Leaf
        $backup = '{0:D4}.bak' -f $index
        if ($existed) {
            [IO.File]::Copy($target, (Join-Path $pending $backup))
            if ((Get-FileHash -LiteralPath (Join-Path $pending $backup) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $item.base_sha256) {
                throw "备份校验失败：$($item.path)"
            }
        }
        $entries += [ordered]@{path=$item.path;existed=$existed;backup=$backup;sha256=$item.base_sha256}
        $index++
    }
    $journal = [ordered]@{schema=1;from=$manifest.from;to=$manifest.to;files=$entries} | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText((Join-Path $pending 'transaction.json'), $journal, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $pending 'applying.flag'), '1', [Text.Encoding]::ASCII)
    foreach ($item in $ordered) {
        $target = Get-UpdateTarget $root $item.path
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        $temp = $target + '.artemis-' + [Guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::Copy((Join-Path $stagePath $item.sha256), $temp)
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $displaced = $target + '.artemis-prev-' + [Guid]::NewGuid().ToString('N') + '.tmp'
            [IO.File]::Replace($temp, $target, $displaced)
            Remove-Item -LiteralPath $displaced -Force
        }
        else { [IO.File]::Move($temp, $target) }
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $item.sha256) {
            throw "安装文件校验失败：$($item.path)"
        }
    }
    [IO.File]::Move((Join-Path $pending 'applying.flag'), (Join-Path $pending 'completed.flag'))
    try {
        $uninstall = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{E49344F1-069E-4DA4-A5B7-232C0BE325A8}_is1'
        if (Test-Path -LiteralPath $uninstall) {
            $registered = (Get-ItemProperty -LiteralPath $uninstall -Name InstallLocation).InstallLocation
            if ([IO.Path]::GetFullPath($registered).TrimEnd('\') -ieq [IO.Path]::GetFullPath($root).TrimEnd('\')) {
                Set-ItemProperty -LiteralPath $uninstall -Name DisplayVersion -Value $manifest.to
                Set-ItemProperty -LiteralPath $uninstall -Name DisplayName -Value ('ArtemisOS 15 版本 ' + $manifest.to)
            }
        }
    } catch { Write-UpdateLog "更新已安装，但 Windows 应用列表版本未能同步：$($_.Exception.Message)" }
    Write-UpdateLog "更新完成：$($manifest.from) -> $($manifest.to)。"
    Restart-Artemis
} catch {
    $problem = $_.Exception.Message
    if ($lockHeld) { try { & (Join-Path $PSScriptRoot 'recovery.ps1') } catch { $problem += ' 恢复失败：' + $_.Exception.Message } }
    Write-UpdateLog "更新失败：$problem"
    Restart-Artemis
    exit 1
} finally {
    if ($lockHeld) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
