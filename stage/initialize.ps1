param(
    [Parameter(Mandatory = $true)][string]$Serial,
    [int]$EmulatorPid = 0,
    # First boot can take longer on busy or low-end disks, and changing the
    # locale may restart the framework after boot_completed is first set.
    [int]$WaitSeconds = 900,
    [switch]$Headless,
    [ValidateSet('', 'auto', 'host', 'vulkan', 'vulkan_intel', 'vulkan_amd', 'software', 'swiftshader', 'swangle', 'lavapipe')]
    [string]$GraphicsRenderer = '',
    [string]$GraphicsDevice = '',
    [string]$SessionId = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'settings.ps1')
if ($SessionId) { . (Join-Path $PSScriptRoot 'update\frontend-handoff.ps1') }
$adb = Join-Path $PSScriptRoot 'sdk\platform-tools\adb.exe'
$logDirectory = Join-Path $script:ArtemisDataRoot 'logs'
[void][IO.Directory]::CreateDirectory($logDirectory)
$logFile = Join-Path $logDirectory 'initialize.log'

function Write-InitializeLog([string]$Message) {
    Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message" -Encoding UTF8
}

function Invoke-Device([string[]]$DeviceArguments) {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $result = & $adb -s $Serial @DeviceArguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    $output = ($result | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0) { throw "设备命令失败 ($code)：$($DeviceArguments -join ' ') $output" }
    return $output.Trim()
}

function Test-EmulatorRunning {
    if ($SessionId) {
        return (Test-ArtemisFrontendBackendIdentity (Get-ArtemisFrontendProcessSnapshot $EmulatorPid) $PSScriptRoot $EmulatorPid ([string]$session.emulatorStartTimeUtcTicks))
    }
    return ($EmulatorPid -le 0 -or $null -ne (Get-Process -Id $EmulatorPid -ErrorAction SilentlyContinue))
}

