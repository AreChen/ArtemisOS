param(
    [ValidateSet('auto', 'swiftshader')]
    [string]$Graphics = 'auto',
    [switch]$Headless,
    [int]$Port = 0,
    [switch]$ExternalDisplay,
    [string]$SessionId = '',
    [int]$FrontendPid = 0,
    [string]$FrontendStartTimeUtcTicks = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

function Show-Problem([string]$Message) {
    if ($Headless -or $ExternalDisplay) {
        [Console]::Error.WriteLine($Message)
        return
    }
    [void][System.Windows.Forms.MessageBox]::Show(
        $Message, 'ArtemisOS 15',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
}

function Get-ArtemisLaunchMode([switch]$Headless, [switch]$ExternalDisplay, [switch]$FrontendAvailable, [ValidateSet('artemis', 'native')][string]$Preference = 'artemis') {
    if ($Headless -and $ExternalDisplay) { throw 'Headless and ExternalDisplay cannot be used together.' }
    return @{
        DelegateFrontend=($Preference -eq 'artemis' -and $FrontendAvailable -and -not $Headless -and -not $ExternalDisplay)
        EmulatorArguments=@(if ($Headless) { '-no-window'; '-no-audio'; '-no-boot-anim' } elseif ($ExternalDisplay) { '-no-window' })
        InitializeHeadless=($Headless -or $ExternalDisplay)
        StartBridge=(-not $Headless)
    }
}

function ConvertTo-ArtemisNativeArgument([string]$Value) {
    # Quote for CommandLineToArgvW-compatible executables, never through cmd.exe.
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    return '"' + [regex]::Replace($escaped, '(\\+)$', '$1$1') + '"'
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

function Get-ArtemisLaunchPort([int]$RequestedPort = 0) {
    if ($RequestedPort -ne 0 -and ($RequestedPort -lt 5554 -or $RequestedPort -gt 5584 -or $RequestedPort % 2 -ne 0)) {
        throw '模拟器端口必须是 5554 到 5584 之间的偶数。'
    }
    $reservedPorts = @(Get-ArtemisAdbReservedPorts)
    if ($RequestedPort -eq 0) {
        foreach ($candidate in 5554..5584) {
            if ($candidate % 2 -eq 0 -and $candidate -notin $reservedPorts -and (Test-PortPair $candidate)) { return $candidate }
        }
        throw '没有可用的模拟器端口，请关闭不需要的安卓模拟器后重试。'
    }
    if ($RequestedPort -in $reservedPorts -or -not (Test-PortPair $RequestedPort)) { throw "模拟器端口 $RequestedPort 已被占用。" }
    return $RequestedPort
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

function Enter-ArtemisLaunchLock([string]$InstallRoot) {
    # Separate installations must not block each other. The global namespace
    # also protects a shared installation across Windows logon sessions.
    $path = [IO.Path]::GetFullPath($InstallRoot).TrimEnd([char[]]'\/').ToUpperInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($path)) }
    finally { $sha.Dispose() }
    $name = 'Global\ArtemisOS-Launch-' + ([BitConverter]::ToString($digest) -replace '-', '')
    $mutex = New-Object Threading.Mutex($false, $name)
    try {
        try { $held = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'ArtemisOS 正在启动，请稍候，不要重复启动。' }
        return $mutex
    } catch {
        $mutex.Dispose()
        throw
    }
}

function Get-ArtemisSdCard([string]$AvdPath, [string[]]$ConfigLines, [string]$MakeSdCardPath, [long]$CapacityBytes = 1GB) {
    # Existing custom paths and image data always take priority. Never format,
    # resize, replace, or recreate an existing card or its QCOW2 overlay.
    function Find-Item([string]$Path) {
        try { return Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
        catch [System.Management.Automation.ItemNotFoundException] { return $null }
    }
    $configuredPath = $null
    foreach ($line in $ConfigLines) {
        $match = [regex]::Match($line, '^\s*(?:hw\.sdCard\.path|sdcard\.path)\s*=\s*(.*?)\s*$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $match.Success -or -not $match.Groups[1].Value) { continue }
        $value = $match.Groups[1].Value.Trim()
        if ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) { $value = $value.Substring(1, $value.Length - 2) }
        if (-not $value) { continue }
        if ($value.Contains('"') -or $value -match '^[A-Za-z]:(?![\\/])' -or $value -match '^[\\/](?![\\/])') {
            throw 'SD 卡的自定义路径无效，请检查配置。'
        }
        if (-not [IO.Path]::IsPathRooted($value)) { $value = Join-Path $AvdPath $value }
        $value = [IO.Path]::GetFullPath($value)
        if ($configuredPath -and -not [string]::Equals($configuredPath, $value, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'SD 卡配置中存在多个不同的自定义路径，请检查配置。'
        }
        $configuredPath = $value
    }
    $cardPath = if ($configuredPath) { $configuredPath } else { Join-Path $AvdPath 'sdcard.img' }
    $card = Find-Item $cardPath
    if ($card) {
        if ($card.PSIsContainer -or ($card.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $card.Length -lt 9MB) {
            throw '已有的 SD 卡镜像不可用，已保留原文件；请检查或恢复镜像。'
        }
        return $card.FullName
    }
    if ($configuredPath) { throw '找不到配置的 SD 卡镜像，已保留原配置；请检查文件路径。' }
    if (Find-Item ($cardPath + '.qcow2')) { throw 'SD 卡的基础镜像缺失，但发现已有数据文件；已保留文件，请先恢复。' }

    # Create only a unique temporary image in the same AVD directory. A failed
    # or interrupted attempt is retained and must not be silently replaced.
    $unfinished = @(Get-ChildItem -LiteralPath $AvdPath -Filter '.artemisos-sdcard-create-*.tmp' -Force -ErrorAction Stop)
    if ($unfinished.Count -gt 0) {
        $paths = @($unfinished | Select-Object -First 5 | ForEach-Object { $_.FullName }) -join "`r`n"
        if ($unfinished.Count -gt 5) { $paths += "`r`n以及该目录中的其他同类临时文件。" }
        throw "发现未完成的 SD 卡创建临时文件，已保留：`r`n$paths`r`n请关闭模拟器后检查并清理这些未完成的临时文件；不要删除已有的卡镜像及其 .qcow2 文件。"
    }
    $directory = Get-Item -LiteralPath $AvdPath -Force -ErrorAction Stop
    while ($null -ne $directory) {
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'SD 卡目录不能经过链接或重解析点。' }
        $directory = $directory.Parent
    }
    if ($CapacityBytes -lt 9MB -or $CapacityBytes % 1MB -ne 0) { throw 'SD 卡容量无效。' }
    $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($AvdPath)))
    if ($drive.AvailableFreeSpace -lt $CapacityBytes) { throw '磁盘空间不足，无法创建 1 GB SD 卡。' }
    $tool = Find-Item $MakeSdCardPath
    if (-not $tool -or $tool.PSIsContainer -or ($tool.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw '缺少创建 SD 卡所需的模拟器文件，请重新安装或更新 ArtemisOS。'
    }
    $temporary = Join-Path $AvdPath ('.artemisos-sdcard-create-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $reservation = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $reservation.Dispose()
    & $MakeSdCardPath (('{0}M' -f ($CapacityBytes / 1MB))) $temporary 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "创建 SD 卡失败，未完成的临时文件路径：`r`n$temporary`r`n请关闭模拟器后检查并清理该临时文件；不要删除已有卡镜像或 .qcow2 文件。" }
    $created = Get-Item -LiteralPath $temporary -Force -ErrorAction Stop
    if ($created.PSIsContainer -or ($created.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $created.Length -ne $CapacityBytes) {
        throw "创建的 SD 卡镜像大小不正确，未完成的临时文件路径：`r`n$temporary`r`n请关闭模拟器后检查并清理该临时文件；不要删除已有卡镜像或 .qcow2 文件。"
    }
    [IO.File]::Move($temporary, $cardPath) # Never replaces an existing target.
    return $cardPath
}

$launchMutex = $null
$process = $null
$sessionCreated = $false
try {
    $installRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    . (Join-Path $installRoot 'settings.ps1')
    $preferences = Get-ArtemisPreferences
    $frontend = Join-Path $installRoot 'update\frontend\ArtemisFrontend.exe'
    $launchMode = Get-ArtemisLaunchMode -Headless:$Headless -ExternalDisplay:$ExternalDisplay -FrontendAvailable:(Test-Path -LiteralPath $frontend -PathType Leaf) -Preference $preferences.Frontend
    if ($launchMode.DelegateFrontend) {
        if ($Port -eq 0) {
            $Port = Get-ArtemisLaunchPort
        }
        $frontendArguments = @('--root', (ConvertTo-ArtemisNativeArgument $installRoot), '--graphics', $Graphics, '--port', [string]$Port)
        Start-Process -FilePath $frontend -ArgumentList $frontendArguments -WorkingDirectory $installRoot | Out-Null
        return
    }
    if ($ExternalDisplay) {
        . (Join-Path $installRoot 'update\frontend-handoff.ps1')
        [void](Get-ArtemisFrontendSessionPath $installRoot $SessionId)
        if (-not (Test-ArtemisFrontendIdentity (Get-ArtemisFrontendProcessSnapshot $FrontendPid) $installRoot $FrontendPid $FrontendStartTimeUtcTicks)) {
            throw 'The external display frontend does not belong to this installation or has exited.'
        }
        if (Test-Path -LiteralPath (Get-ArtemisFrontendSessionPath $installRoot $SessionId)) { throw 'The frontend session already exists.' }
    } elseif ($SessionId -or $FrontendPid -ne 0 -or $FrontendStartTimeUtcTicks) {
        throw 'Frontend session arguments require ExternalDisplay mode.'
    }
    $launchMutex = Enter-ArtemisLaunchLock $installRoot
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

    $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'qemu-system-x86_64.exe' OR Name = 'qemu-system-x86_64-headless.exe' OR Name = 'emulator.exe'" -ErrorAction Stop)
    foreach ($candidate in $processes) {
        if (-not $candidate.ExecutablePath) { throw '无法确认运行中的模拟器进程，请关闭模拟器后重试。' }
        if (-not $candidate.ExecutablePath.StartsWith((Join-Path $sdkRoot 'emulator\'), [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not $candidate.CommandLine) { throw '无法确认 ArtemisOS 的运行状态，请关闭模拟器后重试。' }
        if ($candidate.CommandLine -match '(?i)-avd\s+(InternalAndroid15|ArtemisOS_15)(\s|$)') {
            throw 'ArtemisOS 15 已在运行。请先关闭模拟器，再重新启动以应用配置。'
        }
    }

    $Port = Get-ArtemisLaunchPort $Port

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
    $display = Get-ArtemisDisplay $preferences.Resolution
    $renderer = Get-ArtemisGraphics $preferences.Graphics $Graphics
    $graphicsRuntime = Get-ArtemisGraphicsRuntime $renderer
    $graphicsDevice = if ($renderer -in @('vulkan_intel', 'vulkan_amd')) { Get-ArtemisSelectedVulkanDevice -Renderer $renderer -DeviceId $preferences.GraphicsDevice } else { '' }
    $configLines = [IO.File]::ReadAllLines($configPath)
    $sdcardPath = Get-ArtemisSdCard $avdPath $configLines (Join-Path $sdkRoot 'emulator\mksdcard.exe')
    $configLines = Set-ConfigValue $configLines 'AvdId' $avdName
    $configLines = Set-ConfigValue $configLines 'avd.ini.displayname' 'ArtemisOS 15'
    $configLines = Set-ConfigValue $configLines 'hw.cpu.ncore' ([string]$resources.Cpu)
    $configLines = Set-ConfigValue $configLines 'hw.ramSize' ([string]$resources.MemoryMB)
    $configLines = Set-ConfigValue $configLines 'hw.sdCard' 'yes'
    $configLines = Set-ConfigValue $configLines 'hw.lcd.width' ([string]$display.Width)
    $configLines = Set-ConfigValue $configLines 'hw.lcd.height' ([string]$display.Height)
    $configLines = Set-ConfigValue $configLines 'hw.lcd.density' ([string]$display.Density)
    $configLines = Set-ConfigValue $configLines 'skin.dynamic' 'yes'
    $configLines = Set-ConfigValue $configLines 'skin.name' ("{0}x{1}" -f $display.Width, $display.Height)
    [IO.File]::WriteAllLines($configPath, [string[]]$configLines, $utf8)

    $simProfile = New-ArtemisSimProfile $preferences.Carrier
    $arguments = @('-avd', $avdName, '-gpu', $graphicsRuntime.GpuMode, '-no-snapshot', '-port', [string]$Port, '-timezone', 'Asia/Shanghai', '-icc-profile', ('"' + $simProfile + '"'))
    foreach ($feature in $graphicsRuntime.DisabledFeatures) { $arguments += @('-feature', ('-' + $feature)) }
    $arguments += @('-sdcard', ('"' + $sdcardPath + '"'))
    if ($preferences.VideoCompat -eq '1') { $arguments += @('-feature', '-HardwareDecoder') }
    $state = Read-ArtemisKeyValues $script:ArtemisStatePath
    if ($state['locale'] -ne '1') { $arguments += @('-change-locale', 'zh-CN') }
    $arguments += @($launchMode.EmulatorArguments)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $stdout = Join-Path $logRoot ($stamp + '-stdout.log')
    $stderr = Join-Path $logRoot ($stamp + '-stderr.log')
    $graphicsEnvironment = Get-ArtemisGraphicsEnvironment $renderer (Split-Path -Parent $emulator) $graphicsDevice
    $previousEnvironment = @{}
    try {
        foreach ($name in $graphicsEnvironment.Keys) {
            $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $graphicsEnvironment[$name], 'Process')
        }
        $process = Start-Process -FilePath $emulator -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent $emulator) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
    } finally {
        foreach ($name in $previousEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
        }
    }
    if ($ExternalDisplay) {
        $emulatorTicks = $process.StartTime.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
        New-ArtemisFrontendSession -InstallRoot $installRoot -SessionId $SessionId -Serial "emulator-$Port" -EmulatorPid $process.Id -EmulatorStartTimeUtcTicks $emulatorTicks -FrontendPid $FrontendPid -FrontendStartTimeUtcTicks $FrontendStartTimeUtcTicks -GraphicsOverride $Graphics -GraphicsRenderer $renderer -GraphicsDevice $graphicsDevice -StdoutLog $stdout -StderrLog $stderr
        $sessionCreated = $true
    }
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
    $initializeArgs = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $initialize + '"'), '-Serial', "emulator-$Port", '-EmulatorPid', [string]$process.Id, '-GraphicsRenderer', $renderer)
    if ($graphicsDevice) { $initializeArgs += @('-GraphicsDevice', ('"' + $graphicsDevice + '"')) }
    if ($launchMode.InitializeHeadless) { $initializeArgs += '-Headless' }
    if ($ExternalDisplay) { $initializeArgs += @('-SessionId', $SessionId) }
    Start-Process -FilePath $powershell -ArgumentList $initializeArgs -WindowStyle Hidden | Out-Null
    if ($launchMode.StartBridge) {
        $bridge = Join-Path $installRoot 'update\bridge.ps1'
        if (Test-Path -LiteralPath $bridge -PathType Leaf) {
            $bridgeArgs = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $bridge + '"'), '-Serial', "emulator-$Port", '-EmulatorPid', [string]$process.Id, '-Graphics', $Graphics)
            Start-Process -FilePath $powershell -ArgumentList $bridgeArgs -WindowStyle Hidden | Out-Null
        }
    }
} catch {
    $launchError = $_.Exception.Message
    if ($ExternalDisplay -and $null -ne $process) {
        if ($sessionCreated) {
            try { Set-ArtemisFrontendSessionState -InstallRoot $installRoot -SessionId $SessionId -Serial "emulator-$Port" -EmulatorPid $process.Id -State failed -Error $launchError } catch { }
        }
        try {
            $owner = Get-CimInstance Win32_Process -Filter "ProcessId = $($process.Id)" -ErrorAction Stop
            if (Test-ArtemisEmulatorOwnership $owner $installRoot $process.Id "emulator-$Port") {
                $owned = Get-ArtemisFrontendProcessSnapshot $process.Id
                if ($null -ne $owned -and $owned.StartTimeUtcTicks -ceq $process.StartTime.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)) {
                    & (Join-Path $installRoot 'sdk\platform-tools\adb.exe') -s "emulator-$Port" emu kill 2>&1 | Out-Null
                }
            }
        } catch { }
    }
    Show-Problem $launchError
    exit 1
} finally {
    if ($null -ne $launchMutex) {
        $launchMutex.ReleaseMutex()
        $launchMutex.Dispose()
    }
}
