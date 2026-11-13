param(
    [ValidateSet('auto', 'swiftshader')][string]$Graphics = 'auto',
    [switch]$Headless,
    [int]$Port = 0,
    [switch]$NoLaunch
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $root 'launch.ps1'
$recovery = Join-Path $PSScriptRoot 'recovery.ps1'
$pending = Join-Path $root 'data\update\pending'
$journalPath = Join-Path $pending 'transaction.json'
$applying = Join-Path $pending 'applying.flag'
$completed = Join-Path $pending 'completed.flag'
$targetHash = '6af5e91c467d0b4dbc9d6b1f34a5bf25aef2f422437864aad47b52e98d6b4840'
$legacyHashes = @(
    'f6ba9ca9102798014bed975dc2ad9d9f8409fac3f4f554d10e928f408ee0c07e',
    '49d234a4cee1e83af12385de3206e2a11939b2cabc35693dd885d1459fe7fac5'
)

# Recovery must run before core.ps1 is loaded: the preceding OTA may have
# stopped while replacing core itself. Check ancestors without loading it.
function Assert-BootstrapPathSafe([string]$Path) {
    $part = [IO.Path]::GetFullPath($Path)
    while ($part) {
        try { $attributes = [IO.File]::GetAttributes($part) }
        catch {
            $reason = $_.Exception
            while ($reason -is [Management.Automation.MethodInvocationException] -and $reason.InnerException) { $reason = $reason.InnerException }
            if ($reason -isnot [IO.FileNotFoundException] -and $reason -isnot [IO.DirectoryNotFoundException]) { throw 'Cannot verify the launch recovery path.' }
            $attributes = 0
        }
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Launch recovery paths cannot contain links or reparse points.' }
        $parent = [IO.Path]::GetDirectoryName($part.TrimEnd('\'))
        if (-not $parent -or [string]::Equals($parent, $part, [StringComparison]::OrdinalIgnoreCase)) { break }
        $part = $parent
    }
}
function Get-LauncherHash([string]$Path) {
    Assert-BootstrapPathSafe $Path
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Assert-BootstrapRuntimeStopped {
    Import-Module (Join-Path $PSHOME 'Modules\CimCmdlets\CimCmdlets.psd1') -ErrorAction Stop
    $prefix = [IO.Path]::GetFullPath((Join-Path $root 'sdk')).TrimEnd('\') + '\'
    $filter = "Name = 'emulator.exe' OR Name = 'qemu-system-x86_64.exe' OR Name = 'qemu-system-x86_64-headless.exe'"
    foreach ($process in @(Get-CimInstance Win32_Process -Filter $filter -ErrorAction Stop)) {
        if (-not $process.ExecutablePath) { throw 'Cannot verify emulator process paths; recovery has been stopped.' }
        $path = [IO.Path]::GetFullPath([string]$process.ExecutablePath)
        if ($path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'The emulator is still running. Close this installation before retrying recovery.' }
    }
}
function Write-BootstrapJournal($Journal) {
    Assert-UpdatePathSafe $journalPath
    $temp = Join-Path $pending ('transaction-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $previous = $temp + '.previous'
    Assert-UpdatePathSafe $temp
    Assert-UpdatePathSafe $previous
    try {
        [IO.File]::WriteAllText($temp, ($Journal | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        [IO.File]::Replace($temp, $journalPath, $previous)
    } finally {
        foreach ($path in @($temp, $previous)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
    }
}
function Get-BootstrapCompletedJournal {
    foreach ($path in @($pending, $journalPath, $applying, $completed)) { Assert-UpdatePathSafe $path }
    if (-not (Test-Path -LiteralPath $completed -PathType Leaf) -or (Test-Path -LiteralPath $applying) -or
        -not (Test-Path -LiteralPath $journalPath -PathType Leaf)) { throw 'The completed 1.0.4 OTA transaction is missing.' }
    $journal = [IO.File]::ReadAllText($journalPath) | ConvertFrom-Json
    $entries = @($journal.files)
    if ($journal.schema -ne 1 -or $journal.from -cne '1.0.3' -or $journal.to -cne '1.0.4' -or
        $entries.Count -lt 1 -or $entries.Count -gt 1000) { throw 'The launcher migration transaction is invalid.' }
    $seenPaths = @{}; $seenBackups = @{}; $hasVersion = $false
    foreach ($entry in $entries) {
        if ($entry.path -isnot [string] -or $entry.existed -isnot [bool] -or
            $entry.backup -isnot [string] -or $entry.backup -notmatch '^[0-9]{4}\.bak$') { throw 'The launcher migration backup record is invalid.' }
        [void](Get-UpdateTarget $root $entry.path)
        $key = $entry.path.ToLowerInvariant()
        if ($seenPaths.ContainsKey($key) -or $seenBackups.ContainsKey($entry.backup)) { throw 'The launcher migration transaction contains duplicate entries.' }
        $seenPaths[$key] = $true; $seenBackups[$entry.backup] = $true
        if ($key -ceq 'version.ini') { $hasVersion = $entry.existed }
        if ($entry.existed) {
            if ($entry.sha256 -isnot [string] -or $entry.sha256 -notmatch '^[0-9a-f]{64}$' -or
                (Get-LauncherHash (Join-Path $pending $entry.backup)) -cne $entry.sha256) { throw 'The launcher migration backup hash is invalid.' }
        } elseif ($entry.sha256 -cne '-') { throw 'The launcher migration new-file backup record is invalid.' }
        if ($key -ceq 'launch.ps1' -and (-not $entry.existed -or $entry.sha256 -cnotin $legacyHashes)) { throw 'The launcher migration backup is not a supported launcher.' }
    }
    if (-not $hasVersion) { throw 'The launcher migration transaction has no version backup.' }
    return $journal
}

$mutex = $null
$lockHeld = $false
try {
    foreach ($path in @($root, $recovery, $applying)) { Assert-BootstrapPathSafe $path }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $identity = [Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($root).TrimEnd('\').ToLowerInvariant())
        $mutexName = 'Local\ArtemisOS-Update-' + ([BitConverter]::ToString($sha.ComputeHash($identity))).Replace('-', '').Substring(0, 24)
    } finally { $sha.Dispose() }
    $mutex = New-Object Threading.Mutex($false, $mutexName)
    try { $lockHeld = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $lockHeld = $true }
    if (-not $lockHeld) { throw 'An update is still in progress. Retry after it has finished.' }
    # The original recovery re-enters this thread's same named mutex. Holding
    # it here closes the race between checking applying.flag and recovery.
    if (Test-Path -LiteralPath $applying -PathType Leaf) { Assert-BootstrapRuntimeStopped }
    & $recovery
    $core = Join-Path $PSScriptRoot 'core.ps1'
    Assert-BootstrapPathSafe $core
    . $core
    Assert-UpdatePathSafe $launcher
    if ((Get-UpdateVersion $root) -ceq '1.0.4' -and (Get-LauncherHash $launcher) -cne $targetHash) {
        $journal = Get-BootstrapCompletedJournal
        $originalHash = Get-LauncherHash $launcher
        try {
            if ($originalHash -cnotin $legacyHashes) { throw 'The existing launcher is not a supported release; it has not been overwritten.' }
            $payload = Join-Path $PSScriptRoot 'launcher-1.0.4.ps1'
            if ((Get-LauncherHash $payload) -cne $targetHash) { throw 'The signed 1.0.4 launcher payload hash does not match.' }
            Assert-BootstrapRuntimeStopped
            $entries = @($journal.files)
            $launcherEntries = @($entries | Where-Object { $_.path -ieq 'launch.ps1' })
            if ($launcherEntries.Count -eq 1) {
                if ($launcherEntries[0].sha256 -cne $originalHash) { throw 'The prepared launcher backup does not match the current launcher.' }
            } else {
                if ($entries.Count -ge 1000) { throw 'The launcher migration transaction is full.' }
                $used = @{}; foreach ($entry in $entries) { $used[$entry.backup] = $true }
                $index = 0
                while ($used.ContainsKey(('{0:D4}.bak' -f $index))) { $index++ }
                $backupName = '{0:D4}.bak' -f $index
                $backup = Join-Path $pending $backupName
                Assert-UpdatePathSafe $backup
                if (-not (Test-Path -LiteralPath $backup)) { [IO.File]::Copy($launcher, $backup) }
                if ((Get-LauncherHash $backup) -cne $originalHash) { throw 'The actual launcher backup hash does not match.' }
                $journal.files = $entries + @([pscustomobject]@{ path = 'launch.ps1'; existed = $true; backup = $backupName; sha256 = $originalHash })
                Write-BootstrapJournal $journal
            }
            if ((Get-LauncherHash $launcher) -cne $originalHash) { throw 'The launcher changed while preparing its migration.' }
            [IO.File]::Move($completed, $applying)
            $temp = Join-Path $root ('launch.artemis-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            $previous = $temp + '.previous'
            Assert-UpdatePathSafe $temp
            Assert-UpdatePathSafe $previous
            try {
                [IO.File]::Copy($payload, $temp)
                if ((Get-LauncherHash $temp) -cne $targetHash) { throw 'The copied launcher payload hash does not match.' }
                [IO.File]::Replace($temp, $launcher, $previous)
                if ((Get-LauncherHash $launcher) -cne $targetHash) { throw 'The installed launcher hash does not match.' }
                [IO.File]::Move($applying, $completed)
            } finally {
                foreach ($path in @($temp, $previous)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
            }
        } catch {
            $failure = $_
            # Never restore SDK files while a matching runtime is still alive.
            # Leave the transaction intact when process ownership is uncertain.
            Assert-BootstrapRuntimeStopped
            if (-not (Test-Path -LiteralPath $applying)) {
                # An unknown user launcher never became part of this migration.
                # Preserve it even if a previous preparation appended an entry.
                if ($originalHash -cnotin $legacyHashes) {
                    $journal.files = @($journal.files | Where-Object { $_.path -ine 'launch.ps1' })
                    Write-BootstrapJournal $journal
                }
                [IO.File]::Move($completed, $applying)
            }
            & $recovery
            throw $failure
        }
    }
} catch {
    if ($NoLaunch -or $Headless) { throw }
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show("ArtemisOS 启动或更新恢复失败。请保留现有数据后重试。`r`n`r`n$($_.Exception.Message)", 'ArtemisOS 15', 'OK', 'Error')
    exit 1
} finally {
    if ($lockHeld) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
if (-not $NoLaunch) { & $launcher -Graphics $Graphics -Headless:$Headless -Port $Port }