function Set-VersionedWindowTitle {
    if ($Headless -or $SessionId -or $EmulatorPid -le 0) { return $true }
    $port = $Serial -replace '^emulator-', ''
    if ($port -notmatch '^\d+$') { return $true }
    $title = 'ArtemisOS 15 v' + (Get-ArtemisVersion)
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $EmulatorPid AND Name = 'qemu-system-x86_64.exe'" -ErrorAction SilentlyContinue)
    $processIds = @($EmulatorPid) + @($children | ForEach-Object { $_.ProcessId })
    foreach ($id in $processIds) {
        $windowProcess = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($null -eq $windowProcess -or $windowProcess.MainWindowHandle -eq [IntPtr]::Zero) { continue }
        $originalTitle = $windowProcess.MainWindowTitle
        if ($originalTitle -eq $title) { return $true }
        if ($originalTitle -notmatch ('^Android Emulator - (ArtemisOS_15|InternalAndroid15):' + $port + '$')) { continue }
        if (-not ('ArtemisOS.WindowTitle' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ArtemisOS {
    public static class WindowTitle {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool SetWindowText(IntPtr window, string title);
    }
}
'@
        }
        if (-not [ArtemisOS.WindowTitle]::SetWindowText($windowProcess.MainWindowHandle, $title)) {
            throw '无法设置模拟器窗口标题。'
        }
        Write-InitializeLog "窗口标题已更新：$title。"
        return $true
    }
    return $false
}

function Disable-UnusedSerialConsole {
    if ((Invoke-Device @('shell', 'getprop', 'ro.boot.qemu')) -ne '1' -or
        (Invoke-Device @('shell', 'getprop', 'ro.debuggable')) -ne '1') { return $true }
    $state = Invoke-Device @('shell', 'getprop', 'init.svc.console')
    if ($state -eq 'running') {
        [void](Invoke-Device @('shell', 'su', '0', 'stop', 'console'))
        $state = Invoke-Device @('shell', 'getprop', 'init.svc.console')
        if ($state -eq 'stopped') { Write-InitializeLog '已停止未使用的 Android 串行控制台。' }
    }
    return ($state -eq 'stopped')
}

function Clear-SerialConsoleWarning {
    # Transaction 8 and notification 55 are specific to the exact Android image shipped here.
    $fingerprint = Invoke-Device @('shell', 'getprop', 'ro.build.fingerprint')
    if ($fingerprint -ne 'google/sdk_gphone64_x86_64/emu64xa:15/AE3A.240806.043/12960925:userdebug/dev-keys' -or
        (Invoke-Device @('shell', 'getprop', 'init.svc.console')) -ne 'stopped') { return }
    $result = Invoke-Device @('shell', 'su', '1000', 'service', 'call', 'notification', '8', 's16', 'android', 's16', 'android', 'i32', '-1', 'i32', '55', 'i32', '-1')
    if ($result -match '(?i)exception|error') { throw "无法清除旧的串行控制台通知：$result" }
}

function Wait-AndroidReady {
    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    $consoleHandled = $false
    $consoleErrorLogged = $false
    $titleHandled = ($Headless -or $SessionId -or $EmulatorPid -le 0)
    $titleErrorLogged = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Test-EmulatorRunning)) { return $false }
        try {
            $boot = Invoke-Device @('shell', 'getprop', 'sys.boot_completed')
            if (-not $titleHandled) {
                try { $titleHandled = Set-VersionedWindowTitle } catch {
                    if (-not $titleErrorLogged) {
                        Write-InitializeLog "设置窗口标题失败，将重试：$($_.Exception.Message)"
                        $titleErrorLogged = $true
                    }
                }
            }
            if (-not $consoleHandled) {
                try { $consoleHandled = Disable-UnusedSerialConsole } catch {
                    if (-not $consoleErrorLogged) {
                        Write-InitializeLog "停止串行控制台失败，将重试：$($_.Exception.Message)"
                        $consoleErrorLogged = $true
                    }
                }
            }
            if ($boot -eq '1') {
                $timeSetting = Invoke-Device @('shell', 'settings', 'get', 'global', 'auto_time_zone')
                $packages = Invoke-Device @('shell', 'pm', 'list', 'packages', 'com.android.settings')
                $state = Read-ArtemisKeyValues $script:ArtemisStatePath
                $localeReady = ($state['locale'] -eq '1')
                if (-not $localeReady) {
                    $locale = Invoke-Device @('shell', 'getprop', 'persist.sys.locale')
                    $localeReady = ($locale -match '^zh(?:-|_)(?:Hans(?:-|_))?CN$')
                }
                if ($timeSetting -in @('0', '1', 'null') -and $packages -match 'package:com\.android\.settings' -and $localeReady) {
                    if ($consoleHandled) {
                        try { Clear-SerialConsoleWarning } catch { Write-InitializeLog $_.Exception.Message }
                    }
                    return $true
                }
            }
        } catch { }
        Start-Sleep -Seconds 3
    }
    if (-not (Test-EmulatorRunning)) { return $false }
    throw '等待 Android 初始化超时。'
}

function Initialize-Locale {
    $locale = Invoke-Device @('shell', 'getprop', 'persist.sys.locale')
    if ($locale -notmatch '^zh(?:-|_)(?:Hans(?:-|_))?CN$') { throw "系统语言尚未切换为简体中文：$locale" }
    [void](Invoke-Device @('shell', 'settings', 'put', 'global', 'auto_time_zone', '0'))
    [void](Invoke-Device @('shell', 'cmd', 'alarm', 'set-timezone', 'Asia/Shanghai'))
    $timezone = Invoke-Device @('shell', 'getprop', 'persist.sys.timezone')
    if ($timezone -ne 'Asia/Shanghai') { throw "设置时区失败：$timezone" }
    Set-ArtemisState 'locale' '1'
    Write-InitializeLog '简体中文与 UTC+8 已设置。'
}

