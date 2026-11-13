param(
    [Parameter(Mandatory = $true)][string]$InstallRoot,
    [ValidateRange(5554, 5584)][int]$Port = 5580,
    [ValidateRange(30, 600)][int]$TimeoutSeconds = 240
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$project = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$allowed = [IO.Path]::GetFullPath((Join-Path $project 'build')).TrimEnd('\') + '\'
$InstallRoot = (Resolve-Path -LiteralPath $InstallRoot).ProviderPath.TrimEnd('\')
if (-not $InstallRoot.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -or $Port % 2) {
    throw 'Only an isolated build installation and an even emulator port are allowed.'
}
. (Join-Path $InstallRoot 'update\core.ps1')
Assert-UpdatePathSafe $InstallRoot
if ((Get-UpdateVersion $InstallRoot) -cne '1.0.4') { throw 'The fixture has not completed its 1.0.4 OTA.' }
$sdk = Join-Path $InstallRoot 'sdk'
$sdkPrefix = [IO.Path]::GetFullPath($sdk).TrimEnd('\') + '\'
$adb = Join-Path $sdk 'platform-tools\adb.exe'
$serial = "emulator-$Port"
$preferences = Join-Path $InstallRoot 'data\preferences.ini'
$preferenceHash = (Get-FileHash -LiteralPath $preferences -Algorithm SHA256).Hash
$oldEnvironment = @{}
$emulatorHome = Join-Path $InstallRoot 'data\emulator-home'
[void][IO.Directory]::CreateDirectory($emulatorHome)
$started = $false
$result = $null
try {
    foreach ($name in @('ANDROID_USER_HOME', 'ANDROID_EMULATOR_HOME')) {
        $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $emulatorHome, 'Process')
    }
    $started = $true
    # Wait on the launcher itself; a CLI proxy can retain inherited pipes after
    # PowerShell has exited while the emulator's descendants are still alive.
    $launchArguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
        ('"' + (Join-Path $InstallRoot 'update\launch-current.ps1') + '"'), '-Graphics', 'swiftshader', '-Headless', '-Port', [string]$Port)
    $launchProcess = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $launchArguments -WindowStyle Hidden -PassThru
    if (-not $launchProcess.WaitForExit(30000)) { throw 'The upgraded shortcut entry did not return after startup.' }
    if ($launchProcess.ExitCode -ne 0) { throw 'The upgraded shortcut entry failed to start.' }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $boot = ''
    while ([DateTime]::UtcNow -lt $deadline) {
        try { $boot = (& rtk proxy $adb -s $serial shell getprop sys.boot_completed 2>$null | Out-String).Trim() }
        catch { $boot = '' }
        if ($LASTEXITCODE -eq 0 -and $boot -eq '1') { break }
        Start-Sleep -Seconds 3
    }
    if ($boot -ne '1') { throw 'The upgraded Android instance did not finish booting.' }
    $surface = (& rtk proxy $adb -s $serial shell dumpsys SurfaceFlinger 2>$null | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'Could not obtain Android renderer evidence.' }
    $gles = @($surface -split '\r?\n' | Where-Object { $_ -match '^GLES:' }) -join "`n"
    if ($gles -notmatch 'ANGLE' -or $gles -notmatch 'Vulkan' -or $gles -notmatch 'SwiftShader Device \(Subzero\)') {
        throw "Unexpected software renderer: $gles"
    }
    $runtimeProcesses = @(Get-CimInstance Win32_Process -Filter "Name = 'qemu-system-x86_64.exe' OR Name = 'qemu-system-x86_64-headless.exe'" | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath.StartsWith($sdkPrefix, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($runtimeProcesses.Count -ne 1 -or $runtimeProcesses[0].CommandLine -notmatch ('-port\s+' + $Port + '(?:\s|$)')) {
        throw 'Could not uniquely identify the upgraded test runtime.'
    }
    $modules = @((Get-Process -Id $runtimeProcesses[0].ProcessId -ErrorAction Stop).Modules | Where-Object {
        $_.FileName.StartsWith($sdkPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        $_.ModuleName -match '^(libEGL|libGLESv2|libGLES_CM|vk_swiftshader|vulkan-1)\.dll$'
    } | ForEach-Object { $_.FileName.Substring($sdkPrefix.Length).Replace('\', '/') })
    if (@($modules | Where-Object { $_ -match 'libGLES_CM\.dll$' }).Count) {
        throw 'The obsolete GLES1 provider was unexpectedly loaded.'
    }
    if ((Get-FileHash -LiteralPath $preferences -Algorithm SHA256).Hash -cne $preferenceHash) {
        throw 'The one-time software shortcut changed saved user rendering preferences.'
    }
    $result = [ordered]@{
        schemaVersion = 1
        timeUtc = [DateTime]::UtcNow.ToString('o')
        installRoot = $InstallRoot
        serial = $serial
        bootCompleted = $boot
        gles = $gles
        loadedRuntimeModules = $modules
        leftoverOldGles1File = Test-Path -LiteralPath (Join-Path $sdk 'emulator\lib64\gles_swiftshader\libGLES_CM.dll')
        obsoleteGles1Loaded = $false
        preferencesUnchanged = $true
    }
} finally {
    foreach ($name in $oldEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $oldEnvironment[$name], 'Process')
    }
    if ($started) {
        $owned = @(Get-CimInstance Win32_Process -Filter "Name = 'qemu-system-x86_64.exe' OR Name = 'qemu-system-x86_64-headless.exe'" | Where-Object {
            $_.ExecutablePath -and $_.ExecutablePath.StartsWith($sdkPrefix, [StringComparison]::OrdinalIgnoreCase) -and
            $_.CommandLine -match ('-port\s+' + $Port + '(?:\s|$)')
        })
        if ($owned.Count -eq 1) { & rtk proxy $adb -s $serial emu kill | Out-Null }
    }
}
if ($null -ne $result) {
    $resultPath = Join-Path $InstallRoot 'modern-vulkan-ota-boot.json'
    [IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    Write-Host "PASS: actual old-to-new SDK OTA boots through the upgraded shortcut with ANGLE/Vulkan/SwiftShader. Evidence: $resultPath"
}
