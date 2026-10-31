param(
    [ValidateSet('auto', 'swiftshader')]
    [string]$Graphics = 'auto',
    [switch]$Headless,
    [int]$Port = 0
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

function Show-Problem([string]$Message) {
    if ($Headless) {
        [Console]::Error.WriteLine($Message)
        return
    }
    [void][System.Windows.Forms.MessageBox]::Show(
        $Message, 'ArtemisOS 15',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
}

function Test-PortPair([int]$Number) {
    $listeners = @()
    try {
        foreach ($candidate in @($Number, ($Number + 1))) {
            $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $candidate)
            $listener.ExclusiveAddressUse = $true
            $listener.Start()
            $listeners += $listener
        }
        return $true
    } catch {
        return $false
    } finally {
        foreach ($listener in $listeners) { $listener.Stop() }
    }
}

function Set-ConfigValue([string[]]$Lines, [string]$Key, [string]$Value) {
    $matched = $false
    $updated = foreach ($line in $Lines) {
        if ($line -match ('^' + [Regex]::Escape($Key) + '=')) {
            if (-not $matched) { "$Key=$Value"; $matched = $true }
        } else { $line }
    }
    if (-not $matched) { $updated += "$Key=$Value" }
    return [string[]]$updated
}

try {
    $installRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    . (Join-Path $installRoot 'settings.ps1')
    $sdkRoot = Join-Path $installRoot 'sdk'
    $emulator = Join-Path $sdkRoot 'emulator\emulator.exe'
    $systemImage = Join-Path $sdkRoot 'system-images\android-35\google_apis\x86_64\system.img'
    $avdRoot = Join-Path $installRoot 'data\avd'
    $avdName = 'ArtemisOS_15'
    $avdPath = Join-Path $avdRoot ($avdName + '.avd')
    $legacyAvdPath = Join-Path $avdRoot 'InternalAndroid15.avd'
    $logRoot = Join-Path $installRoot 'data\logs'

    if ($installRoot -match '[^\x00-\x7F]') {
        throw '模拟器的安装路径不能包含中文或其他非英文字符。请重新安装到只包含英文字母、数字和空格的路径。'
    }
    if (-not (Test-Path -LiteralPath $emulator -PathType Leaf) -or
        -not (Test-Path -LiteralPath $systemImage -PathType Leaf)) {
        throw '模拟器文件不完整，请重新运行安装程序。'
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw '此版本需要 64 位 Windows。'
    }
    if ($Port -ne 0 -and ($Port -lt 5554 -or $Port -gt 5584 -or $Port % 2 -ne 0)) {
        throw '模拟器端口必须是 5554 到 5584 之间的偶数。'
    }

    $running = Get-CimInstance Win32_Process -Filter "Name = 'qemu-system-x86_64.exe' OR Name = 'emulator.exe'" |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith((Join-Path $sdkRoot 'emulator\'), [StringComparison]::OrdinalIgnoreCase) -and $_.CommandLine -match '(?i)-avd\s+(InternalAndroid15|ArtemisOS_15)(\s|$)' }
    if ($running) { throw 'ArtemisOS 15 已在运行。请先关闭模拟器，再重新启动以应用配置。' }

    if ($Port -eq 0) {
        foreach ($candidate in 5554..5584) {
            if ($candidate % 2 -eq 0 -and (Test-PortPair $candidate)) { $Port = $candidate; break }
        }
        if ($Port -eq 0) { throw '没有可用的模拟器端口，请关闭不需要的安卓模拟器后重试。' }
    } elseif (-not (Test-PortPair $Port)) {
        throw "模拟器端口 $Port 已被占用。"
    }

    # Set these only for this process and its child; do not change the user's SDK.
    $env:ANDROID_HOME = $sdkRoot
    $env:ANDROID_SDK_ROOT = $sdkRoot
    $env:ANDROID_AVD_HOME = $avdRoot
    $accelOutput = (& $emulator -accel-check 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $accelOutput -notmatch '(?s)accel:\s*0\s') {
        throw "无法使用 CPU 虚拟化加速。请在 BIOS 中启用 Intel VT-x 或 AMD-V，并在‘启用或关闭 Windows 功能’中启用‘Windows 虚拟机监控程序平台’，然后重启电脑。`r`n`r`n$accelOutput"
    }

    # Older releases stored the same user's data under this folder. Reuse it in place.
    if (Test-Path -LiteralPath $legacyAvdPath -PathType Container) { $avdPath = $legacyAvdPath }
    [void](New-Item -ItemType Directory -Path $avdPath -Force)
    [void](New-Item -ItemType Directory -Path $logRoot -Force)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $avdIni = "avd.ini.encoding=UTF-8`npath=$avdPath`ntarget=android-35`n"
    [System.IO.File]::WriteAllText((Join-Path $avdRoot ($avdName + '.ini')), $avdIni, $utf8)

    $configPath = Join-Path $avdPath 'config.ini'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        $config = @'
AvdId=ArtemisOS_15
PlayStore.enabled=false
abi.type=x86_64
avd.ini.displayname=ArtemisOS 15
avd.ini.encoding=UTF-8
disk.dataPartition.size=6G
fastboot.forceColdBoot=yes
hw.accelerometer=yes
hw.audioInput=yes
hw.battery=yes
hw.camera.back=virtualscene
hw.camera.front=emulated
hw.cpu.arch=x86_64
hw.cpu.ncore=2
hw.device.manufacturer=Generic
hw.device.name=android_phone
hw.gps=yes
hw.gpu.enabled=yes
hw.gpu.mode=auto
hw.keyboard=yes
hw.lcd.density=320
hw.lcd.height=1600
hw.lcd.width=720
hw.mainKeys=no
hw.ramSize=2560
hw.sdCard=no
image.sysdir.1=system-images\android-35\google_apis\x86_64\
runtime.network.latency=none
runtime.network.speed=full
showDeviceFrame=no
skin.dynamic=yes
skin.name=720x1600
tag.display=Google APIs
tag.id=google_apis
target=android-35
vm.heapSize=256
'@
        [System.IO.File]::WriteAllText($configPath, $config, $utf8)
    }

    $preferences = Get-ArtemisPreferences
    $resources = Get-ArtemisResources $preferences.Profile
    $configLines = [IO.File]::ReadAllLines($configPath)
    $configLines = Set-ConfigValue $configLines 'AvdId' $avdName
    $configLines = Set-ConfigValue $configLines 'avd.ini.displayname' 'ArtemisOS 15'
    $configLines = Set-ConfigValue $configLines 'hw.cpu.ncore' ([string]$resources.Cpu)
    $configLines = Set-ConfigValue $configLines 'hw.ramSize' ([string]$resources.MemoryMB)
    [IO.File]::WriteAllLines($configPath, [string[]]$configLines, $utf8)

    $arguments = @('-avd', $avdName, '-gpu', $Graphics, '-no-snapshot', '-port', [string]$Port, '-timezone', 'Asia/Shanghai')
    $state = Read-ArtemisKeyValues $script:ArtemisStatePath
    if ($state['locale'] -ne '1') { $arguments += @('-change-locale', 'zh-CN') }
    if ($Headless) { $arguments += @('-no-window', '-no-audio', '-no-boot-anim') }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $stdout = Join-Path $logRoot ($stamp + '-stdout.log')
    $stderr = Join-Path $logRoot ($stamp + '-stderr.log')
    $process = Start-Process -FilePath $emulator -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent $emulator) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
    function Set-EmulatorNormalPriority([int]$EmulatorId) {
        try {
            $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $EmulatorId AND Name = 'qemu-system-x86_64.exe'" -ErrorAction Stop)
            foreach ($processId in (@($EmulatorId) + @($children | ForEach-Object { $_.ProcessId }))) {
                $emulatorProcess = Get-Process -Id $processId -ErrorAction SilentlyContinue
                if ($null -ne $emulatorProcess -and $emulatorProcess.PriorityClass -in @('Idle','BelowNormal')) {
                    $emulatorProcess.PriorityClass = [Diagnostics.ProcessPriorityClass]::Normal
                }
            }
        } catch {
            try { Add-Content -LiteralPath $stderr -Value ("无法调整模拟器进程优先级：" + $_.Exception.Message) -Encoding UTF8 } catch { }
        }
    }
    Set-EmulatorNormalPriority $process.Id
    Start-Sleep -Seconds 3
    $process.Refresh()
    if ($process.HasExited -and $process.ExitCode -ne 0) {
        throw "模拟器启动失败，诊断日志位于：`r`n$stderr`r`n$stdout"
    }
    # The QEMU child can appear after the parent; normalize it after startup too.
    Set-EmulatorNormalPriority $process.Id
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $initialize = Join-Path $installRoot 'initialize.ps1'
    $initializeArgs = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $initialize + '"'), '-Serial', "emulator-$Port", '-EmulatorPid', [string]$process.Id)
    if ($Headless) { $initializeArgs += '-Headless' }
    Start-Process -FilePath $powershell -ArgumentList $initializeArgs -WindowStyle Hidden | Out-Null
    if (-not $Headless) {
        $bridge = Join-Path $installRoot 'update\bridge.ps1'
        if (Test-Path -LiteralPath $bridge -PathType Leaf) {
            $bridgeArgs = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $bridge + '"'), '-Serial', "emulator-$Port", '-EmulatorPid', [string]$process.Id, '-Graphics', $Graphics)
            Start-Process -FilePath $powershell -ArgumentList $bridgeArgs -WindowStyle Hidden | Out-Null
        }
    }
} catch {
    Show-Problem $_.Exception.Message
    exit 1
}