function Initialize-Network {
    $checks = @(
        @{ Key = 'captive_portal_http_url'; Value = 'http://connectivitycheck.platform.hicloud.com/generate_204'; Google = 'http://connectivitycheck.gstatic.com/generate_204' },
        @{ Key = 'captive_portal_https_url'; Value = 'https://connectivitycheck.platform.hicloud.com/generate_204'; Google = 'https://www.google.com/generate_204' },
        @{ Key = 'captive_portal_fallback_url'; Value = 'http://connect.rom.miui.com/generate_204'; Google = 'http://www.google.com/gen_204' }
    )
    foreach ($check in $checks) {
        $current = Invoke-Device @('shell', 'settings', 'get', 'global', $check.Key)
        if ($current -notin @('', 'null', $check.Value, $check.Google)) {
            Write-InitializeLog "保留用户已有的网络检测地址：$($check.Key)。"
            Set-ArtemisState 'network' 'custom'
            return
        }
    }
    foreach ($check in $checks) {
        [void](Invoke-Device @('shell', 'settings', 'put', 'global', $check.Key, $check.Value))
        if ((Invoke-Device @('shell', 'settings', 'get', 'global', $check.Key)) -ne $check.Value) { throw "无法保存网络检测地址：$($check.Key)" }
    }
    [void](Invoke-Device @('shell', 'settings', 'put', 'global', 'captive_portal_use_https', '1'))

    $airplane = Invoke-Device @('shell', 'settings', 'get', 'global', 'airplane_mode_on')
    $wifiBefore = Invoke-Device @('shell', 'settings', 'get', 'global', 'wifi_on')
    if ($airplane -eq '0' -and $wifiBefore -eq '1') {
        $wifiDisabled = $false
        try {
            # Reconnect Wi-Fi to apply the new validation URLs without enabling airplane mode.
            [void](Invoke-Device @('shell', 'cmd', 'wifi', 'set-wifi-enabled', 'disabled'))
            $wifiDisabled = $true
            Start-Sleep -Seconds 3
        } finally {
            if ($wifiDisabled) { [void](Invoke-Device @('shell', 'cmd', 'wifi', 'set-wifi-enabled', 'enabled')) }
        }
        # Wi-Fi comes back asynchronously; allow it to become ready.
        $wifiEnabled = '0'
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            $wifiEnabled = Invoke-Device @('shell', 'settings', 'get', 'global', 'wifi_on')
            if ($wifiEnabled -eq '1') { break }
            Start-Sleep -Seconds 2
        }
        if ($wifiEnabled -eq '1') {
            $networks = Invoke-Device @('shell', 'cmd', 'wifi', 'list-networks')
            if ($networks -match '^No networks') {
                [void](Invoke-Device @('shell', 'cmd', 'wifi', 'connect-network', 'AndroidWifi', 'open'))
                Write-InitializeLog '已请求连接模拟器内置的 AndroidWifi。'
            }
        }
    }
    Set-ArtemisState 'network' '1'
    Write-InitializeLog '网络检测地址已更新，HTTPS 验证保持启用。'
}

function Ensure-DefaultWifi {
    $airplane = Invoke-Device @('shell', 'settings', 'get', 'global', 'airplane_mode_on')
    $wifiEnabled = Invoke-Device @('shell', 'settings', 'get', 'global', 'wifi_on')
    if ($airplane -ne '0' -or $wifiEnabled -ne '1') { return }
    $status = Invoke-Device @('shell', 'cmd', 'wifi', 'status')
    if ($status -notmatch 'Wifi is not connected') { return }
    $networks = Invoke-Device @('shell', 'cmd', 'wifi', 'list-networks')
    if ($networks -notmatch '(?m)^No networks\s*$') { return }
    [void](Invoke-Device @('shell', 'cmd', 'wifi', 'connect-network', 'AndroidWifi', 'open'))
    Write-InitializeLog '未发现已保存的无线网络，已请求连接模拟器内置的 AndroidWifi。'
}

function Initialize-SimCarrier([string]$Carrier) {
    $expected = switch ($Carrier) {
        'mobile' { '46000' }
        'telecom' { '46003' }
        'unicom' { '46001' }
        default { throw '无效的模拟运营商。' }
    }
    if ((Invoke-Device @('shell', 'getprop', 'gsm.sim.state')) -ne 'LOADED' -or
        (Invoke-Device @('shell', 'getprop', 'gsm.sim.operator.numeric')) -ne $expected) {
        throw '模拟 SIM 尚未就绪。'
    }
    # LTE is a radio setting; the emulator's separate network shaper remains unlimited.
    $result = Invoke-Device @('shell', 'cmd', 'phone', 'set-allowed-network-types-for-users', '-s', '0', '01000001000000000000')
    if ($result -notmatch 'completed') { throw '无法设置模拟 LTE 网络。' }
    Set-ArtemisState 'carrier' $Carrier
    Write-InitializeLog "模拟运营商已设置：$Carrier，LTE。"
}

