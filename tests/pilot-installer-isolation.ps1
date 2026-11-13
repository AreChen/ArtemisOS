param(
    [Parameter(Mandatory=$true)][string]$Installer,
    [Parameter(Mandatory=$true)][string]$ExpectedImage,
    [Parameter(Mandatory=$true)][string]$ExpectedServer,
    [int]$Port=5568,
    [string]$ExistingImage,
    [switch]$RequireSparse,
    [switch]$RequireNotSparse,
    [switch]$ExpectHashRejection,
    [switch]$UseTemp,
    [switch]$SkipOnline,
    [switch]$SkipBoot,
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$ExpectedVersion = '0.3.5',
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$ExpectedEmulatorVersion = '',
    [ValidatePattern('^(?:[A-Za-z0-9][A-Za-z0-9._-]{0,79}|\{[0-9A-Fa-f-]{36}\})$')][string]$TestAppId = '{E49344F1-069E-4DA4-A5B7-232C0BE325A8}',
    [string]$TestShortcutName = 'ArtemisOS 15'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$project = Split-Path -Parent $PSScriptRoot
$installerPath = (Resolve-Path -LiteralPath $Installer).Path
$imagePath = (Resolve-Path -LiteralPath $ExpectedImage).Path
$serverPath = (Resolve-Path -LiteralPath $ExpectedServer).Path
$parent = Join-Path $project 'build'
if ($UseTemp) {
    $parent = Join-Path ([IO.Path]::GetTempPath()) 'ArtemisOS-installer-validation'
    [void][IO.Directory]::CreateDirectory($parent)
    $parentItem = Get-Item -LiteralPath $parent -Force
    if (-not $parentItem.PSIsContainer -or ($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The dedicated temporary test parent must be a regular directory.'
    }
}
$root = Join-Path $parent ('pilot-installer-validation-' + [guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $root) { throw 'Refusing to reuse an existing installer test directory.' }
$install = Join-Path $root 'install'
$backup = Join-Path $root 'backup'
$key = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\{E49344F1-069E-4DA4-A5B7-232C0BE325A8}_is1'
$testKey = Join-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' ($TestAppId + '_is1')
$programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$startMenu = Join-Path $programs 'ArtemisOS 15'
$desktop = [Environment]::GetFolderPath('Desktop')
$links = @(
    (Join-Path $startMenu 'ArtemisOS 15.lnk'),
    (Join-Path $startMenu 'ArtemisOS 15（配置）.lnk'),
    (Join-Path $startMenu 'ArtemisOS 15（软件渲染）.lnk'),
    (Join-Path $startMenu '使用说明.lnk'),
    (Join-Path $desktop 'ArtemisOS 15.lnk'),
    (Join-Path $desktop 'ArtemisOS 15（配置）.lnk'),
    (Join-Path $desktop 'ArtemisOS 15（软件渲染）.lnk')
)
$independentId = $TestAppId -ine '{E49344F1-069E-4DA4-A5B7-232C0BE325A8}'
$independentName = $TestShortcutName -ine 'ArtemisOS 15'
if ($independentId -ne $independentName) { throw 'Independent tests require both a different AppId and a different shortcut name.' }
if ([string]::IsNullOrWhiteSpace($TestShortcutName) -or $TestShortcutName -match '[<>:"/\\|?*\x00-\x1f]' -or
    $TestShortcutName -match '[. ]$' -or $TestShortcutName -in @('.', '..')) {
    throw 'Invalid shortcut name.'
}
$testStartMenu = Join-Path $programs $TestShortcutName
$testLinks = @(
    @{Path=(Join-Path $testStartMenu ($TestShortcutName + '.lnk')); Script='start-auto.vbs'},
    @{Path=(Join-Path $testStartMenu ($TestShortcutName + '（配置）.lnk')); Script='configure.vbs'},
    @{Path=(Join-Path $testStartMenu ($TestShortcutName + '（软件渲染）.lnk')); Script='start-software.vbs'},
    @{Path=(Join-Path $testStartMenu '使用说明.lnk'); Script='使用说明.txt'},
    @{Path=(Join-Path $desktop ($TestShortcutName + '.lnk')); Script='start-auto.vbs'},
    @{Path=(Join-Path $desktop ($TestShortcutName + '（配置）.lnk')); Script='configure.vbs'},
    @{Path=(Join-Path $desktop ($TestShortcutName + '（软件渲染）.lnk')); Script='start-software.vbs'}
)
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host "PASS: $Message"
}
function Assert-EmulatorVersion([string]$InstallPath, [string]$Version) {
    $emulatorDirectory = Join-Path $InstallPath 'sdk\emulator'
    $propertiesPath = Join-Path $emulatorDirectory 'source.properties'
    $emulatorPath = Join-Path $emulatorDirectory 'emulator.exe'
    Assert (Test-Path -LiteralPath $propertiesPath -PathType Leaf) 'installed Emulator version metadata exists'
    Assert (Test-Path -LiteralPath $emulatorPath -PathType Leaf) 'installed Emulator executable exists'
    $revisionPattern = '(?m)^Pkg\.Revision=' + [regex]::Escape($Version) + '\r?$'
    Assert ([IO.File]::ReadAllText($propertiesPath) -match $revisionPattern) "installed Emulator metadata reports $Version"
    $savedErrorPreference = $ErrorActionPreference
    try {
        # Emulator writes informational messages to stderr even for -version.
        # Windows PowerShell 5 can otherwise promote them to terminating errors.
        $ErrorActionPreference = 'Continue'
        $emulatorOutput = @(& rtk proxy $emulatorPath -version 2>&1)
        $emulatorExitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedErrorPreference }
    $binaryVersionPattern = '(?m)^Android emulator version ' + [regex]::Escape($Version) + '(?:\.0)?(?:\s|$)'
    Assert ($emulatorExitCode -eq 0 -and (($emulatorOutput -join "`n") -match $binaryVersionPattern)) "installed Emulator executable reports $Version"
}
function Test-OwnedRegistration($Registration, [string]$InstallPath) {
    try {
        $expected = [IO.Path]::GetFullPath($InstallPath).TrimEnd('\')
        $actual = [string]$Registration.'Inno Setup: App Path'
        $location = [string]$Registration.InstallLocation
        if (-not [IO.Path]::IsPathRooted($actual) -or -not [IO.Path]::IsPathRooted($location)) { return $false }
        $uninstaller = '"' + (Join-Path $expected 'unins000.exe') + '"'
        return ([IO.Path]::GetFullPath($actual).TrimEnd('\') -ieq $expected -and
            [IO.Path]::GetFullPath($location).TrimEnd('\') -ieq $expected -and
            [string]$Registration.UninstallString -ieq $uninstaller)
    } catch { return $false }
}
function Test-OwnedShortcut($Shortcut, [string]$InstallPath, [string]$Script) {
    try {
        $expected = [IO.Path]::GetFullPath($InstallPath).TrimEnd('\')
        $target = [string]$Shortcut.TargetPath
        if (-not [IO.Path]::IsPathRooted($target)) { return $false }
        $expectedFile = Join-Path $expected $Script
        if ($Script -eq '使用说明.txt') {
            return ([IO.Path]::GetFullPath($target) -ieq $expectedFile -and [string]$Shortcut.Arguments -eq '')
        }
        $hostPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
        $workingDirectory = [string]$Shortcut.WorkingDirectory
        if (-not [IO.Path]::IsPathRooted($workingDirectory)) { return $false }
        return ([IO.Path]::GetFullPath($target) -ieq [IO.Path]::GetFullPath($hostPath) -and
            [IO.Path]::GetFullPath($workingDirectory).TrimEnd('\') -ieq $expected -and
            [string]$Shortcut.Arguments -ceq ('"' + $expectedFile + '"'))
    } catch { return $false }
}
function Assert-IndependentTargetsAbsent {
    foreach ($parentPath in @($programs, $desktop)) {
        $item = Get-Item -LiteralPath $parentPath -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Unsafe shortcut parent: $parentPath"
        }
    }
    $programsFull = [IO.Path]::GetFullPath($programs).TrimEnd('\')
    $menuFull = [IO.Path]::GetFullPath($testStartMenu).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($menuFull) -ine $programsFull) { throw 'Invalid independent Start menu path.' }
    if (Test-Path -LiteralPath $testKey) { throw 'Independent uninstall registration already exists; refusing to modify it.' }
    if (Test-Path -LiteralPath $testStartMenu) { throw 'Independent Start menu folder already exists; refusing to modify it.' }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $testLinks) {
        $path = [IO.Path]::GetFullPath($entry.Path)
        if (-not $names.Add($path)) { throw 'Independent shortcut names collide.' }
        if (Test-Path -LiteralPath $path) { throw "Independent shortcut already exists: $path" }
    }
}
function Remove-OwnedIndependentTargets {
    $failures = [Collections.Generic.List[string]]::new()
    try {
        if (Test-Path -LiteralPath $testKey) {
            $reg = Get-Item -LiteralPath $testKey -ErrorAction Stop
            $values = Get-ItemProperty -LiteralPath $testKey -ErrorAction Stop
            if ($reg.SubKeyCount -ne 0 -or -not (Test-OwnedRegistration $values $install)) {
                throw 'Independent uninstall registration does not belong to this test installation.'
            }
            Remove-Item -LiteralPath $testKey -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $testKey) { throw 'Independent uninstall registration remains after cleanup.' }
        }
    } catch { $failures.Add($_.Exception.Message) }
    $menuSafe = $true
    try {
        if (Test-Path -LiteralPath $testStartMenu) {
            $menu = Get-Item -LiteralPath $testStartMenu -Force -ErrorAction Stop
            if (-not $menu.PSIsContainer -or ($menu.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Independent Start menu folder is not a normal directory.'
            }
        }
    } catch { $menuSafe = $false; $failures.Add($_.Exception.Message) }
    $shell = $null
    foreach ($entry in $testLinks) {
        try {
            if (-not $menuSafe -and [IO.Path]::GetDirectoryName($entry.Path) -ieq $testStartMenu) { continue }
            if (-not (Test-Path -LiteralPath $entry.Path)) { continue }
            $item = Get-Item -LiteralPath $entry.Path -Force -ErrorAction Stop
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Independent shortcut is not a normal file: $($entry.Path)"
            }
            if (-not $shell) { $shell = New-Object -ComObject WScript.Shell }
            $shortcut = $shell.CreateShortcut($entry.Path)
            if (-not (Test-OwnedShortcut $shortcut $install $entry.Script)) {
                throw "Independent shortcut does not belong to this test installation: $($entry.Path)"
            }
            Remove-Item -LiteralPath $entry.Path -Force -ErrorAction Stop
        } catch { $failures.Add($_.Exception.Message) }
    }
    try {
        if ($menuSafe -and (Test-Path -LiteralPath $testStartMenu)) {
            if (@(Get-ChildItem -LiteralPath $testStartMenu -Force -ErrorAction Stop).Count -ne 0) {
                throw 'Independent Start menu folder contains unrecognized items; it was retained.'
            }
            Remove-Item -LiteralPath $testStartMenu -Force -ErrorAction Stop
        }
    } catch { $failures.Add($_.Exception.Message) }
    if ($failures.Count) { throw ($failures -join '; ') }
}
if ($Port -lt 5554 -or $Port -gt 5584 -or $Port % 2 -ne 0) { throw 'Invalid test port.' }
if ($independentId) { Assert-IndependentTargetsAbsent }
foreach ($link in $links) {
    if (-not (Test-Path -LiteralPath $link -PathType Leaf)) {
        throw 'Expected existing shortcuts are missing; refusing to run a test that could create untracked shortcuts.'
    }
}
[void][IO.Directory]::CreateDirectory($backup)
$linkHashes = @()
for ($i=0; $i -lt $links.Count; $i++) {
    $linkHashes += (Get-FileHash -LiteralPath $links[$i] -Algorithm SHA256).Hash
    [IO.File]::Copy($links[$i], (Join-Path $backup ("shortcut-$i.lnk")))
}
$before = Join-Path $backup 'uninstall-before.reg'
$after = Join-Path $backup 'uninstall-after.reg'
& rtk proxy reg.exe export $key $before /y | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not back up the existing uninstall registration.' }
function Assert-OriginalStateUnchanged {
    $changed = [Collections.Generic.List[string]]::new()
    $savedErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & rtk proxy reg.exe export $key $after /y 2>&1 | Out-Null
        $exportExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedErrorPreference }
    $registrationUnchanged = $exportExit -eq 0 -and (Get-FileHash -LiteralPath $before).Hash -eq (Get-FileHash -LiteralPath $after).Hash
    if (-not $registrationUnchanged) {
        $changed.Add('existing uninstall registration changed')
        try {
            $ErrorActionPreference = 'Continue'
            & rtk proxy reg.exe import $before 2>&1 | Out-Null
            $restoreExit = $LASTEXITCODE
        } finally { $ErrorActionPreference = $savedErrorPreference }
        if ($restoreExit -ne 0) { $changed.Add("could not restore registration; backup: $before") }
    }
    for ($i=0; $i -lt $links.Count; $i++) {
        $unchanged = $false
        try {
            if (Test-Path -LiteralPath $links[$i] -PathType Leaf) {
                $item = Get-Item -LiteralPath $links[$i] -Force -ErrorAction Stop
                if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    $unchanged = (Get-FileHash -LiteralPath $links[$i]).Hash -eq $linkHashes[$i]
                }
            }
            if (-not $unchanged) {
                $changed.Add("existing shortcut $i changed")
                if ((Test-Path -LiteralPath $links[$i]) -and
                    ((Get-Item -LiteralPath $links[$i] -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    throw 'Refusing to overwrite a reparse point.'
                }
                [IO.File]::Copy((Join-Path $backup ("shortcut-$i.lnk")), $links[$i], $true)
            }
        } catch { $changed.Add("could not verify or restore existing shortcut ${i}: $($_.Exception.Message)") }
    }
    if ($changed.Count) { throw (($changed -join '; ') + "; backups: $backup") }
}
function Complete-IndependentSetup([bool]$RequireRegistration) {
    $failures = [Collections.Generic.List[string]]::new()
    if ($RequireRegistration -and -not (Test-Path -LiteralPath $testKey)) {
        $failures.Add('successful setup did not create the expected independent uninstall registration')
    }
    try { Remove-OwnedIndependentTargets } catch { $failures.Add($_.Exception.Message) }
    try { Assert-OriginalStateUnchanged } catch { $failures.Add($_.Exception.Message) }
    if ($failures.Count) { throw ($failures -join '; ') }
}
$setupExit = $null
function Invoke-IsolatedSetup([string[]]$SetupArguments) {
    $wrappedArguments = @('proxy', ('"' + $installerPath + '"')) + $SetupArguments
    $process = Start-Process -FilePath (Get-Command rtk.exe).Source -ArgumentList $wrappedArguments -WindowStyle Hidden -PassThru -Wait
    return $process.ExitCode
}
if ($ExistingImage) {
    $existingImagePath = Join-Path $install 'sdk\system-images\android-35\google_apis\x86_64\system.img'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $existingImagePath))
    [IO.File]::Copy((Resolve-Path -LiteralPath $ExistingImage).Path, $existingImagePath)
}
try {
    $args = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-','/NOICONS','/TASKS=""',
        ('/DIR="' + $install + '"'),('/LOG="' + (Join-Path $root 'setup.log') + '"'))
    $setupExit = Invoke-IsolatedSetup $args
} finally {
    if ($independentId) {
        Complete-IndependentSetup ($setupExit -eq 0)
    } else {
        & rtk proxy reg.exe import $before | Out-Null
        $restoreExit = $LASTEXITCODE
        for ($i=0; $i -lt $links.Count; $i++) { [IO.File]::Copy((Join-Path $backup ("shortcut-$i.lnk")), $links[$i], $true) }
        if ($restoreExit -ne 0) { throw "Could not restore uninstall registration; backup: $before" }
    }
}
& rtk proxy reg.exe export $key $after /y | Out-Null
Assert ($LASTEXITCODE -eq 0 -and (Get-FileHash $before).Hash -eq (Get-FileHash $after).Hash) 'existing uninstall registration restored byte-for-byte'
for ($i=0; $i -lt $links.Count; $i++) {
    Assert ((Get-FileHash -LiteralPath $links[$i]).Hash -eq $linkHashes[$i]) "existing shortcut $i restored"
}
if ($ExpectHashRejection) {
    Assert ($setupExit -ne 0) 'unexpected image hash stops the installer'
    Assert (Test-Path -LiteralPath (Join-Path $install '.artemis-fresh-install')) 'failed installation retains its incomplete-install marker'
    if ($independentId) {
        Assert-IndependentTargetsAbsent
        $retryExit = $null
        try { $retryExit = Invoke-IsolatedSetup $args }
        finally { Complete-IndependentSetup ($retryExit -eq 0) }
    } else {
        $retryExit = Invoke-IsolatedSetup $args
    }
    Assert ($retryExit -ne 0) 'retry refuses the incomplete installation directory'
    & rtk proxy reg.exe export $key $after /y | Out-Null
    Assert ($LASTEXITCODE -eq 0 -and (Get-FileHash $before).Hash -eq (Get-FileHash $after).Hash) 'failed retry leaves existing uninstall registration intact'
    Write-Host "Isolated installer validation files retained under $root"
    return
}
Assert ($setupExit -eq 0) 'actual installer completed in independent directory'
Assert ((Get-FileHash (Join-Path $install 'sdk\system-images\android-35\google_apis\x86_64\system.img')).Hash -eq
    (Get-FileHash $imagePath).Hash) 'installed system image matches the validated candidate'
Assert ((Get-FileHash (Join-Path $install 'update\server.txt')).Hash -eq (Get-FileHash $serverPath).Hash) 'new installation has the intended OpenList channel'
$versionPattern = '(?m)^Version=' + [regex]::Escape($ExpectedVersion) + '\r?$'
Assert ([IO.File]::ReadAllText((Join-Path $install 'version.ini')) -match $versionPattern) "new installation reports $ExpectedVersion"
if ($ExpectedEmulatorVersion) { Assert-EmulatorVersion $install $ExpectedEmulatorVersion }
Assert (Test-Path -LiteralPath (Join-Path $install 'sdk\system-images\android-35\google_apis\x86_64\data\empty_data_disk')) 'empty-data marker is present for first boot'
Assert (-not (Test-Path -LiteralPath (Join-Path $install '.artemis-fresh-install'))) 'fresh-install marker does not persist'
if ($RequireSparse) {
    $installedImage = Join-Path $install 'sdk\system-images\android-35\google_apis\x86_64\system.img'
    $attributes = (Get-Item -LiteralPath $installedImage).Attributes
    Assert (($attributes -band [IO.FileAttributes]::SparseFile) -ne 0) 'fresh installation reclaimed zero ranges as a sparse file'
    if (-not ('ArtemisPilotAllocation' -as [type])) { Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ArtemisPilotAllocation {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern uint GetCompressedFileSizeW(string name, out uint high);
    public static ulong Get(string path) {
        uint high;
        uint low=GetCompressedFileSizeW(path, out high);
        int error=Marshal.GetLastWin32Error();
        if (low==uint.MaxValue && error!=0) throw new System.ComponentModel.Win32Exception(error);
        return ((ulong)high << 32) | low;
    }
}
'@ }
    $allocated = [ArtemisPilotAllocation]::Get($installedImage)
    $logical = (Get-Item -LiteralPath $installedImage).Length
    Assert ($allocated -lt [UInt64]$logical) 'sparse image occupies less disk than its logical length'
    Write-Host "Installed image: logical=$logical allocated=$allocated saved=$($logical-[Int64]$allocated) bytes"
}
if ($RequireNotSparse) {
    $attributes = (Get-Item -LiteralPath (Join-Path $install 'sdk\system-images\android-35\google_apis\x86_64\system.img')).Attributes
    Assert (($attributes -band [IO.FileAttributes]::SparseFile) -eq 0) 'existing installation image is not sparse-converted'
}
if (-not $SkipOnline) {
    . (Join-Path $install 'update\core.ps1')
    Assert ($null -eq (Get-UpdateOffer $install)) 'new installation reads signed current-version marker from OpenList'
}
if ($SkipBoot) { Write-Host "Isolated installer validation files retained under $root"; return }

$adb = Join-Path $install 'sdk\platform-tools\adb.exe'
$launch = Join-Path $install 'launch.ps1'
$sdk = Join-Path $install 'sdk\emulator\'
try {
    # The launcher detaches the emulator. With redirected output, rtk can
    # remain alive while a descendant holds a pipe; waiting for that wrapper
    # would deadlock this test until the emulator is shut down.
    $launchArguments = @('proxy', 'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $launch + '"'), '-Headless', '-Port', [string]$Port)
    $launchProcess = Start-Process -FilePath (Get-Command rtk.exe).Source -ArgumentList $launchArguments -WindowStyle Hidden -PassThru
    # Cold initialization can be slow on a busy host; this is a readiness
    # deadline, not a performance claim.
    $deadline = [DateTime]::UtcNow.AddMinutes(10)
    $booted = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        $launchProcess.Refresh()
        if ($launchProcess.HasExited -and $launchProcess.ExitCode -ne 0) { throw 'Installed launcher failed.' }
        # The device is absent until the new emulator registers with ADB.
        # Windows PowerShell 5 treats that expected stderr as an error when
        # ErrorActionPreference is Stop, even when it is redirected.
        $savedErrorPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $state = & rtk proxy $adb -s "emulator-$Port" shell getprop sys.boot_completed 2>$null
        } finally {
            $ErrorActionPreference = $savedErrorPreference
        }
        if (($state | Out-String).Trim() -eq '1') { $booted = $true; break }
        Start-Sleep -Seconds 2
    }
    Assert $booted 'new installation cold-boots in its own data directory'
    # boot_completed can precede the framework restart caused by the first
    # locale change. Check the product initializer, not just the boot property.
    $initDeadline = [DateTime]::UtcNow.AddMinutes(15)
    $initialized = $false
    $stateFile = Join-Path $install 'data\setup-state.ini'
    $initLog = Join-Path $install 'data\logs\initialize.log'
    while ([DateTime]::UtcNow -lt $initDeadline) {
        try {
            $state = if (Test-Path -LiteralPath $stateFile) { [IO.File]::ReadAllText($stateFile) } else { '' }
            if ($state -match '(?m)^locale=1\r?$' -and $state -match '(?m)^network=1\r?$') { $initialized = $true; break }
            if ((Test-Path -LiteralPath $initLog) -and [IO.File]::ReadAllText($initLog) -match '初始化未完成') { break }
        } catch [IO.IOException] { }
        Start-Sleep -Seconds 3
    }
    Assert $initialized 'fresh installation completes locale and network initialization'
    $locale = (& rtk proxy $adb -s "emulator-$Port" shell getprop persist.sys.locale | Out-String).Trim()
    $timezone = (& rtk proxy $adb -s "emulator-$Port" shell getprop persist.sys.timezone | Out-String).Trim()
    Assert ($locale -match '^zh(?:-|_)(?:Hans(?:-|_))?CN$' -and $timezone -eq 'Asia/Shanghai') 'fresh installation uses Simplified Chinese and UTC+8'
} finally {
    $own = @(Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe' OR Name='qemu-system-x86_64-headless.exe'" |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($sdk, [StringComparison]::OrdinalIgnoreCase) -and
            $_.CommandLine -match ("-port\s+" + $Port + "(\s|$)") })
    if ($own.Count -eq 1) { & rtk proxy $adb -s "emulator-$Port" emu kill | Out-Null }
}
Write-Host "Isolated installer validation files retained under $root"
