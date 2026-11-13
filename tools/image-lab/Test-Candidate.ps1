param(
    [Parameter(Mandatory=$true)][string]$CandidateImage,
    [Parameter(Mandatory=$true)][string]$BaseImageDir,
    [Parameter(Mandatory=$true)][string]$RuntimeSdk,
    [Parameter(Mandatory=$true)][string]$ArmApk,
    [Parameter(Mandatory=$true)][string]$X86Apk,
    [Parameter(Mandatory=$true)][string]$WebApk,
    [Parameter(Mandatory=$true)][string]$Output,
    [ValidateRange(5554,5680)][int]$Port = 5578,
    [ValidatePattern('^[A-Za-z0-9_-]{1,40}$')][string]$AvdName = 'ArtemisExtraSlimLab',
    [ValidateSet('present','absent')][string]$ExpectedRemovals = 'absent',
    [switch]$AppTestProfile,
    [string]$ResultArchive = ''
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$buildRoot = [IO.Path]::GetFullPath((Join-Path $project 'build')).TrimEnd('\')
$tempRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'ArtemisOS-image-lab')).TrimEnd('\')
$destination = [IO.Path]::GetFullPath($Output).TrimEnd('\')
$inBuild = $destination.StartsWith($buildRoot + '\', [StringComparison]::OrdinalIgnoreCase)
$inTemp = $destination.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase)
if ((-not $inBuild -and -not $inTemp) -or (Test-Path -LiteralPath $destination)) {
    throw 'Output must be a new directory under build/ or the dedicated ArtemisOS-image-lab temporary root.'
}
if ($inTemp) {
    $relative = $destination.Substring($tempRoot.Length + 1)
    if ($relative.Contains('\')) { throw 'A temporary test output must be a direct child of the dedicated temporary root.' }
    if (-not (Test-Path -LiteralPath $tempRoot)) { New-Item -ItemType Directory -Path $tempRoot | Out-Null }
    $tempItem = Get-Item -LiteralPath $tempRoot -Force
    if (-not $tempItem.PSIsContainer -or ($tempItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The dedicated temporary root must be a normal directory, not a reparse point.'
    }
}
$archivePath = ''
if ($ResultArchive) {
    $archivePath = [IO.Path]::GetFullPath($ResultArchive).TrimEnd('\')
    if (-not $archivePath.StartsWith($buildRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $archivePath)) {
        throw 'ResultArchive must be a new directory under build/.'
    }
}
if ($Port % 2 -ne 0) { throw 'The emulator console port must be even.' }
foreach ($path in @($CandidateImage, $BaseImageDir, $RuntimeSdk, $ArmApk, $X86Apk, $WebApk)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing input: $path" }
}
# The emulator launcher changes its working directory to the runtime's
# emulator folder, so its executable path must not remain relative.
$RuntimeSdk = (Resolve-Path -LiteralPath $RuntimeSdk).ProviderPath.TrimEnd('\')
$avdName = $AvdName
if (@(Get-CimInstance Win32_Process -Filter "Name = 'emulator.exe'" | Where-Object { $_.CommandLine -match "(?i)-avd\s+$avdName(\s|$)" }).Count) {
    throw 'An AVD with this test name is already running.'
}
$listeners = @()
try {
    foreach ($testPort in @($Port, ($Port + 1))) {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $testPort)
        $listener.Start()
        $listeners += $listener
    }
} finally { foreach ($listener in $listeners) { $listener.Stop() } }
$adb = Join-Path $RuntimeSdk 'platform-tools\adb.exe'
$emulator = Join-Path $RuntimeSdk 'emulator\emulator.exe'
$runner = (Get-Command rtk -CommandType Application).Source
$serial = "emulator-$Port"
$existingDevices = @(& rtk proxy $adb devices | Where-Object { $_ -match "^$serial\s" })
if ($existingDevices.Count) { throw "The test ADB target $serial is already in use." }

$sysdir = Join-Path $destination 'sysdir'
$avdHome = Join-Path $destination 'avd'
$avdPath = Join-Path $avdHome ($avdName + '.avd')
New-Item -ItemType Directory -Path $sysdir,$avdPath | Out-Null
foreach ($item in Get-ChildItem -LiteralPath $BaseImageDir -Force) {
    if ($item.Name -eq 'system.img') { continue }
    if ($item.PSIsContainer) { Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $sysdir $item.Name) -Recurse }
    else { [IO.File]::Copy($item.FullName, (Join-Path $sysdir $item.Name), $false) }
}
Write-Output 'Copying candidate system image into the isolated test directory.'
[IO.File]::Copy((Resolve-Path -LiteralPath $CandidateImage).ProviderPath, (Join-Path $sysdir 'system.img'), $false)
$ini = "avd.ini.encoding=UTF-8`npath=$avdPath`ntarget=android-35`n"
[IO.File]::WriteAllText((Join-Path $avdHome ($avdName + '.ini')), $ini, [Text.UTF8Encoding]::new($false))
$config = @'
AvdId=__AVD_ID__
PlayStore.enabled=false
abi.type=x86_64
avd.ini.displayname=Artemis Extra Slim Lab
avd.ini.encoding=UTF-8
disk.dataPartition.size=4G
fastboot.forceColdBoot=yes
hw.audioInput=no
hw.cpu.arch=x86_64
hw.cpu.ncore=2
hw.gpu.enabled=yes
hw.gpu.mode=swiftshader
hw.lcd.density=320
hw.lcd.height=1600
hw.lcd.width=720
hw.ramSize=2560
hw.sdCard=no
image.sysdir.1=system-images\android-35\google_apis\x86_64\
runtime.network.latency=none
runtime.network.speed=full
showDeviceFrame=no
skin.dynamic=yes
skin.name=720x1600
tag.id=google_apis
target=android-35
vm.heapSize=256
'@
$config = $config.Replace('__AVD_ID__', $avdName)
[IO.File]::WriteAllText((Join-Path $avdPath 'config.ini'), $config, [Text.UTF8Encoding]::new($false))
$env:ANDROID_HOME = $RuntimeSdk
$env:ANDROID_SDK_ROOT = $RuntimeSdk
$env:ANDROID_AVD_HOME = $avdHome
$results = [ordered]@{ port=$Port; candidate=(Resolve-Path -LiteralPath $CandidateImage).ProviderPath; expected_removals=$ExpectedRemovals; app_test_profile=[bool]$AppTestProfile; checks=[ordered]@{} }
$started = $false
$iteration = 0
function Invoke-TestAdb([string[]]$Arguments, [int]$MaxAttempts = 10) {
    for ($attempt = 0; $attempt -lt $MaxAttempts; $attempt++) {
        # A framework restart can temporarily take this test device offline.
        # Retrying only transport failures avoids hiding real ADB command errors.
        $savedErrorPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $result = @(& rtk proxy $adb -s $serial @Arguments 2>&1)
            $exitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $savedErrorPreference }
        if ($exitCode -eq 0) { return $result }
        $detail = $result -join ' '
        if ($detail -notmatch '(?i)device offline|device[^\r\n]*not found|no devices|connection reset|error:\s*closed' -or $attempt -eq ($MaxAttempts - 1)) {
            throw "ADB $($Arguments -join ' ') failed: $detail"
        }
        Start-Sleep -Seconds 2
    }
}
function Invoke-TestAdbRetry([string[]]$Arguments) {
    for ($attempt=0; $attempt -lt 12; $attempt++) {
        try {
            $reply = @(Invoke-TestAdb $Arguments)
            if (($Arguments -join ' ') -eq 'shell pm list packages -s') { $results.checks.package_list_attempts = $attempt + 1 }
            return $reply
        }
        catch { if ($attempt -eq 11) { throw }; Start-Sleep -Seconds 5 }
    }
}
function Wait-PackageManager([string]$Phase) {
    $stable = 0
    for ($attempt=0; $attempt -lt 60; $attempt++) {
        try {
            $paths = @(Invoke-TestAdb @('shell','pm','path','android')) -join "`n"
            if ($paths -match '(?m)^package:') { $stable++ } else { $stable = 0 }
        } catch { $stable = 0 }
        if ($stable -ge 3) { $results.checks["${Phase}_package_manager_ready_attempts"] = $attempt + 1; return }
        Start-Sleep -Seconds 5
    }
    throw 'Android package manager did not remain ready across three probes.'
}
function Get-SystemServerStartCount {
    $value = (@(Invoke-TestAdb @('shell','getprop','sys.system_server.start_count')) | Out-String).Trim()
    if ($value -notmatch '^\d+$') { throw 'system_server start count is unavailable' }
    return [int]$value
}
function Wait-ActivityManager([string]$Phase) {
    $stable = 0
    $lastCount = -1
    for ($attempt=0; $attempt -lt 60; $attempt++) {
        try {
            $count = Get-SystemServerStartCount
            if ($count -ne $lastCount) { $stable = 0; $lastCount = $count }
            $settings = @(Invoke-TestAdb @('shell','am','start','-W','-a','android.settings.SETTINGS')) -join "`n"
            if ($settings -match '(?i)Status:\s*ok') { $stable++ } else { $stable = 0 }
        } catch { $stable = 0 }
        if ($stable -ge 3) {
            $results.checks["${Phase}_activity_ready_attempts"] = $attempt + 1
            $results.checks["${Phase}_system_server_start_count_when_ready"] = $lastCount
            $results.checks["${Phase}_activity_stable"] = $true
            return
        }
        Start-Sleep -Seconds 5
    }
    throw 'Settings activity did not remain ready across three probes.'
}
function Save-TestCrashEvidence([string]$Phase) {
    @(Invoke-TestAdb @('logcat','-d','-b','crash','-v','threadtime')) |
        Set-Content -Encoding utf8 (Join-Path $destination "test-crash-$Phase-buffer.txt")
    @(Invoke-TestAdb @('logcat','-d','-b','crash','-b','system','-b','main','-t','15000','-v','threadtime') |
        Select-String -Pattern 'FATAL EXCEPTION|system_server.*(died|crash|killed)|OutOfMemory|lowmemorykiller|\blmkd\b|watchdog|ANR in|Fatal signal' -CaseSensitive:$false |
        ForEach-Object { $_.Line }) | Set-Content -Encoding utf8 (Join-Path $destination "test-crash-$Phase-filter.txt")
}
function Assert-OwnedTarget {
    $reply = @(Invoke-TestAdb -Arguments @('emu','avd','name') -MaxAttempts 1) | ForEach-Object { $_.Trim() }
    if ($reply -notcontains $avdName) { throw "ADB target $serial is not the isolated $avdName instance." }
}
function Start-TestInstance {
    $script:iteration++
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $argsList = @('proxy',$emulator,'-avd',$avdName,'-sysdir',$sysdir,'-gpu','swiftshader','-accel','on',
        '-no-window','-no-audio','-no-boot-anim','-no-snapshot','-port',[string]$Port,'-timezone','Asia/Shanghai','-change-locale','zh-CN')
    $script:launcher = Start-Process -FilePath $runner -ArgumentList $argsList -WorkingDirectory (Split-Path -Parent $emulator) -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $destination "boot-$iteration.stdout.log") `
        -RedirectStandardError (Join-Path $destination "boot-$iteration.stderr.log")
    $script:started = $true
    Write-Output "Waiting for isolated cold boot $iteration."
    for ($i=0; $i -lt 360; $i++) {
        Start-Sleep -Seconds 2
        if ($script:launcher.HasExited) {
            $running = @(Get-CimInstance Win32_Process -Filter "Name = 'emulator.exe'" |
                Where-Object { $_.CommandLine -match "(?i)-avd\s+$avdName(\s|$)" })
            if (-not $running.Count) { throw "Emulator launcher exited with status $($script:launcher.ExitCode); see boot-$iteration logs." }
        }
        $owned = $false
        try { Assert-OwnedTarget; $owned = $true } catch { }
        if (-not $owned) { continue }
        # The device can briefly be offline after it first appears. Windows
        # PowerShell 5 promotes native stderr to a terminating error under
        # Stop, even when the stream is redirected; offline is only a retry.
        $savedErrorPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $boot = @(& rtk proxy $adb -s $serial shell getprop sys.boot_completed 2>$null | ForEach-Object { $_.Trim() })
            $bootExitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $savedErrorPreference }
        if ($bootExitCode -eq 0 -and $boot -contains '1') { $results.checks["cold_boot_${iteration}_host_elapsed_ms"] = $watch.ElapsedMilliseconds; return }
    }
    throw "The isolated emulator did not complete cold boot $iteration."
}
function Stop-TestInstance {
    if (-not $script:started) { return }
    try {
        Assert-OwnedTarget
        Invoke-TestAdb @('emu','kill') | Out-Null
    } catch {
        # Only terminate a process whose command line names this new AVD.
        Get-CimInstance Win32_Process -Filter "Name = 'emulator.exe'" |
            Where-Object { $_.CommandLine -match "(?i)-avd\s+$avdName(\s|$)" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
    }
    for ($i=0; $i -lt 30; $i++) {
        $alive = @(Get-CimInstance Win32_Process -Filter "Name = 'emulator.exe'" | Where-Object { $_.CommandLine -match "(?i)-avd\s+$avdName(\s|$)" })
        if (-not $alive.Count) { break }
        Start-Sleep -Seconds 1
    }
    $script:started = $false
}
function Get-ElfMachine([string]$apk, [string]$entryName) {
    $archive = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $apk).ProviderPath)
    try {
        $entry = $archive.GetEntry($entryName)
        if (-not $entry) { throw "APK lacks $entryName" }
        $stream = $entry.Open()
        try {
            $header = [byte[]]::new(20)
            if ($stream.Read($header, 0, 20) -ne 20 -or $header[0] -ne 0x7f -or $header[1] -ne 0x45 -or $header[2] -ne 0x4c -or $header[3] -ne 0x46) { throw 'Invalid ELF header.' }
            return [BitConverter]::ToUInt16($header, 18)
        } finally { $stream.Dispose() }
    } finally { $archive.Dispose() }
}
function Install-TestApk([string]$apk) {
    for ($attempt=0; $attempt -lt 5; $attempt++) {
        try { Invoke-TestAdb @('install','-r','--no-streaming',$apk) | Out-Null; return }
        catch { if ($attempt -eq 4) { throw }; Start-Sleep -Seconds 5 }
    }
}
function Run-NativeProbe([string]$apk, [string]$kind, [int]$expectedMachine, [string]$entry) {
    if ((Get-ElfMachine $apk $entry) -ne $expectedMachine) { throw "$kind APK ELF architecture mismatch" }
    Install-TestApk $apk
    $token = [guid]::NewGuid().ToString('N')
    Invoke-TestAdb @('shell','am','start','-W','-n','internal.artemis.abilab/.MainActivity','--es','run_token',$token) | Out-Null
    $found = $false
    for ($i=0; $i -lt 15; $i++) {
        $logs = @(Invoke-TestAdb @('logcat','-d','-s','ArtemisAbiProbe:I','*:S'))
        if ($logs -match "ARM64_JNI_OK:37042:$token") { $found = $true; break }
        Start-Sleep -Seconds 1
    }
    Invoke-TestAdb @('uninstall','internal.artemis.abilab') | Out-Null
    return $found
}
try {
    Start-TestInstance
    $results.checks.cold_boot = $true
    $results.checks.system_server_start_count_at_boot = Get-SystemServerStartCount
    Wait-PackageManager 'first'
    Wait-ActivityManager 'first'
    if ($results.checks.system_server_start_count_at_boot -gt 1 -or $results.checks.first_system_server_start_count_when_ready -gt 1) {
        Save-TestCrashEvidence 'first'
    }
    # sys.boot_completed may precede completion of locale application and first-
    # boot package-manager initialization, especially on a busy host.
    for ($i=0; $i -lt 30; $i++) {
        $initialLocale = (@(Invoke-TestAdb @('shell','getprop','persist.sys.locale')) | Out-String).Trim()
        if ($initialLocale -like 'zh*') { break }
        Start-Sleep -Seconds 2
    }
    $results.checks.sdk = (@(Invoke-TestAdb @('shell','getprop','ro.build.version.sdk')) | Out-String).Trim()
    $results.checks.locale = (@(Invoke-TestAdb @('shell','getprop','persist.sys.locale')) | Out-String).Trim()
    $results.checks.timezone = (@(Invoke-TestAdb @('shell','getprop','persist.sys.timezone')) | Out-String).Trim()
    $packages = @(Invoke-TestAdbRetry @('shell','pm','list','packages','-s') | ForEach-Object { $_.Trim() })
    foreach ($package in @('com.google.android.gms','com.google.android.webview','com.android.phone','com.android.settings','com.android.systemui','com.google.android.inputmethod.latin','com.google.android.apps.messaging')) {
        $results.checks["package:$package"] = ($packages -contains "package:$package")
    }
    foreach ($package in @('com.google.android.googlequicksearchbox','com.google.android.as','com.google.android.as.oss','com.google.android.apps.wellbeing','com.google.android.projection.gearhead','com.google.android.markup')) {
        $results.checks["removed:$package"] = -not ($packages -contains "package:$package")
    }
    foreach ($package in @('com.google.android.apps.safetyhub','com.google.android.apps.restore')) {
        $results.checks["removed:$package"] = -not ($packages -contains "package:$package")
    }
    $settings = @(Invoke-TestAdb @('shell','am','start','-W','-a','android.settings.SETTINGS')) -join "`n"
    $results.checks.settings_activity = $settings -match '(?i)Status:\s*ok'
    $results.checks.arm64_jni = Run-NativeProbe $ArmApk 'arm64' 183 'lib/arm64-v8a/libarmprobe.so'
    $results.checks.x86_64_jni = Run-NativeProbe $X86Apk 'x86_64' 62 'lib/x86_64/libarmprobe.so'
    Install-TestApk $WebApk
    $webToken = [guid]::NewGuid().ToString('N')
    Invoke-TestAdb @('shell','am','start','-W','-n','internal.artemis.webviewprobe/.MainActivity','--es','run_token',$webToken) | Out-Null
    $webLogs = @()
    for ($i=0; $i -lt 30; $i++) {
        $webLogs = @(Invoke-TestAdb @('logcat','-d','-s','ArtemisWebProbe:I','*:S'))
        if (($webLogs -match "WEBVIEW_OK:$webToken") -and ($webLogs -match "GMS_BIND_OK:$webToken")) { break }
        Start-Sleep -Seconds 1
    }
    $results.checks.webview_local_html_js = [bool]($webLogs -match "WEBVIEW_OK:$webToken")
    $results.checks.gms_common_service_bind = [bool]($webLogs -match "GMS_BIND_OK:$webToken")
    $results.checks.gms_probe_detail = @($webLogs | Where-Object { $_ -match "GMS_BIND_(REJECTED|FAILURE):$webToken" }) -join ' '
    & rtk proxy $adb -s $serial shell toybox nc -z -w 5 www.baidu.com 443 2>$null | Out-Null
    $results.checks.dns_and_tcp_443 = ($LASTEXITCODE -eq 0)
    $results.checks.system_server_start_count_before_restart = Get-SystemServerStartCount
    if ($results.checks.system_server_start_count_before_restart -gt 1) { Save-TestCrashEvidence 'first' }
    Stop-TestInstance
    Start-TestInstance
    $results.checks.second_cold_boot = $true
    $results.checks.system_server_start_count_second_boot = Get-SystemServerStartCount
    Wait-PackageManager 'second'
    Wait-ActivityManager 'second'
    if ($results.checks.second_system_server_start_count_when_ready -gt 1) { Save-TestCrashEvidence 'second' }
    $results.checks.second_locale = (@(Invoke-TestAdb @('shell','getprop','persist.sys.locale')) | Out-String).Trim()
    $results.checks.second_timezone = (@(Invoke-TestAdb @('shell','getprop','persist.sys.timezone')) | Out-String).Trim()
} catch {
    $results.error = $_.Exception.Message
    # Only the new test AVD is queried. Do not collect logs from other devices.
    try {
        $devices = @(& rtk proxy $adb devices)
        if ($devices -match "^$serial\s+device\s*$") {
            Assert-OwnedTarget
            Save-TestCrashEvidence 'failure'
        }
    } catch { $results.log_collection_error = $_.Exception.Message }
} finally {
    Stop-TestInstance
    $failures = [Collections.Generic.List[string]]::new()
    if ($results.error) { $failures.Add('test execution: ' + $results.error) }
    $requiredTrue = @('cold_boot','package:com.google.android.gms','package:com.google.android.webview',
        'package:com.android.phone','package:com.android.settings','package:com.android.systemui',
        'package:com.google.android.inputmethod.latin','package:com.google.android.apps.messaging',
        'settings_activity','arm64_jni','x86_64_jni','webview_local_html_js',
        'gms_common_service_bind','dns_and_tcp_443','second_cold_boot','first_activity_stable','second_activity_stable')
    foreach ($name in $requiredTrue) {
        if ($results.checks[$name] -ne $true) { $failures.Add($name) }
    }
    foreach ($name in @('removed:com.google.android.googlequicksearchbox','removed:com.google.android.as',
        'removed:com.google.android.as.oss','removed:com.google.android.apps.wellbeing',
        'removed:com.google.android.projection.gearhead','removed:com.google.android.markup')) {
        $expected = ($ExpectedRemovals -eq 'absent')
        if ($results.checks[$name] -ne $expected) { $failures.Add($name) }
    }
    if ($AppTestProfile) {
        foreach ($name in @('removed:com.google.android.apps.safetyhub','removed:com.google.android.apps.restore')) {
            if ($results.checks[$name] -ne $true) { $failures.Add($name) }
        }
    }
    if ($results.checks.sdk -ne '35') { $failures.Add('sdk') }
    foreach ($name in @('locale','second_locale')) {
        if ($results.checks[$name] -notlike 'zh*') { $failures.Add($name) }
    }
    foreach ($name in @('timezone','second_timezone')) {
        if ($results.checks[$name] -ne 'Asia/Shanghai') { $failures.Add($name) }
    }
    $results.required_failures = $failures.ToArray()
    $results.accepted = ($failures.Count -eq 0)
    $results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $destination 'test-results.json') -Encoding utf8
    if ($archivePath) {
        New-Item -ItemType Directory -Path $archivePath | Out-Null
        Get-ChildItem -LiteralPath $destination -File | Where-Object { $_.Name -match '^(test-results\.json|boot-\d+\.(stdout|stderr)\.log|test-crash-(first|second|failure)-(buffer|filter)\.txt)$' } |
            ForEach-Object { [IO.File]::Copy($_.FullName, (Join-Path $archivePath $_.Name), $false) }
    }
    $results | ConvertTo-Json -Depth 5
}
if (-not $results.accepted) { exit 1 }
