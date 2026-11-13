<#
.SYNOPSIS
Behavioral regression for the fresh-install NTFS sparse image helper.

.DESCRIPTION
Creates and removes only a uniquely named synthetic fixture directory. The
selected parent must be on NTFS. No Android SDK or existing installation is
read or modified. A Windows PowerShell 5.1 child verifies the installer's exit
code contract and an interrupted zero-range operation.
#>
[CmdletBinding()]
param([string]$TestParent = [IO.Path]::GetTempPath())

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$repo = Split-Path -Parent $PSScriptRoot
$helper = Join-Path $repo 'tools\Optimize-SparseFreshInstall.ps1'
$windowsPowerShell = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
$parent = (Resolve-Path -LiteralPath $TestParent).ProviderPath
if (([IO.DriveInfo]::new([IO.Path]::GetPathRoot($parent))).DriveFormat -cne 'NTFS') {
    throw 'Choose an NTFS test parent with -TestParent.'
}
if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) { throw 'Windows PowerShell 5.1 is required.' }
$fixtureRoot = Join-Path $parent ('ArtemisSparseFixture-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)

try {
    if (-not ('ArtemisTestAllocation' -as [type])) { Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ArtemisTestAllocation {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern uint GetCompressedFileSizeW(string name, out uint high);
    public static ulong Get(string path) {
        uint high;
        uint low=GetCompressedFileSizeW(path, out high);
        int error=Marshal.GetLastWin32Error();
        if (low==uint.MaxValue && error!=0) throw new System.ComponentModel.Win32Exception(error);
        return ((ulong)high << 32) | low;
    }
}
'@
    }
    $source = Join-Path $fixtureRoot 'source.bin'
    $buffer = [byte[]]::new(65536)
    $random = [Random]::new(38001)
    $stream = [IO.File]::Open($source,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        for ($i=0; $i -lt 256; $i++) {
            [Array]::Clear($buffer,0,$buffer.Length)
            if ($i -in @(1,17,80,170,255)) { $random.NextBytes($buffer) }
            $stream.Write($buffer,0,$buffer.Length)
        }
        [Array]::Clear($buffer,0,$buffer.Length)
        $stream.Write($buffer,0,4096)
    } finally { $stream.Dispose() }
    $expected = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedLength = (Get-Item -LiteralPath $source).Length

    function New-Fixture([string]$Name) {
        $install = Join-Path $fixtureRoot $Name
        $image = Join-Path $install 'sdk\system-images\android-35\google_apis\x86_64\system.img'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $image))
        [IO.File]::Copy($source,$image,$false)
        $token = [guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText((Join-Path $install '.artemis-fresh-install'),$token,[Text.Encoding]::ASCII)
        [pscustomobject]@{ Root=$install; Image=$image; Token=$token }
    }
    function Assert-Original([string]$Path) {
        if ((Get-Item -LiteralPath $Path).Length -ne $expectedLength -or
            (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $expected) {
            throw 'Fixture logical bytes or length changed.'
        }
    }
    function Is-Sparse([string]$Path) {
        [bool]((Get-Item -LiteralPath $Path).Attributes -band [IO.FileAttributes]::SparseFile)
    }
    function Start-Child([string]$Arguments,[string]$Name) {
        $process = Start-Process -FilePath $windowsPowerShell -ArgumentList $Arguments -PassThru -Wait -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $fixtureRoot ($Name + '.out')) `
            -RedirectStandardError (Join-Path $fixtureRoot ($Name + '.err'))
        return $process.ExitCode
    }

    $normal = New-Fixture 'normal'
    $allocatedBefore = [ArtemisTestAllocation]::Get($normal.Image)
    $optimized = & $helper -InstallRoot $normal.Root -ExpectedSha256 $expected -FreshInstallToken $normal.Token
    $allocatedAfter = [ArtemisTestAllocation]::Get($normal.Image)
    if ($optimized.Status -cne 'Optimized' -or -not (Is-Sparse $normal.Image) -or $allocatedAfter -ge $allocatedBefore) {
        throw 'The normal fixture did not become smaller on disk.'
    }
    Assert-Original $normal.Image

    $linked = New-Fixture 'hardlink'
    $alias = Join-Path $linked.Root 'other-hard-link.bin'
    New-Item -ItemType HardLink -Path $alias -Target $linked.Image | Out-Null
    $skipped = & $helper -InstallRoot $linked.Root -ExpectedSha256 $expected -FreshInstallToken $linked.Token
    if ($skipped.Status -cne 'Skipped' -or $skipped.Reason -notmatch 'multiple hard links' -or (Is-Sparse $linked.Image)) {
        throw 'Hard-link refusal failed.'
    }
    Assert-Original $linked.Image
    Assert-Original $alias

    $wrong = New-Fixture 'wronghash'
    $badHash = '0' * 64
    $arguments = '-NoProfile -NonInteractive -File "{0}" -InstallRoot "{1}" -ExpectedSha256 {2} -FreshInstallToken {3}' -f $helper,$wrong.Root,$badHash,$wrong.Token
    if ((Start-Child $arguments 'wronghash') -eq 0 -or (Is-Sparse $wrong.Image)) { throw 'Hash mismatch did not fail before modification.' }
    Assert-Original $wrong.Image

    $locked = New-Fixture 'locked'
    $handle = [IO.File]::Open($locked.Image,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { $skipped = & $helper -InstallRoot $locked.Root -ExpectedSha256 $expected -FreshInstallToken $locked.Token }
    finally { $handle.Dispose() }
    if ($skipped.Status -cne 'Skipped' -or (Is-Sparse $locked.Image)) { throw 'Exclusive-open refusal failed.' }
    Assert-Original $locked.Image

    $unmarked = New-Fixture 'unmarked'
    Remove-Item -LiteralPath (Join-Path $unmarked.Root '.artemis-fresh-install')
    $skipped = & $helper -InstallRoot $unmarked.Root -ExpectedSha256 $expected -FreshInstallToken $unmarked.Token
    if ($skipped.Status -cne 'Skipped' -or (Is-Sparse $unmarked.Image)) { throw 'Fresh-marker refusal failed.' }
    Assert-Original $unmarked.Image

    $fallback = New-Fixture 'fallback'
    $outcome = [Artemis.SparseFreshInstall]::Reclaim($fallback.Image,$expected,[Action[int]]{ param($n) throw 'Injected failure.' })
    if ($outcome.Status -cne 'Skipped') { throw 'Recoverable failure did not safely skip.' }
    Assert-Original $fallback.Image

    $interrupted = New-Fixture 'interrupted'
    $child = Join-Path $fixtureRoot 'interrupt.ps1'
    @'
param($Helper,$WarmRoot,$WarmToken,$Expected,$Target)
$ErrorActionPreference = 'Stop'
& $Helper -InstallRoot $WarmRoot -ExpectedSha256 $Expected -FreshInstallToken $WarmToken | Out-Null
[Artemis.SparseFreshInstall]::Reclaim($Target,$Expected,[Action[int]]{ param($n) [Environment]::Exit(91) }) | Out-Null
exit 1
'@ | Set-Content -LiteralPath $child -Encoding ASCII
    $arguments = '-NoProfile -NonInteractive -File "{0}" -Helper "{1}" -WarmRoot "{2}" -WarmToken {3} -Expected {4} -Target "{5}"' -f $child,$helper,$linked.Root,$linked.Token,$expected,$interrupted.Image
    if ((Start-Child $arguments 'interrupt') -ne 91) { throw 'Interrupt did not occur immediately after zero-range reclamation.' }
    Assert-Original $interrupted.Image
    if (-not (Is-Sparse $interrupted.Image)) { throw 'Interrupted image did not become sparse.' }
    $resumed = & $helper -InstallRoot $interrupted.Root -ExpectedSha256 $expected -FreshInstallToken $interrupted.Token
    if ($resumed.Status -cne 'Optimized') { throw 'Interrupted operation could not be retried.' }
    Assert-Original $interrupted.Image

    [pscustomobject]@{
        Status='Passed'; Checks=@('bytes','allocation','hardlink','bad-hash-process-exit','locked','marker','fallback','interrupt','retry')
        LogicalBytes=$expectedLength; AllocatedBefore=$allocatedBefore; AllocatedAfter=$allocatedAfter
    }
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolved = (Resolve-Path -LiteralPath $fixtureRoot).ProviderPath.TrimEnd('\')
        $expectedPath = [IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\')
        if ($resolved -ine $expectedPath -or (Split-Path -Leaf $resolved) -cnotmatch '^ArtemisSparseFixture-[0-9a-f]{32}$' -or
            ((Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Refusing to remove an unexpected fixture directory.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
