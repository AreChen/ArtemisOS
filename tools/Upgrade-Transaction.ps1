[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Apply', 'Recover', 'Rollback')][string]$Action,
    [Parameter(Mandatory = $true)][string]$Target,
    [string]$Payload,
    # Deliberately unavailable outside an isolated temp-directory fixture.
    [ValidateSet('', 'Prepared', 'SdkMoved', 'OldMoved', 'SdkRestored', 'NewMoved', 'RollbackMoved', 'MutationAfterUnlock')][string]$TestCrashAt = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This first migration deliberately accepts only 0.3.4/0.3.5/0.3.6 to
# 1.0.0. A future signed, versioned payload policy is separate work.
# The entire sdk tree is an owned component. Everything outside it is retained
# unless its path is one of the product files shipped by the installer.
$managedRoot = @('version.ini', 'launch.ps1', 'settings.ps1', 'initialize.ps1',
    'configure.ps1', 'configure.vbs', 'start-auto.vbs', 'start-software.vbs',
    'ArtemisOS15.ico', ([string]::Concat([char[]](0x4f7f, 0x7528, 0x8bf4, 0x660e)) + '.txt'))
$managedUpdate = @('apply.ps1', 'ArtemisUpdate.apk', 'bridge.ps1', 'core.ps1',
    'recovery.ps1', 'trusted-key.xml')
$requiredSdk = @('emulator\emulator.exe', 'emulator\qemu\windows-x86_64\qemu-system-x86_64.exe',
    'emulator\qemu\windows-x86_64\qemu-system-x86_64-headless.exe',
    'platform-tools\adb.exe', 'system-images\android-35\google_apis\x86_64\system.img',
    'system-images\android-35\google_apis\x86_64\vendor.img',
    'system-images\android-35\google_apis\x86_64\ramdisk.img',
    'system-images\android-35\google_apis\x86_64\kernel-ranchu')
$script:guards = New-Object 'System.Collections.Generic.List[System.IO.FileStream]'
$script:mutex = $null
$script:mutexOwned = $false
$script:legacyMutex = $null
$script:legacyMutexOwned = $false

function Fail([string]$Message) { throw $Message }
function Canonical-LocalPath([string]$Path, [bool]$MustExist) {
    if (-not $Path -or $Path -notmatch '^[A-Za-z]:\\' -or $Path -match '[\*\?]' -or $Path.Substring(2).Contains(':')) {
        Fail 'A local, absolute drive path without alternate-stream syntax is required.'
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full.Length -le 3 -or $full -match '[\x00-\x1f]') { Fail 'Unsafe root or path.' }
    $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($full))
    if (-not $drive.IsReady -or $drive.DriveType -ne [IO.DriveType]::Fixed -or $drive.DriveFormat -ne 'NTFS') {
        Fail 'Upgrade requires a ready local fixed NTFS volume.'
    }
    if ($MustExist -and -not [IO.Directory]::Exists($full)) { Fail "Directory does not exist: $full" }
    # Refuse junctions and symbolic links anywhere in the existing ancestry.
    $part = $full
    while ($part) {
        if ([IO.File]::Exists($part) -or [IO.Directory]::Exists($part)) {
            if (([IO.File]::GetAttributes($part) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Fail "A path component is a reparse point: $part"
            }
        }
        $parent = [IO.Directory]::GetParent($part)
        if ($null -eq $parent) { break }
        $part = $parent.FullName
    }
    return $full
}
function Assert-Separate([string]$A, [string]$B) {
    if ($A.Equals($B, [StringComparison]::OrdinalIgnoreCase) -or
        $A.StartsWith($B + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $B.StartsWith($A + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Fail 'Target and payload must be separate directory trees.'
    }
}
function Get-HashText([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Get-Version([string]$Root) {
    $path = Join-Path $Root 'version.ini'
    if (-not [IO.File]::Exists($path)) { Fail "Missing ArtemisOS version file: $path" }
    $content = [IO.File]::ReadAllText($path)
    if ($content -notmatch '(?im)^\s*\[ArtemisOS\]\s*$') { Fail 'Invalid ArtemisOS product marker.' }
    $versions = [regex]::Matches($content, '(?im)^\s*Version=(\d+\.\d+\.\d+)\s*$')
    if ($versions.Count -ne 1) { Fail 'Invalid or ambiguous ArtemisOS version.' }
    try { return [version]$versions[0].Groups[1].Value } catch { Fail 'Invalid ArtemisOS version number.' }
}
function Assert-Sdk([string]$Root) {
    foreach ($relative in $requiredSdk) {
        if (-not [IO.File]::Exists((Join-Path (Join-Path $Root 'sdk') $relative))) {
            Fail "The installation is missing a required SDK file: $relative"
        }
    }
    if (-not [IO.File]::Exists((Join-Path $Root 'start-auto.vbs'))) { Fail 'Missing ArtemisOS launcher.' }
}
function Get-Tree([string]$Root) {
    $all = New-Object 'System.Collections.Generic.List[System.IO.FileSystemInfo]'
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($entry in (Get-Item -LiteralPath $directory -Force).EnumerateFileSystemInfos()) {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Fail "Reparse points are not supported: $($entry.FullName)" }
            $all.Add($entry)
            if (($entry.Attributes -band [IO.FileAttributes]::Directory) -ne 0) { $pending.Push($entry.FullName) }
        }
    }
    return ,$all
}
function Relative-Path([string]$Root, [string]$Path) {
    if (-not $Path.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) { Fail 'Entry escaped its tree.' }
    return $Path.Substring($Root.Length + 1)
}
function Is-Owned([string]$Relative) {
    if ($Relative -match '^(?i:sdk)(?:\\|$)') { return $true }
    if ($Relative -notmatch '\\') { return $managedRoot -icontains $Relative }
    if ($Relative -match '^(?i:update)\\([^\\]+)$') { return $managedUpdate -icontains $Matches[1] }
    if ($Relative -match '^(?i:licenses)\\([^\\]+)$') {
        return @('Android-Emulator-Preview-License.txt', 'Android-SDK-License.txt') -icontains $Matches[1]
    }
    return $false
}
function Get-Streams([string]$Path) {
    return @(Get-Item -LiteralPath $Path -Stream * -ErrorAction Stop | Where-Object { $_.Stream -ne ':$DATA' } | ForEach-Object { $_.Stream } | Sort-Object)
}
function Open-ReadStream([string]$Path, [string]$Name = '') {
    if (-not $Name) {
        return [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
    }
    # .NET Framework path validation rejects NTFS stream names. CreateFileW
    # opens them directly, while enforcing the same read-only share policy.
    if (-not ('ArtemisUpgrade.NativeStreams' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace ArtemisUpgrade {
    public static class NativeStreams {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern SafeFileHandle CreateFileW(string name, uint access, uint share,
            IntPtr security, uint disposition, uint flags, IntPtr template);
        public static FileStream OpenRead(string path, string stream) {
            SafeFileHandle handle = CreateFileW(path + ":" + stream, 0x80000000,
                0x00000001 | 0x00000004, IntPtr.Zero, 3, 0, IntPtr.Zero);
            if (handle.IsInvalid) { int error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error); }
            return new FileStream(handle, FileAccess.Read, 4096, false);
        }
    }
}
'@
    }
    return [ArtemisUpgrade.NativeStreams]::OpenRead($Path, $Name)
}
function Hash-Stream([string]$Path, [string]$Name = '') {
    $hash = [Security.Cryptography.SHA256]::Create()
    $stream = Open-ReadStream $Path $Name
    try { return ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-', '') }
    finally { $stream.Dispose(); $hash.Dispose() }
}
function Copy-Verified([string]$Source, [string]$Destination) {
    $directory = [IO.Path]::GetDirectoryName($Destination)
    [void][IO.Directory]::CreateDirectory($directory)
    [IO.File]::Copy($Source, $Destination, $false)
    if ((Hash-Stream $Source) -cne (Hash-Stream $Destination)) { Fail "File verification failed: $Source" }
    $before = @(Get-Streams $Source)
    $after = @(Get-Streams $Destination)
    if (($before -join "`n") -cne ($after -join "`n")) { Fail "Stream verification failed: $Source" }
    foreach ($stream in $before) {
        if ((Hash-Stream $Source $stream) -cne (Hash-Stream $Destination $stream)) {
            Fail "Stream verification failed: $Source"
        }
    }
}
function Assert-Identical([string]$Source, [string]$Destination) {
    $sourceHash = Hash-Stream $Source
    if (-not [IO.File]::Exists($Destination) -or $sourceHash -cne (Hash-Stream $Destination)) {
        Fail "Preserved data changed during the swap: $Source"
    }
    $before = @(Get-Streams $Source)
    $after = @(Get-Streams $Destination)
    if (($before -join "`n") -cne ($after -join "`n")) { Fail "Preserved streams changed during the swap: $Source" }
    $streams = @()
    foreach ($stream in $before) {
        $streamHash = Hash-Stream $Source $stream
        if ($streamHash -cne (Hash-Stream $Destination $stream)) {
            Fail "Preserved streams changed during the swap: $Source"
        }
        $streams += [pscustomobject]@{ name = $stream; sha256 = $streamHash }
    }
    return [pscustomobject]@{ sha256 = $sourceHash; streams = @($streams) }
}
function Get-LogicalBytes([IO.FileSystemInfo]$Entry) {
    if (($Entry.Attributes -band [IO.FileAttributes]::Directory) -ne 0) { return [int64]0 }
    $size = [int64]$Entry.Length
    foreach ($stream in @(Get-Item -LiteralPath $Entry.FullName -Stream * -ErrorAction Stop)) {
        if ($stream.Stream -ne ':$DATA') { $size += [int64]$stream.Length }
    }
    return $size
}
function Lock-TreeFiles($Entries, [string]$Root) {
    foreach ($entry in $Entries) {
        if (($entry.Attributes -band [IO.FileAttributes]::Directory) -ne 0) { continue }
        $rel = Relative-Path $Root $entry.FullName
        if ($rel -match '^(?i:sdk)\\') { continue }
        $share = [IO.FileShare]::Read -bor [IO.FileShare]::Delete
        $script:guards.Add([IO.File]::Open($entry.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share))
        foreach ($stream in @(Get-Streams $entry.FullName)) {
            $script:guards.Add((Open-ReadStream $entry.FullName $stream))
        }
    }
}
function Release-Guards {
    foreach ($guard in $script:guards) { $guard.Dispose() }
    $script:guards.Clear()
}
function Assert-NoRunning([string]$Root) {
    # Do not terminate anything. Refuse owned emulator/QEMU/ADB bridge processes.
    $owned = $Root + '\'
    $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    foreach ($process in $processes) {
        if ($process.Name -match '^(?i:powershell|pwsh)(?:\.exe)?$') {
            $scriptCmd = [string]$process.CommandLine
            if ($scriptCmd -and $scriptCmd.IndexOf($owned, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                $scriptCmd -match '(?i)update[\\/](?:apply|recovery|bridge)\.ps1') {
                Fail 'The selected installation has a running OTA process. Close it and retry.'
            }
            continue
        }
        if ($process.Name -notmatch '^(?i:emulator|qemu-system-[^\\]+|adb)(?:\.exe)?$') { continue }
        $exe = [string]$process.ExecutablePath
        $cmd = [string]$process.CommandLine
        if (-not $exe -or -not $cmd) { Fail 'A virtual-device process could not be inspected; close it and retry.' }
        if ($exe.StartsWith($owned, [StringComparison]::OrdinalIgnoreCase) -or
            $cmd.IndexOf($owned, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Fail 'The selected installation has a running emulator or related process. Close it and retry.'
        }
    }
}
function Write-JsonAtomic([string]$Path, $Object) {
    $tmp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Object | ConvertTo-Json -Depth 10 -Compress))
    $stream = New-Object IO.FileStream ($tmp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    if ([IO.File]::Exists($Path)) {
        # Windows PowerShell 5.1 converts a null backup path to an invalid
        # empty string; keep uniquely named previous journals instead.
        [IO.File]::Replace($tmp, $Path, ($Path + '.previous.' + [guid]::NewGuid().ToString('N')))
    } else { [IO.File]::Move($tmp, $Path) }
}
function Set-State([string]$State) {
    $script:record.state = $State
    Write-JsonAtomic $script:recordFile $script:record
}
function Test-Crash([string]$Point) {
    if ($TestCrashAt -eq $Point) { [Environment]::Exit(91) }
}
function Read-Record {
    if (-not [IO.File]::Exists($script:recordFile)) {
        if ([IO.Directory]::Exists($script:txRoot)) { Fail 'A transaction directory exists without a valid record; it was retained.' }
        return $null
    }
    if (([IO.File]::GetAttributes($script:recordFile) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail 'A transaction record cannot be a reparse point.'
    }
    $item = [IO.File]::ReadAllText($script:recordFile) | ConvertFrom-Json
    if ($item.product -cne 'ArtemisOS-15' -or $item.schema -ne 1 -or
        -not [string]::Equals([string]$item.target, $script:targetPath, [StringComparison]::OrdinalIgnoreCase) -or
        $item.id -notmatch '^[0-9a-f]{32}$' -or
        $item.oldVersion -notmatch '^\d+\.\d+\.\d+$' -or $item.newVersion -cne '1.0.0' -or
        $item.state -notin @('preparing', 'prepared', 'sdk-intent', 'old-intent', 'new-intent', 'applied', 'abandoned', 'rollback-intent', 'rolled-back')) {
        Fail 'The existing transaction record is invalid or belongs to another target.'
    }
    return $item
}
function Test-DirVersion([string]$Path, [string]$Version) {
    if (-not [IO.Directory]::Exists($Path)) { return $false }
    try { return (Get-Version $Path).ToString() -ceq $Version } catch { return $false }
}
function Test-TransactionMarker([string]$Root, [string]$Kind) {
    $marker = Join-Path $Root ('.artemisos-' + $script:record.id + '-' + $Kind + '.marker')
    if (-not [IO.File]::Exists($marker)) { return $false }
    if (([IO.File]::GetAttributes($marker) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    try { return [IO.File]::ReadAllText($marker) -ceq ($script:record.id + ':' + $Kind) } catch { return $false }
}
function Write-TransactionMarker([string]$Root, [string]$Kind) {
    $marker = Join-Path $Root ('.artemisos-' + $script:record.id + '-' + $Kind + '.marker')
    $bytes = [Text.Encoding]::ASCII.GetBytes($script:record.id + ':' + $Kind)
    $stream = New-Object IO.FileStream ($marker, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Paths-ForRecord {
    $script:tx = Join-Path $script:txRoot $script:record.id
    if (-not [IO.Directory]::Exists($script:tx)) { Fail 'The transaction directory is missing.' }
    [void](Canonical-LocalPath $script:tx $true)
    $script:newPath = Join-Path $script:tx 'new'
    $script:oldPath = Join-Path $script:tx 'old'
    $script:blockedSdk = Join-Path $script:tx 'blocked-sdk'
    $script:upgradedPath = Join-Path $script:tx 'upgraded-preserved'
    $script:dataManifestPath = Join-Path $script:tx 'data-manifest.json'
    foreach ($path in @($script:newPath, $script:oldPath, $script:blockedSdk, $script:upgradedPath)) {
        if ([IO.Directory]::Exists($path)) { [void](Canonical-LocalPath $path $true) }
    }
}
function Assert-DataBackup {
    if (-not [IO.File]::Exists($script:dataManifestPath) -or
        (([IO.File]::GetAttributes($script:dataManifestPath) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Fail 'The verified data-backup manifest is missing or unsafe.'
    }
    $manifest = [IO.File]::ReadAllText($script:dataManifestPath) | ConvertFrom-Json
    if ($manifest.schema -ne 1 -or $manifest.id -cne $script:record.id -or $manifest.product -cne 'ArtemisOS-15') {
        Fail 'The data-backup manifest does not match the transaction.'
    }
    $dataRoot = Join-Path $script:oldPath 'data'
    if (-not [IO.Directory]::Exists($dataRoot)) { Fail 'The retained user data directory is missing.' }
    $actual = Get-Tree $dataRoot
    $manifestNames = @($manifest.entries | ForEach-Object { ([string]$_.path).ToLowerInvariant() } | Sort-Object)
    $actualNames = @($actual | ForEach-Object { (Relative-Path $dataRoot $_.FullName).ToLowerInvariant() } | Sort-Object)
    if (($manifestNames -join "`n") -cne ($actualNames -join "`n")) { Fail 'The retained data-backup contents changed.' }
    foreach ($entry in $manifest.entries) {
        $rel = [string]$entry.path
        if (-not $rel -or [IO.Path]::IsPathRooted($rel) -or $rel -match '(^|\\)\.\.?($|\\)' -or $rel.Contains(':')) {
            Fail 'The data-backup manifest has an unsafe path.'
        }
        $file = Join-Path $dataRoot $rel
        if ($entry.kind -eq 'directory') {
            if (-not [IO.Directory]::Exists($file)) { Fail 'A backed-up data directory is missing.' }
            continue
        }
        if ($entry.kind -ne 'file' -or $entry.sha256 -notmatch '^[0-9A-F]{64}$' -or
            -not [IO.File]::Exists($file) -or (Hash-Stream $file) -cne $entry.sha256) {
            Fail 'A backed-up data file failed verification.'
        }
        $expectedStreams = @($entry.streams | ForEach-Object { [string]$_.name } | Sort-Object)
        $actualStreams = @(Get-Streams $file)
        if (($expectedStreams -join "`n") -cne ($actualStreams -join "`n")) { Fail 'A backed-up data stream is missing or unexpected.' }
        foreach ($stream in $entry.streams) {
            if ($stream.sha256 -notmatch '^[0-9A-F]{64}$' -or (Hash-Stream $file ([string]$stream.name)) -cne $stream.sha256) {
                Fail 'A backed-up data stream failed verification.'
            }
        }
    }
}
function Recover-Transaction {
    $script:record = Read-Record
    if ($null -eq $script:record) { Write-Output 'No upgrade transaction requires recovery.'; return }
    Paths-ForRecord
    $tOld = Test-DirVersion $script:targetPath $script:record.oldVersion
    $tNew = (Test-DirVersion $script:targetPath $script:record.newVersion) -and (Test-TransactionMarker $script:targetPath 'new')
    $oOld = (Test-DirVersion $script:oldPath $script:record.oldVersion) -and (Test-TransactionMarker $script:oldPath 'old')
    $uNew = (Test-DirVersion $script:upgradedPath $script:record.newVersion) -and (Test-TransactionMarker $script:upgradedPath 'new')
    $blocked = [IO.Directory]::Exists($script:blockedSdk)
    $targetExists = [IO.Directory]::Exists($script:targetPath)
    $oldExists = [IO.Directory]::Exists($script:oldPath)
    $newExists = [IO.Directory]::Exists($script:newPath)
    $upgradedExists = [IO.Directory]::Exists($script:upgradedPath)

    if ($script:record.state -eq 'abandoned') {
        if ($tOld -and -not $oldExists -and -not $blocked -and -not $upgradedExists -and
            [IO.Directory]::Exists((Join-Path $script:targetPath 'sdk'))) {
            Write-Output 'Transaction already settled: original installation is present.'; return
        }
        Fail 'The abandoned transaction no longer matches the actual directories; all files were retained.'
    }
    if ($script:record.state -eq 'rolled-back') {
        if ($tOld -and (Test-TransactionMarker $script:targetPath 'old') -and $uNew -and
            -not $oldExists -and -not $blocked -and [IO.Directory]::Exists((Join-Path $script:targetPath 'sdk')) -and
            [IO.Directory]::Exists((Join-Path $script:upgradedPath 'sdk'))) {
            Write-Output 'Transaction already settled: rollback is present.'; return
        }
        Fail 'The completed rollback no longer matches the actual directories; all files were retained.'
    }
    if ($script:record.state -eq 'rollback-intent') {
        if ($oOld) { Assert-DataBackup }
        if ($tNew -and $oOld -and -not $upgradedExists -and -not $blocked -and
            [IO.Directory]::Exists((Join-Path $script:targetPath 'sdk'))) {
            Assert-NoRunning $script:targetPath
            $rollbackEntries = Get-Tree $script:targetPath
            Lock-TreeFiles $rollbackEntries $script:targetPath
            Assert-NoRunning $script:targetPath
            [IO.Directory]::Move((Join-Path $script:targetPath 'sdk'), $script:blockedSdk)
            $blocked = $true
            Release-Guards
        }
        if ($tNew -and $oOld -and -not $upgradedExists -and $blocked -and
            -not [IO.Directory]::Exists((Join-Path $script:targetPath 'sdk'))) {
            [IO.Directory]::Move($script:targetPath, $script:upgradedPath)
            Test-Crash 'RollbackMoved'
            $targetExists = $false; $uNew = $true
        }
        if (-not $targetExists -and $uNew -and $oOld -and $blocked -and
            -not [IO.Directory]::Exists((Join-Path $script:upgradedPath 'sdk'))) {
            [IO.Directory]::Move($script:blockedSdk, (Join-Path $script:upgradedPath 'sdk'))
            $blocked = $false
        }
        if (-not $targetExists -and $uNew -and $oOld -and -not $blocked -and
            [IO.Directory]::Exists((Join-Path $script:upgradedPath 'sdk'))) {
            [IO.Directory]::Move($script:oldPath, $script:targetPath)
            $tOld = $true; $oldExists = $false
        }
        if ($tOld -and $uNew -and -not $oldExists -and -not $blocked) {
            Set-State 'rolled-back'; Write-Output "Rollback complete; upgraded data retained at $script:upgradedPath"; return
        }
        Fail 'Rollback state is ambiguous. All directories were retained.'
    }
    if ($tNew -and $oOld -and -not $newExists -and -not $blocked -and -not $upgradedExists) {
        Set-State 'applied'; Write-Output "Upgrade is present; previous installation retained at $script:oldPath"; return
    }
    if ($script:record.state -eq 'applied') { Fail 'Applied upgrade state is ambiguous. All directories were retained.' }
    if ($tOld -and -not $oldExists -and -not $blocked -and -not $upgradedExists) {
        Set-State 'abandoned'; Write-Output 'No switch occurred; the original installation was retained.'; return
    }
    if ($tOld -and (Test-TransactionMarker $script:targetPath 'old') -and -not $oldExists -and $blocked -and -not $upgradedExists -and
        -not [IO.Directory]::Exists((Join-Path $script:targetPath 'sdk'))) {
        Assert-NoRunning $script:targetPath
        [IO.Directory]::Move($script:blockedSdk, (Join-Path $script:targetPath 'sdk'))
        Set-State 'abandoned'; Write-Output 'Original SDK restored; staged files retained.'; return
    }
    if (-not $targetExists -and $oOld -and -not $upgradedExists) {
        if ($blocked -and -not [IO.Directory]::Exists((Join-Path $script:oldPath 'sdk'))) {
            [IO.Directory]::Move($script:blockedSdk, (Join-Path $script:oldPath 'sdk'))
            $blocked = $false
        }
        if (-not $blocked -and [IO.Directory]::Exists((Join-Path $script:oldPath 'sdk'))) {
            [IO.Directory]::Move($script:oldPath, $script:targetPath)
            Set-State 'abandoned'; Write-Output 'Original installation restored; staged files retained.'; return
        }
    }
    Fail 'Upgrade state is ambiguous. All directories were retained.'
}

try {
    $script:targetPath = Canonical-LocalPath $Target $false
    $parent = [IO.Directory]::GetParent($script:targetPath).FullName
    if ($parent.TrimEnd('\').Length -gt 2) { [void](Canonical-LocalPath $parent $true) }
    if ($TestCrashAt) {
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $script:targetPath.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -or
            $env:ARTEMIS_UPGRADE_TEST -cne '1') { Fail 'Fault injection is restricted to explicit temp fixtures.' }
    }
    $identity = Get-HashText $script:targetPath.ToLowerInvariant()
    $script:txRoot = Join-Path $parent ('.ArtemisOS-upgrade-' + $identity.Substring(0, 20))
    $script:recordFile = Join-Path $script:txRoot 'transaction.json'
    $script:mutex = New-Object Threading.Mutex ($false, ('Global\ArtemisOS-Upgrade-' + $identity.Substring(0, 24)))
    try { $script:mutexOwned = $script:mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $script:mutexOwned = $true }
    if (-not $script:mutexOwned) { Fail 'Another upgrade for this installation is running.' }
    # Serialize against the updater shipped by 0.3.x in this logon session.
    # The legacy updater formats its hexadecimal hash in uppercase; kernel
    # object names are case-sensitive, so retain its exact spelling.
    $script:legacyMutex = New-Object Threading.Mutex ($false, ('Local\ArtemisOS-Update-' + $identity.Substring(0, 24).ToUpperInvariant()))
    try { $script:legacyMutexOwned = $script:legacyMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $script:legacyMutexOwned = $true }
    if (-not $script:legacyMutexOwned) { Fail 'The existing ArtemisOS OTA updater is running; retry after it finishes.' }
    if ([IO.Directory]::Exists($script:txRoot)) { [void](Canonical-LocalPath $script:txRoot $true) }

    if ($Action -eq 'Recover') { Recover-Transaction; exit 0 }
    if ($Action -eq 'Rollback') {
        $script:record = Read-Record
        if ($null -eq $script:record -or $script:record.state -ne 'applied') { Fail 'There is no applied upgrade to roll back.' }
        Paths-ForRecord
        if (-not (Test-DirVersion $script:targetPath $script:record.newVersion) -or
            -not (Test-TransactionMarker $script:targetPath 'new') -or
            -not (Test-DirVersion $script:oldPath $script:record.oldVersion) -or
            -not (Test-TransactionMarker $script:oldPath 'old') -or [IO.Directory]::Exists($script:upgradedPath)) {
            Fail 'Rollback paths are ambiguous; all directories were retained.'
        }
        Assert-NoRunning $script:targetPath
        Set-State 'rollback-intent'
        Recover-Transaction
        exit 0
    }
    if (-not $Payload) { Fail 'Apply requires a complete extracted payload directory.' }
    [void](Canonical-LocalPath $script:targetPath $true)
    $payloadPath = Canonical-LocalPath $Payload $true
    Assert-Separate $script:targetPath $payloadPath
    Assert-Separate $script:txRoot $payloadPath
    $existing = Read-Record
    if ($null -ne $existing -and $existing.state -notin @('abandoned', 'rolled-back')) {
        Fail 'An existing transaction requires recovery or already contains an applied upgrade.'
    }
    $oldVersion = Get-Version $script:targetPath
    $newVersion = Get-Version $payloadPath
    if ($newVersion.ToString() -cne '1.0.0') { Fail 'This transaction accepts only an ArtemisOS 1.0.0 payload.' }
    if ($oldVersion -ge $newVersion) { Fail 'Same-version installation and downgrade are not allowed.' }
    if ($oldVersion.ToString() -notin @('0.3.4', '0.3.5', '0.3.6')) { Fail 'This installed version has not been qualified for this upgrade.' }
    Assert-Sdk $script:targetPath
    Assert-Sdk $payloadPath
    if (-not [IO.Directory]::Exists((Join-Path $script:targetPath 'data'))) { Fail 'The existing installation has no data directory.' }
    if ([IO.File]::Exists((Join-Path $script:targetPath 'data\update\pending\applying.flag'))) {
        Fail 'The old OTA update has an unfinished transaction; recover it before upgrading.'
    }
    Assert-NoRunning $script:targetPath
    $oldEntries = Get-Tree $script:targetPath
    $payloadEntries = Get-Tree $payloadPath
    $requiredBytes = [int64]0
    foreach ($entry in $oldEntries) {
        $rel = Relative-Path $script:targetPath $entry.FullName
        if (-not (Is-Owned $rel)) {
            # CopyFile preserves content and streams, not relationships between
            # distinct hard links. Refuse rather than silently changing them.
            if (($entry.Attributes -band [IO.FileAttributes]::Directory) -eq 0 -and $entry.LinkType -eq 'HardLink') {
                Fail "User files with hard links require manual migration: $rel"
            }
            $requiredBytes += (Get-LogicalBytes $entry)
        }
    }
    foreach ($entry in $payloadEntries) {
        $rel = Relative-Path $payloadPath $entry.FullName
        if ($rel -match '^(?i:data)(?:\\|$)' -or $rel -match '^(?i:unins\d+\.(?:exe|dat|msg))$') { Fail 'Payload contains user data or an existing uninstaller.' }
        $requiredBytes += (Get-LogicalBytes $entry)
    }
    $disk = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($script:targetPath))
    if ($disk.AvailableFreeSpace -lt ($requiredBytes + [int64]268435456)) { Fail 'Insufficient free space for the verified staged copy and recovery margin.' }
    Lock-TreeFiles $oldEntries $script:targetPath
    Assert-NoRunning $script:targetPath
    [void][IO.Directory]::CreateDirectory($script:txRoot)
    $script:record = [pscustomobject]@{ product = 'ArtemisOS-15'; schema = 1; target = $script:targetPath;
        id = [guid]::NewGuid().ToString('N'); oldVersion = $oldVersion.ToString(); newVersion = '1.0.0'; state = 'preparing' }
    $script:tx = Join-Path $script:txRoot $script:record.id
    [void][IO.Directory]::CreateDirectory($script:tx)
    Write-JsonAtomic $script:recordFile $script:record
    Paths-ForRecord
    [void][IO.Directory]::CreateDirectory($script:newPath)
    # Copy product files first, then preserve every non-owned old file and empty directory.
    foreach ($entry in $payloadEntries) {
        $rel = Relative-Path $payloadPath $entry.FullName
        $dest = Join-Path $script:newPath $rel
        if (($entry.Attributes -band [IO.FileAttributes]::Directory) -ne 0) { [void][IO.Directory]::CreateDirectory($dest); continue }
        if ($rel -ieq 'update\server.txt' -and [IO.File]::Exists((Join-Path $script:targetPath $rel))) { continue }
        Copy-Verified $entry.FullName $dest
    }
    foreach ($entry in $oldEntries) {
        $rel = Relative-Path $script:targetPath $entry.FullName
        if (Is-Owned $rel) { continue }
        $dest = Join-Path $script:newPath $rel
        if (($entry.Attributes -band [IO.FileAttributes]::Directory) -ne 0) { [void][IO.Directory]::CreateDirectory($dest); continue }
        if ([IO.File]::Exists($dest) -or [IO.Directory]::Exists($dest)) { Fail "An unmanaged user item conflicts with the new payload: $rel" }
        Copy-Verified $entry.FullName $dest
    }
    # Detect files or streams introduced after enumeration while old contents were locked.
    $after = Get-Tree $script:targetPath
    $beforeNames = @($oldEntries | ForEach-Object { $_.FullName.ToLowerInvariant() } | Sort-Object)
    $afterNames = @($after | ForEach-Object { $_.FullName.ToLowerInvariant() } | Sort-Object)
    if (($beforeNames -join "`n") -cne ($afterNames -join "`n")) { Fail 'The installation changed during backup; retry after closing other programs.' }
    Assert-Sdk $script:newPath
    Write-TransactionMarker $script:newPath 'new'
    Set-State 'prepared'
    Test-Crash 'Prepared'
    Assert-NoRunning $script:targetPath
    Write-TransactionMarker $script:targetPath 'old'
    Set-State 'sdk-intent'
    # With user files locked, removing the SDK prevents an old launcher starting
    # another emulator during the short directory swap.
    [IO.Directory]::Move((Join-Path $script:targetPath 'sdk'), $script:blockedSdk)
    Test-Crash 'SdkMoved'
    Release-Guards
    if ($TestCrashAt -eq 'MutationAfterUnlock') {
        # Used only in temporary test fixtures to exercise the verification window.
        [IO.File]::AppendAllText((Join-Path $script:targetPath 'data\preferences.ini'), ' changed during swap')
    }
    Set-State 'old-intent'
    [IO.Directory]::Move($script:targetPath, $script:oldPath)
    Test-Crash 'OldMoved'
    [IO.Directory]::Move($script:blockedSdk, (Join-Path $script:oldPath 'sdk'))
    Test-Crash 'SdkRestored'
    # The old SDK was removed while user files were locked, so the previous
    # launcher cannot start. After releasing those locks, verify again from
    # the retained original before making the new tree visible; this also
    # catches direct writes or newly added items during the short move window.
    $oldAfterEntries = Get-Tree $script:oldPath
    $oldMarkerName = '.artemisos-' + $script:record.id + '-old.marker'
    $oldPreserved = @($oldAfterEntries | Where-Object {
        $relative = Relative-Path $script:oldPath $_.FullName
        $relative -cne $oldMarkerName -and -not (Is-Owned $relative)
    })
    $newPreserved = @($oldEntries | Where-Object { -not (Is-Owned (Relative-Path $script:targetPath $_.FullName)) })
    $oldNames = @($oldPreserved | ForEach-Object { (Relative-Path $script:oldPath $_.FullName).ToLowerInvariant() } | Sort-Object)
    $newNames = @($newPreserved | ForEach-Object { (Relative-Path $script:targetPath $_.FullName).ToLowerInvariant() } | Sort-Object)
    if (($oldNames -join "`n") -cne ($newNames -join "`n")) { Fail 'User files changed during the swap; use Recover to restore the original.' }
    $dataEntries = @()
    foreach ($entry in $oldPreserved) {
        $rel = Relative-Path $script:oldPath $entry.FullName
        $isData = $rel.StartsWith('data\', [StringComparison]::OrdinalIgnoreCase)
        if (($entry.Attributes -band [IO.FileAttributes]::Directory) -ne 0) {
            if ($isData) { $dataEntries += [pscustomobject]@{ path = $rel.Substring(5); kind = 'directory' } }
            continue
        }
        $hashes = Assert-Identical $entry.FullName (Join-Path $script:newPath $rel)
        if ($isData) { $dataEntries += [pscustomobject]@{ path = $rel.Substring(5); kind = 'file'; sha256 = $hashes.sha256; streams = @($hashes.streams) } }
    }
    Write-JsonAtomic $script:dataManifestPath ([pscustomobject]@{ schema = 1; product = 'ArtemisOS-15'; id = $script:record.id; entries = @($dataEntries) })
    Set-State 'new-intent'
    [IO.Directory]::Move($script:newPath, $script:targetPath)
    Test-Crash 'NewMoved'
    Set-State 'applied'
    Write-Output "Upgrade installed. Previous installation and data retained at $script:oldPath"
    exit 0
} catch {
    Write-Error -ErrorAction Continue ("ArtemisOS upgrade stopped: " + $_.Exception.Message)
    exit 1
} finally {
    Release-Guards
    if ($script:legacyMutexOwned) { $script:legacyMutex.ReleaseMutex() }
    if ($script:legacyMutex) { $script:legacyMutex.Dispose() }
    if ($script:mutexOwned) { $script:mutex.ReleaseMutex() }
    if ($script:mutex) { $script:mutex.Dispose() }
}