function Write-ManagedApps([string[]]$Apps) {
    [IO.File]::WriteAllLines($script:ArtemisManagedAppsPath, [string[]]$Apps, [Text.Encoding]::ASCII)
}

function Initialize-OptionalApps([string]$Cleanup) {
    $optionalApps = @(
        'com.google.android.apps.docs',
        'com.google.android.gm',
        'com.google.android.apps.maps',
        'com.google.android.youtube',
        'com.google.android.apps.youtube.music',
        'com.google.android.apps.photos'
    )
    $managed = @()
    if (Test-Path -LiteralPath $script:ArtemisManagedAppsPath -PathType Leaf) {
        $managed = @([IO.File]::ReadAllLines($script:ArtemisManagedAppsPath) | Where-Object { $_ -in $optionalApps })
    }
    $installed = @((Invoke-Device @('shell', 'pm', 'list', 'packages')) -split "`r?`n" | ForEach-Object { $_ -replace '^package:', '' })
    $disabled = @((Invoke-Device @('shell', 'pm', 'list', 'packages', '-d')) -split "`r?`n" | ForEach-Object { $_ -replace '^package:', '' })

    if ($Cleanup -eq '1') {
        foreach ($app in $optionalApps) {
            if ($app -notin $installed -or $app -in $disabled) { continue }
            $response = Invoke-Device @('shell', 'pm', 'disable-user', '--user', '0', $app)
            if ($response -notmatch 'disabled-user') { throw "停用 $app 失败：$response" }
            $managed = @($managed + $app | Select-Object -Unique)
            Write-ManagedApps $managed
        }
    } else {
        foreach ($app in @($managed)) {
            if ($app -in $installed -and $app -in $disabled) {
                $response = Invoke-Device @('shell', 'pm', 'enable', '--user', '0', $app)
                if ($response -notmatch 'enabled') { throw "恢复 $app 失败：$response" }
            }
            $managed = @($managed | Where-Object { $_ -ne $app })
            Write-ManagedApps $managed
        }
    }
    Set-ArtemisState 'cleanup' $Cleanup
    Write-InitializeLog "预装应用设置已应用：cleanup=$Cleanup。"
}

function Invoke-InitializationStep([scriptblock]$Step) {
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            & $Step
            return
        } catch {
            if ($attempt -eq 5 -or -not (Test-EmulatorRunning)) { throw }
            Start-Sleep -Seconds 3
        }
    }
}

