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
Assert-UpdatePathSafe $log
[void][IO.Directory]::CreateDirectory($dataRoot)
$mutex = New-Object Threading.Mutex($false, (Get-UpdateMutexName $root))
$lockHeld = $false
$safeToRecover = $false
$applied = $false
$failure = $null
function Write-UpdateLog([string]$Message) {
    Assert-UpdatePathSafe $log
    Add-Content -LiteralPath $log -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message" -Encoding UTF8
}
function Sync-WindowsAppRegistration([string]$InstallRoot, [string]$Version, [string]$UninstallBase) {
    function Normalize-InstallLocation([string]$Path) {
        # Reject relative and drive-relative paths instead of resolving them
        # against the updater's current working directory.
        if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path) -or
            $Path -notmatch '^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/]+[\\/][^\\/]+(?:[\\/]|$))') {
            throw '安装目录不是完整路径。'
        }
        $full = [IO.Path]::GetFullPath($Path)
        $volumeRoot = [IO.Path]::GetPathRoot($full)
        if ($full.Length -gt $volumeRoot.Length) {
            $full = $full.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
        }
        return $full
    }

    $expected = Normalize-InstallLocation $InstallRoot
    $registrations = @(
        @{ Name = '{E49344F1-069E-4DA4-A5B7-232C0BE325A8}_is1'; Legacy = $true },
        @{ Name = 'ArtemisOS15-Release_is1'; Legacy = $false }
    )
    foreach ($registration in $registrations) {
        $key = Join-Path $UninstallBase $registration.Name
        try {
            if (-not (Test-Path -LiteralPath $key)) { continue }
            $registered = (Get-ItemProperty -LiteralPath $key -Name InstallLocation -ErrorAction Stop).InstallLocation
            $actual = Normalize-InstallLocation ([string]$registered)
            if (-not [StringComparer]::OrdinalIgnoreCase.Equals($expected, $actual)) { continue }
            Set-ItemProperty -LiteralPath $key -Name DisplayVersion -Value $Version -ErrorAction Stop
            # Preserve the new release's distinct installed-app name. The
            # legacy identity retains its previous display-name behavior.
            if ($registration.Legacy) {
                Set-ItemProperty -LiteralPath $key -Name DisplayName -Value ('ArtemisOS 15 版本 ' + $Version) -ErrorAction Stop
            }
        } catch {
            Write-UpdateLog "更新已安装，但 Windows 应用列表版本未能同步（$($registration.Name)）：$($_.Exception.Message)"
        }
    }
}
function Restart-Artemis {
    if ($NoRestart) { return }
    $shortcut = if ($Graphics -eq 'swiftshader') { 'start-software.vbs' } else { 'start-auto.vbs' }
    Assert-UpdatePathSafe (Join-Path $root $shortcut)
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + (Join-Path $root $shortcut) + '"') -WindowStyle Hidden | Out-Null
}
function Wait-ArtemisRuntimeExit([string]$Sdk, [string]$Filter, [int]$TimeoutSeconds = 45) {
    # Android Emulator can start short-lived `emulator -kill ... -sleep 20`
    # watchdogs while shutting down. They are not new instances, but must also
    # exit before any runtime files can safely be replaced.
    $prefix = [IO.Path]::GetFullPath($Sdk).TrimEnd('\') + '\'
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        $active = $false
        $unresolved = $false
        foreach ($process in @(Get-CimInstance Win32_Process -Filter $Filter -ErrorAction Stop)) {
            # CIM can briefly lose ExecutablePath while a shutdown watchdog
            # exits. Treat unavailable metadata as still active; only a later
            # snapshot may prove exit or a path outside this installation.
            if ([string]::IsNullOrWhiteSpace([string]$process.ExecutablePath)) {
                $active = $true; $unresolved = $true; continue
            }
            try { $path = [IO.Path]::GetFullPath([string]$process.ExecutablePath) }
            catch { $active = $true; $unresolved = $true; continue }
            if ($path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $active = $true }
        }
        if (-not $active) { return }
        if ([DateTime]::UtcNow -ge $deadline) {
            if ($unresolved) { throw '等待模拟器退出超时，仍无法确认进程的安装路径，已取消更新。' }
            throw '模拟器进程尚未完全退出，已取消更新。'
        }
        Start-Sleep -Milliseconds 500
    }
}
try {
    try { $lockHeld = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $lockHeld = $true }
    if (-not $lockHeld) { throw '另一个更新正在进行。' }
    $stageRoot = [IO.Path]::GetFullPath($dataRoot).TrimEnd('\') + '\'
    $stagePath = [IO.Path]::GetFullPath($Staging)
    if (-not $stagePath.StartsWith($stageRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([IO.Path]::GetDirectoryName($stagePath).TrimEnd('\'), $stageRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $stagePath) -notmatch '^staged-[0-9a-f]{32}$' -or
        ((Get-Item -LiteralPath $stagePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw '暂存目录无效。'
    }
    Assert-UpdatePathSafe (Join-Path $stagePath 'manifest.json')
    Assert-UpdatePathSafe (Join-Path $stagePath 'manifest.sig')
    Assert-UpdatePathSafe $pending
    $manifestBytes = [IO.File]::ReadAllBytes((Join-Path $stagePath 'manifest.json'))
    $signature = [IO.File]::ReadAllBytes((Join-Path $stagePath 'manifest.sig'))
    $manifest = Verify-UpdateManifest $root $manifestBytes $signature
    foreach ($item in @($manifest.files)) {
        $target = Get-UpdateTarget $root $item.path
        $source = Join-Path $stagePath $item.sha256
        Assert-UpdatePathSafe $source
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
    $sdk = (Join-Path $root 'sdk\emulator\')
    Assert-UpdatePathSafe $sdk
    $filter = "Name='qemu-system-x86_64.exe' OR Name='qemu-system-x86_64-headless.exe' OR Name='emulator.exe'"
    $processes = @(Get-CimInstance Win32_Process -Filter $filter -ErrorAction Stop)
    $running = Get-VerifiedUpdateEmulator $processes $sdk $Serial $EmulatorPid
    if ($null -eq $running -and $EmulatorPid -gt 0 -and (Get-Process -Id $EmulatorPid -ErrorAction SilentlyContinue)) {
        throw '无法确认发起更新的模拟器进程。'
    }
    # The frontend and its viewer must release their files before backend exit
    # and replacement. It exits cooperatively; the updater alone stops QEMU.
    $frontendHandoff = Join-Path $PSScriptRoot 'frontend-handoff.ps1'
    if (Test-Path -LiteralPath $frontendHandoff -PathType Leaf) {
        Assert-UpdatePathSafe $frontendHandoff
        . $frontendHandoff
        if (Request-ArtemisFrontendExitForUpdate -InstallRoot $root -Serial $Serial -EmulatorPid $EmulatorPid) {
            Write-UpdateLog '前端与显示端已退出，开始停止所属模拟器并安装更新。'
        }
    } elseif (Test-Path -LiteralPath (Join-Path $root 'update\frontend\ArtemisFrontend.exe')) {
        throw '缺少前端更新交接组件，未关闭模拟器或替换文件。'
    }
    if ($null -ne $running) {
        $adb = Join-Path $root 'sdk\platform-tools\adb.exe'
        Assert-UpdatePathSafe $adb
        & $adb -s $Serial emu kill | Out-Null
        if ($LASTEXITCODE -ne 0) { throw '无法正常关闭模拟器。' }
        $until = [DateTime]::UtcNow.AddSeconds(60)
        while ((Get-Process -Id $running.ProcessId -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $until) {
            Start-Sleep -Milliseconds 500
        }
        if (Get-Process -Id $running.ProcessId -ErrorAction SilentlyContinue) { throw '模拟器尚未关闭，已取消更新。' }
        Wait-ArtemisRuntimeExit $sdk $filter
    }
    # Recovery may replace runtime files. Never attempt it until the emulator
    # process state has been verified and any matching instance has exited.
    $safeToRecover = $true
    if (Test-Path -LiteralPath (Join-Path $pending 'applying.flag')) { & (Join-Path $PSScriptRoot 'recovery.ps1') }
    if (Test-Path -LiteralPath $pending) {
        $archive = Join-Path $dataRoot ('previous-' + [Guid]::NewGuid().ToString('N'))
        Assert-UpdatePathSafe $pending
        Assert-UpdatePathSafe $archive
        $pendingFull = [IO.Path]::GetFullPath($pending)
        $archiveFull = [IO.Path]::GetFullPath($archive)
        $prefix = [IO.Path]::GetFullPath($dataRoot).TrimEnd('\') + '\'
        if (-not $pendingFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
            -not $archiveFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw '备份路径无效。' }
        Move-Item -LiteralPath $pending -Destination $archive
    }
    [void][IO.Directory]::CreateDirectory($pending)
    Assert-UpdatePathSafe $pending
    $entries = @()
    $index = 0
    $ordered = @($manifest.files | Where-Object { $_.path -ne 'version.ini' }) + @($manifest.files | Where-Object { $_.path -eq 'version.ini' })
    foreach ($item in $ordered) {
        $target = Get-UpdateTarget $root $item.path
        $existed = Test-Path -LiteralPath $target -PathType Leaf
        $backup = '{0:D4}.bak' -f $index
        if ($existed) {
            Assert-UpdatePathSafe (Join-Path $pending $backup)
            [IO.File]::Copy($target, (Join-Path $pending $backup))
            if ((Get-FileHash -LiteralPath (Join-Path $pending $backup) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $item.base_sha256) {
                throw "备份校验失败：$($item.path)"
            }
        }
        $entries += [ordered]@{path=$item.path;existed=$existed;backup=$backup;sha256=$item.base_sha256}
        $index++
    }
    $journal = [ordered]@{schema=1;from=$manifest.from;to=$manifest.to;files=$entries} | ConvertTo-Json -Depth 6
    Assert-UpdatePathSafe (Join-Path $pending 'transaction.json')
    Assert-UpdatePathSafe (Join-Path $pending 'applying.flag')
    [IO.File]::WriteAllText((Join-Path $pending 'transaction.json'), $journal, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $pending 'applying.flag'), '1', [Text.Encoding]::ASCII)
    foreach ($item in $ordered) {
        $target = Get-UpdateTarget $root $item.path
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        $temp = $target + '.artemis-' + [Guid]::NewGuid().ToString('N') + '.tmp'
        Assert-UpdatePathSafe (Join-Path $stagePath $item.sha256)
        Assert-UpdatePathSafe $temp
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
    Assert-UpdatePathSafe (Join-Path $pending 'completed.flag')
    [IO.File]::Move((Join-Path $pending 'applying.flag'), (Join-Path $pending 'completed.flag'))
    $applied = $true
    try {
        Sync-WindowsAppRegistration $root $manifest.to 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    } catch { Write-UpdateLog "更新已安装，但 Windows 应用列表版本未能同步：$($_.Exception.Message)" }
    Write-UpdateLog "更新完成：$($manifest.from) -> $($manifest.to)。"
    Restart-Artemis
} catch {
    $problem = $_.Exception.Message
    if ($lockHeld -and $safeToRecover) { try { & (Join-Path $PSScriptRoot 'recovery.ps1') } catch { $problem += ' 恢复失败：' + $_.Exception.Message } }
    try { Write-UpdateLog "更新失败：$problem" } catch { }
    $failure = $problem
} finally {
    if ($lockHeld) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
if ($null -ne $failure) {
    if (-not $NoRestart -and [Environment]::UserInteractive) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            $message = if ($applied) {
                "更新已安装，但未能自动启动模拟器。请手动启动。`r`n`r`n$failure"
            } else {
                "更新未完成。请检查模拟器状态后重试。`r`n`r`n$failure"
            }
            [void][Windows.Forms.MessageBox]::Show($message, 'ArtemisOS 15 更新', 'OK', 'Warning')
        } catch { }
    }
    exit 1
}
