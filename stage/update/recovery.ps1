param(
    [switch]$Launch,
    [ValidateSet('auto','swiftshader')][string]$Graphics = 'auto'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$root = Split-Path -Parent $PSScriptRoot
$pending = Join-Path $root 'data\update\pending'
$flag = Join-Path $pending 'applying.flag'
$journalPath = Join-Path $pending 'transaction.json'
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $identity = [Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($root).TrimEnd('\').ToLowerInvariant())
    $mutexName = 'Local\ArtemisOS-Update-' + ([BitConverter]::ToString($sha.ComputeHash($identity))).Replace('-', '').Substring(0, 24)
} finally { $sha.Dispose() }
$mutex = New-Object Threading.Mutex($false, $mutexName)
$lockHeld = $false

# Recovery deliberately stays independent of core.ps1: core may itself have
# been interrupted during an update. Never enumerate the user's AVD files.
function Assert-RecoveryPathSafe([string]$Path) {
    $parts = New-Object 'System.Collections.Generic.List[string]'
    $part = [IO.Path]::GetFullPath($Path)
    while ($part) {
        $parts.Add($part)
        $parent = [IO.Path]::GetDirectoryName($part.TrimEnd('\'))
        if (-not $parent -or [string]::Equals($part, $parent, [StringComparison]::OrdinalIgnoreCase)) { break }
        $part = $parent
    }
    for ($i = $parts.Count - 1; $i -ge 0; $i--) {
        try { $attributes = [IO.File]::GetAttributes($parts[$i]) }
        catch {
            $reason = $_.Exception
            while ($reason -is [Management.Automation.MethodInvocationException] -and $reason.InnerException) { $reason = $reason.InnerException }
            if ($reason -is [IO.FileNotFoundException] -or $reason -is [IO.DirectoryNotFoundException]) { continue }
            throw '无法确认恢复路径是否安全。'
        }
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '恢复路径不能包含链接或重解析点。' }
    }
}

function Get-RecoveryTarget([string]$Relative) {
    $rootFiles = @('launch.ps1','settings.ps1','initialize.ps1','configure.ps1','configure.vbs',
        'start-auto.vbs','start-software.vbs','version.ini','ArtemisOS15.ico')
    $segments = $Relative -split '/'
    if ($Relative -notmatch '^[A-Za-z0-9._/-]+$' -or $Relative.Contains('//') -or
        @($segments | Where-Object { $_ -in @('', '.', '..') -or $_.EndsWith('.') -or $_ -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)' }).Count -gt 0) {
        throw '恢复记录包含无效的文件路径。'
    }
    if (-not ($Relative -in $rootFiles -or
        ($Relative -match '^update/[A-Za-z0-9._/-]+$' -and $Relative -notin @('update/recovery.ps1','update/trusted-key.xml','update/server.txt')) -or
        $Relative -match '^sdk/[A-Za-z0-9._/-]+$')) { throw '恢复记录包含不允许的路径。' }
    $prefix = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
    $target = [IO.Path]::GetFullPath((Join-Path $root ($Relative.Replace('/', '\'))))
    if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw '恢复路径超出安装目录。' }
    Assert-RecoveryPathSafe $target
    $part = $root
    foreach ($segment in $segments) {
        $part = Join-Path $part $segment
        if ((Test-Path -LiteralPath $part) -and ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw '恢复路径包含链接或重解析点。'
        }
    }
    return $target
}

try {
try { $lockHeld = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $lockHeld = $true }
if (-not $lockHeld) { throw '更新正在进行中，请稍后重试。' }
Assert-RecoveryPathSafe $flag
Assert-RecoveryPathSafe $journalPath
if (Test-Path -LiteralPath $flag -PathType Leaf) {
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) { throw '更新恢复记录缺失，请勿重新安装或清理数据。' }
    $journal = [IO.File]::ReadAllText($journalPath) | ConvertFrom-Json
    $entries = @($journal.files)
    if ($journal.schema -ne 1 -or $entries.Count -lt 1 -or $entries.Count -gt 1000) { throw '更新恢复记录无效。' }
    foreach ($entry in $entries) {
        [void](Get-RecoveryTarget $entry.path)
        if ($entry.existed) {
            if ($entry.backup -notmatch '^[0-9]{4}\.bak$' -or $entry.sha256 -notmatch '^[0-9a-f]{64}$') { throw '备份记录无效。' }
            $backup = Join-Path $pending $entry.backup
            Assert-RecoveryPathSafe $backup
            if (-not (Test-Path -LiteralPath $backup -PathType Leaf) -or
                (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.sha256) {
                throw '更新备份校验失败，请保留当前文件并联系维护人员。'
            }
        }
    }
    foreach ($entry in $entries) {
        $target = Get-RecoveryTarget $entry.path
        if ($entry.existed) {
            Assert-RecoveryPathSafe (Join-Path $pending $entry.backup)
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
            $temp = $target + '.artemis-' + [Guid]::NewGuid().ToString('N') + '.tmp'
            Assert-RecoveryPathSafe $temp
            [IO.File]::Copy((Join-Path $pending $entry.backup), $temp)
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                $displaced = $target + '.artemis-prev-' + [Guid]::NewGuid().ToString('N') + '.tmp'
                [IO.File]::Replace($temp, $target, $displaced)
                Remove-Item -LiteralPath $displaced -Force
            }
            else { [IO.File]::Move($temp, $target) }
        } elseif (Test-Path -LiteralPath $target -PathType Leaf) {
            Remove-Item -LiteralPath $target -Force
        }
    }
    Assert-RecoveryPathSafe (Join-Path $pending 'recovered.flag')
    [IO.File]::Move($flag, (Join-Path $pending 'recovered.flag'))
}
} catch {
    if ($Launch) {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show("更新恢复失败，已停止启动。请保留模拟器数据并联系维护人员。`r`n`r`n$($_.Exception.Message)", 'ArtemisOS 15', 'OK', 'Error')
        exit 1
    }
    throw
} finally {
    if ($lockHeld) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
if ($Launch) {
    $launcher = Join-Path $root 'launch.ps1'
    & $launcher -Graphics $Graphics
    exit $LASTEXITCODE
}