$actualRenderer = ''
try {
    if ($SessionId) {
        $session = Read-ArtemisFrontendSession $PSScriptRoot $SessionId
        if ($session.serial -cne $Serial -or [int]$session.emulatorPid -ne $EmulatorPid) { throw 'The initializer does not own this frontend session.' }
        if (-not (Test-EmulatorRunning)) { throw 'The backend executable path or creation time no longer matches this session.' }
    }
    if (-not (Wait-AndroidReady)) {
        Write-InitializeLog '模拟器已关闭，初始化将在下次启动时继续。'
        if ($SessionId) { throw '模拟器已退出，无法完成初始化。' }
        return
    }
    if ($GraphicsRenderer -in @('vulkan', 'vulkan_intel', 'vulkan_amd')) {
        try {
            if ($GraphicsRenderer -in @('vulkan_intel', 'vulkan_amd') -and -not $GraphicsDevice) { throw '指定显卡 Vulkan 缺少已选显卡名称，请从 ArtemisOS 启动器重新启动。' }
            $surfaceReport = Invoke-Device @('shell', 'dumpsys', 'SurfaceFlinger')
            $actualRenderer = (@($surfaceReport -split "`r?`n" | Where-Object { $_ -match '^\s*GLES:' }) | Select-Object -First 1)
            $gles = Assert-ArtemisHardwareVulkanRenderer $surfaceReport $GraphicsDevice
            $actualRenderer = $gles
            Write-InitializeLog "硬件 Vulkan 渲染已确认：$gles"
        } catch {
            $hardwareError = $_.Exception.Message
            Write-InitializeLog "硬件 Vulkan 启动失败：$hardwareError"
            try {
                $owner = Get-CimInstance Win32_Process -Filter "ProcessId = $EmulatorPid" -ErrorAction Stop
                $owned = Test-ArtemisEmulatorOwnership $owner $PSScriptRoot $EmulatorPid $Serial
                if ($SessionId -and $owned) { $owned = Test-EmulatorRunning }
                if ($owned) {
                    [void](Invoke-Device @('emu', 'kill'))
                    Write-InitializeLog '已停止未能启用硬件 Vulkan 的本次模拟器实例。'
                } else { Write-InitializeLog '无法确认启动进程归属，未停止任何实例。' }
            } catch { Write-InitializeLog ("停止本次实例失败：" + $_.Exception.Message) }
            if ($SessionId) {
                try { Set-ArtemisFrontendSessionState -InstallRoot $PSScriptRoot -SessionId $SessionId -Serial $Serial -EmulatorPid $EmulatorPid -State failed -Error $hardwareError -ActualRenderer $actualRenderer }
                catch { Write-InitializeLog ('无法记录前端启动失败：' + $_.Exception.Message) }
            }
            if ($Headless) { [Console]::Error.WriteLine($hardwareError) }
            else {
                Add-Type -AssemblyName System.Windows.Forms
                [void][Windows.Forms.MessageBox]::Show($hardwareError, 'ArtemisOS 15 - 硬件 Vulkan 启动失败', 'OK', 'Warning')
            }
            exit 1
        }
    }
    $state = Read-ArtemisKeyValues $script:ArtemisStatePath
    if ($state['locale'] -ne '1') { Invoke-InitializationStep { Initialize-Locale } }
    if ($state['network'] -notin @('1', 'custom')) { Invoke-InitializationStep { Initialize-Network } }
    try { Ensure-DefaultWifi } catch { Write-InitializeLog "恢复默认 Wi-Fi 失败：$($_.Exception.Message)" }
    $preferences = Get-ArtemisPreferences
    if ($state['carrier'] -ne $preferences.Carrier) {
        try { Invoke-InitializationStep { Initialize-SimCarrier $preferences.Carrier } } catch {
            Write-InitializeLog "设置模拟运营商失败，将在下次启动时重试：$($_.Exception.Message)"
        }
    }
    if ($state['cleanup'] -ne $preferences.Cleanup) { Invoke-InitializationStep { Initialize-OptionalApps $preferences.Cleanup } }
    if ($SessionId -and $state['launcher_rotation'] -ne '1') {
        $launcherLayout = Join-Path $PSScriptRoot 'update\launcher-layout.ps1'
        if (Test-Path -LiteralPath $launcherLayout -PathType Leaf) {
            try { . $launcherLayout; Initialize-ArtemisLauncherRotation }
            catch { Write-InitializeLog ('桌面旋转初始化已跳过，下次启动重试：' + $_.Exception.Message) }
        }
    }
    if ($SessionId) {
        if (-not $actualRenderer) {
            $surfaceReport = Invoke-Device @('shell', 'dumpsys', 'SurfaceFlinger')
            $actualRenderer = (@($surfaceReport -split "`r?`n" | Where-Object { $_ -match '^\s*GLES:' }) | Select-Object -First 1)
        }
        Set-ArtemisFrontendSessionState -InstallRoot $PSScriptRoot -SessionId $SessionId -Serial $Serial -EmulatorPid $EmulatorPid -State ready -ActualRenderer $actualRenderer
    }
    Write-InitializeLog '初始化检查完成。'
} catch {
    $initializationError = $_.Exception.Message
    Write-InitializeLog "初始化未完成：$initializationError"
    if ($SessionId) {
        try { Set-ArtemisFrontendSessionState -InstallRoot $PSScriptRoot -SessionId $SessionId -Serial $Serial -EmulatorPid $EmulatorPid -State failed -Error $initializationError -ActualRenderer $actualRenderer }
        catch { Write-InitializeLog ('无法记录前端初始化失败：' + $_.Exception.Message) }
        [Console]::Error.WriteLine($initializationError)
        exit 1
    }
    if (-not $Headless -and (Test-EmulatorRunning)) {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show(("ArtemisOS 15 初始化未完成：`r`n" + $_.Exception.Message + "`r`n详情请查看安装目录 data\logs\initialize.log。"), 'ArtemisOS 15', 'OK', 'Warning')
    }
}
