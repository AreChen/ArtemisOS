param([string]$Compiler = (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'))
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Compiler -PathType Leaf)) { throw 'Inno Setup compiler not found.' }
$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixture = Join-Path $parent ('artemisos-fixture-' + [Guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $fixture) { throw 'Fixture path unexpectedly exists.' }
[void][IO.Directory]::CreateDirectory($fixture)
function Assert([bool]$Ok, [string]$Message) {
    if (-not $Ok) { throw $Message }
    Write-Host "PASS: $Message"
}
function Write-Fixture([string]$Path, [string]$Contents) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Contents, [Text.Encoding]::ASCII)
}
function Make-Sdk([string]$Root, [string]$Tag, [bool]$Complete) {
    $files = @('emulator\emulator.exe', 'emulator\qemu\windows-x86_64\qemu-system-x86_64.exe',
        'platform-tools\adb.exe', 'system-images\android-35\google_apis\x86_64\system.img',
        'system-images\android-35\google_apis\x86_64\vendor.img',
        'system-images\android-35\google_apis\x86_64\ramdisk.img',
        'system-images\android-35\google_apis\x86_64\kernel-ranchu')
    foreach ($file in $files) {
        if (-not $Complete -and $file -eq 'platform-tools\adb.exe') { continue }
        Write-Fixture (Join-Path $Root $file) ($Tag + ':' + $file)
    }
}
function Make-OldInstall([string]$Root, [bool]$Complete) {
    Make-Sdk (Join-Path $Root 'sdk') 'old-sdk' $Complete
    foreach ($entry in @('launch.ps1','settings.ps1','start-auto.vbs')) { Write-Fixture (Join-Path $Root $entry) 'old script' }
    Write-Fixture (Join-Path $Root 'version.ini') "[ArtemisOS]`r`nVersion=0.3.5`r`n"
    Write-Fixture (Join-Path $Root '.artemis-test-fixture') 'isolated fixture'
    Write-Fixture (Join-Path $Root 'data\preferences.ini') "profile=high`r`nunknown-setting=keep`r`n"
    Write-Fixture (Join-Path $Root 'data\avd\userdata-qemu.img.qcow2') 'fixture user disk'
}
function Run-Setup([string]$Setup, [string]$Directory, [string]$Log) {
    & rtk proxy $Setup /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- ("/DIR=$Directory") ("/LOG=$Log")
    return $LASTEXITCODE
}
try {
    $sdk = Join-Path $fixture 'payload-sdk'
    Make-Sdk $sdk 'new-sdk' $true
    $fixtureId = 'ArtemisInstallerFixture' + [Guid]::NewGuid().ToString('N')
    $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'installer-upgrade.iss'
    & rtk proxy $Compiler ("/O$fixture") '/Fprototype-guarded' ("/DSdkSource=$sdk") ("/DReleaseAppId=$fixtureId") '/DPackageCompression=none' $source
    if ($LASTEXITCODE -ne 0) { throw 'Guarded prototype compilation failed.' }
    $guardedTarget = Join-Path $fixture 'guarded-target'
    Make-OldInstall $guardedTarget $true
    $guardCode = Run-Setup (Join-Path $fixture 'prototype-guarded.exe') $guardedTarget (Join-Path $fixture 'guarded.log')
    Assert ($guardCode -ne 0 -and [IO.File]::ReadAllText((Join-Path $guardedTarget 'version.ini')) -match 'Version=0\.3\.5' -and
        [IO.File]::ReadAllText((Join-Path $guardedTarget 'data\avd\userdata-qemu.img.qcow2')) -eq 'fixture user disk') 'the normal build blocks an existing installation before changing files'
    & rtk proxy $Compiler ("/O$fixture") '/Fprototype-test' ("/DSdkSource=$sdk") ("/DReleaseAppId=$fixtureId") '/DArtemisUpgradeFixture=1' '/DPackageCompression=none' $source
    if ($LASTEXITCODE -ne 0) { throw 'Prototype compilation failed.' }
    $setup = Join-Path $fixture 'prototype-test.exe'
    $fresh = Join-Path $fixture 'fresh'
    $code = Run-Setup $setup $fresh (Join-Path $fixture 'fresh.log')
    Assert ($code -eq 0 -and (Test-Path -LiteralPath (Join-Path $fresh 'unins000.dat')) -and
        [IO.File]::ReadAllText((Join-Path $fresh 'version.ini')) -match 'Version=1\.0\.0') 'fresh fixture installs and writes an uninstall log without registering or creating shortcuts'
    $target = Join-Path $fixture 'target'
    Make-OldInstall $target $true
    $beforePreferences = [IO.File]::ReadAllBytes((Join-Path $target 'data\preferences.ini'))
    $beforeDisk = [IO.File]::ReadAllBytes((Join-Path $target 'data\avd\userdata-qemu.img.qcow2'))
    $code = Run-Setup $setup $target (Join-Path $fixture 'upgrade.log')
    Assert ($code -eq 0) 'upgrade fixture invokes the transaction successfully'
    Assert ([IO.File]::ReadAllText((Join-Path $target 'version.ini')) -match 'Version=1\.0\.0' -and
        [IO.File]::ReadAllText((Join-Path $target 'sdk\emulator\emulator.exe')) -match '^new-sdk:') 'the target receives the complete new payload'
    Assert ([Convert]::ToBase64String($beforePreferences) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $target 'data\preferences.ini'))) -and
        [Convert]::ToBase64String($beforeDisk) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $target 'data\avd\userdata-qemu.img.qcow2')))) 'upgrade preserves fixture preferences and user data byte for byte'
    Assert (-not (Test-Path -LiteralPath (Join-Path $target 'unins000.dat')) -and @(Get-ChildItem -LiteralPath $fixture -Directory -Filter '.ArtemisOS-upgrade-*' -Force).Count -eq 1) 'upgrade creates no competing uninstaller and retains a recovery tree'
    $bad = Join-Path $fixture 'target-bad'
    Make-OldInstall $bad $false
    $code = Run-Setup $setup $bad (Join-Path $fixture 'bad.log')
    Assert ($code -ne 0 -and [IO.File]::ReadAllText((Join-Path $bad 'version.ini')) -match 'Version=0\.3\.5' -and
        [IO.File]::ReadAllText((Join-Path $bad 'data\avd\userdata-qemu.img.qcow2')) -eq 'fixture user disk') 'a failed transaction returns failure and retains the original fixture data'
} finally {
    if (Test-Path -LiteralPath $fixture) {
        $item = Get-Item -LiteralPath $fixture -Force
        if ($item.FullName -ine $fixture -or $item.Parent.FullName.TrimEnd('\') -ine $parent -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe fixture cleanup path.' }
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}
