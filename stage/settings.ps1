$script:ArtemisDataRoot = Join-Path $PSScriptRoot 'data'
$script:ArtemisPreferencesPath = Join-Path $script:ArtemisDataRoot 'preferences.ini'
$script:ArtemisStatePath = Join-Path $script:ArtemisDataRoot 'setup-state.ini'
$script:ArtemisManagedAppsPath = Join-Path $script:ArtemisDataRoot 'managed-google-apps.txt'

function Get-ArtemisVersion {
    $path = Join-Path $PSScriptRoot 'version.ini'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($path)) {
            if ($line -match '^Version=(\d+\.\d+\.\d+)$') { return $matches[1] }
        }
    }
    return 'unknown'
}

function Read-ArtemisKeyValues([string]$Path) {
    $values = @{}
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($Path)) {
            if ($line -match '^([a-z_][a-z0-9_.-]*)=(.*)$') { $values[$matches[1]] = $matches[2] }
        }
    }
    return $values
}

function Get-ArtemisAdbReservedPorts([int]$ServerPort = 5037) {
    # Some emulators proxy ADB through NAT without reserving the host port.
    # Query the existing ADB server directly so we do not restart another SDK's server.
    $client = New-Object Net.Sockets.TcpClient
    try {
        $client.ReceiveTimeout = 2000
        $client.SendTimeout = 2000
        $client.Connect([Net.IPAddress]::Loopback, $ServerPort)
        $stream = $client.GetStream()
        $request = [Text.Encoding]::ASCII.GetBytes('000Chost:devices')
        $stream.Write($request, 0, $request.Length)

        function Read-AdbBytes($InputStream, [int]$Count) {
            $buffer = New-Object byte[] $Count
            $offset = 0
            while ($offset -lt $Count) {
                $read = $InputStream.Read($buffer, $offset, $Count - $offset)
                if ($read -le 0) { throw 'ADB server closed the connection.' }
                $offset += $read
            }
            return ,$buffer
        }

        if ([Text.Encoding]::ASCII.GetString((Read-AdbBytes $stream 4)) -ne 'OKAY') { return @() }
        $length = [Convert]::ToInt32([Text.Encoding]::ASCII.GetString((Read-AdbBytes $stream 4)), 16)
        if ($length -gt 65535) { return @() }
        $devices = [Text.Encoding]::UTF8.GetString((Read-AdbBytes $stream $length))
        foreach ($line in ($devices -split "`n")) {
            if ($line -match '^emulator-(\d+)\s') {
                [int]$matches[1]
            } elseif ($line -match '^127\.0\.0\.1:(\d+)\s') {
                $adbPort = [int]$matches[1]
                if ($adbPort -ge 5555 -and $adbPort -le 5585 -and $adbPort % 2 -eq 1) { $adbPort - 1 }
            }
        }
    } catch {
        return @()
    } finally {
        $client.Close()
    }
}

function Test-ArtemisMaxFps([string]$Value) {
    return ($Value -cmatch '\A[1-9][0-9]{0,2}\z' -and [int]$Value -le 240)
}

function Get-ArtemisPreferences {
    $values = Read-ArtemisKeyValues $script:ArtemisPreferencesPath
    $profile = if ($values['profile'] -in @('low', 'medium', 'high')) { $values['profile'] } else { 'low' }
    $cleanup = if ($values['cleanup'] -in @('0', '1')) { $values['cleanup'] } else { '1' }
    $videoCompat = if ($values['video_compat'] -in @('0', '1')) { $values['video_compat'] } else { '1' }
    $carrier = if ($values['carrier'] -in @('mobile', 'telecom', 'unicom')) { $values['carrier'] } else { 'mobile' }
    $graphics = if ($values['graphics'] -in @('auto', 'host', 'vulkan', 'vulkan_intel', 'vulkan_amd', 'software', 'swiftshader', 'swangle', 'lavapipe')) { $values['graphics'] } else { 'host' }
    $graphicsDevice = if (Test-ArtemisGraphicsDeviceId $values['graphics_device']) { $values['graphics_device'] } else { '' }
    $resolution = if ($values['resolution'] -in @('720p', '900p', '1080p', '720x1280', '1080x1920', '1280x720', '1920x1080')) { $values['resolution'] } else { '720p' }
    $frontend = if ($values['frontend'] -in @('artemis', 'native')) { $values['frontend'] } else { 'artemis' }
    $maxFps = if (Test-ArtemisMaxFps $values['max_fps']) { [int]$values['max_fps'] } else { 60 }
    return [pscustomobject]@{ Profile = $profile; Cleanup = $cleanup; VideoCompat = $videoCompat; Carrier = $carrier; Graphics = $graphics; Resolution = $resolution; Frontend = $frontend; GraphicsDevice = $graphicsDevice; MaxFps = $maxFps }
}

function Write-ArtemisPreferences([string]$Profile, [string]$Cleanup, [string]$VideoCompat, [string]$Carrier = 'mobile', [string]$Graphics = 'host', [string]$Resolution = '720p', [string]$Frontend, [string]$GraphicsDevice, [string]$MaxFps) {
    # Older positional callers change only their existing fields; they must not
    # reset a native-window choice made by a newer configuration UI.
    if (-not $PSBoundParameters.ContainsKey('Frontend')) { $Frontend = (Get-ArtemisPreferences).Frontend }
    if (-not $PSBoundParameters.ContainsKey('GraphicsDevice')) { $GraphicsDevice = (Get-ArtemisPreferences).GraphicsDevice }
    if (-not $PSBoundParameters.ContainsKey('MaxFps')) { $MaxFps = [string](Get-ArtemisPreferences).MaxFps }
    if ($Profile -notin @('low', 'medium', 'high') -or $Cleanup -notin @('0', '1') -or $VideoCompat -notin @('0', '1') -or
        $Carrier -notin @('mobile', 'telecom', 'unicom') -or
        $Graphics -notin @('auto', 'host', 'vulkan', 'vulkan_intel', 'vulkan_amd', 'software', 'swiftshader', 'swangle', 'lavapipe') -or
        ($GraphicsDevice -and -not (Test-ArtemisGraphicsDeviceId $GraphicsDevice)) -or
        $Resolution -notin @('720p', '900p', '1080p', '720x1280', '1080x1920', '1280x720', '1920x1080') -or
        $Frontend -notin @('artemis', 'native') -or -not (Test-ArtemisMaxFps $MaxFps)) {
        throw '无效的模拟器配置。'
    }
    [void][IO.Directory]::CreateDirectory($script:ArtemisDataRoot)
    $values = Read-ArtemisKeyValues $script:ArtemisPreferencesPath
    $values['profile'] = $Profile; $values['cleanup'] = $Cleanup; $values['video_compat'] = $VideoCompat
    $values['carrier'] = $Carrier; $values['graphics'] = $Graphics; $values['resolution'] = $Resolution; $values['frontend'] = $Frontend; $values['graphics_device'] = $GraphicsDevice
    $values['max_fps'] = $MaxFps
    $keys = @('profile', 'cleanup', 'video_compat', 'carrier', 'graphics', 'resolution', 'frontend', 'graphics_device', 'max_fps')
    $keys += @($values.Keys | Where-Object { $_ -notin $keys } | Sort-Object)
    $lines = @($keys | ForEach-Object { "$_=$($values[$_])" })
    [IO.File]::WriteAllText($script:ArtemisPreferencesPath, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
}

function Get-ArtemisDisplay([string]$Resolution) {
    # Keep the same logical 360 x 800 dp size while increasing pixel density.
    switch ($Resolution) {
        '720p'  { return [pscustomobject]@{ Width = 720; Height = 1600; Density = 320 } }
        '900p'  { return [pscustomobject]@{ Width = 900; Height = 2000; Density = 400 } }
        '1080p' { return [pscustomobject]@{ Width = 1080; Height = 2400; Density = 480 } }
        # 9:16 and 16:9 presets retain a 360 dp short edge at either pixel density.
        '720x1280'  { return [pscustomobject]@{ Width = 720; Height = 1280; Density = 320 } }
        '1080x1920' { return [pscustomobject]@{ Width = 1080; Height = 1920; Density = 480 } }
        '1280x720'  { return [pscustomobject]@{ Width = 1280; Height = 720; Density = 320 } }
        '1920x1080' { return [pscustomobject]@{ Width = 1920; Height = 1080; Density = 480 } }
        default { throw '无效的屏幕分辨率。' }
    }
}

function Get-ArtemisGraphics([string]$Preference, [string]$LaunchMode) {
    if ($Preference -notin @('auto', 'host', 'vulkan', 'vulkan_intel', 'vulkan_amd', 'software', 'swiftshader', 'swangle', 'lavapipe') -or
        $LaunchMode -notin @('auto', 'swiftshader')) { throw '无效的图形渲染配置。' }
    # The existing software shortcut is a one-time override; it does not change preferences.
    if ($LaunchMode -eq 'swiftshader' -or $Preference -in @('software', 'swiftshader', 'swangle')) { return 'swangle' }
    return $Preference
}

function Test-ArtemisGraphicsDeviceName([string]$Name) {
    return (-not [string]::IsNullOrWhiteSpace($Name) -and $Name.Length -le 255 -and $Name -notmatch '[\x00-\x1f\x7f"]')
}

function Test-ArtemisGraphicsDeviceId([string]$Id) {
    return ($Id.Length -le 512 -and $Id -match '^PCI\\VEN_(?:1002|8086)(?:&|$)' -and $Id -notmatch '[^a-zA-Z0-9_\\&.+-]')
}

function Get-ArtemisVulkanDevices([string]$Renderer, [object[]]$VideoControllers) {
    $vendor = switch ($Renderer) { 'vulkan_amd' { '1002' } 'vulkan_intel' { '8086' } default { throw '此渲染模式不支持指定显卡。' } }
    if (-not $PSBoundParameters.ContainsKey('VideoControllers')) {
        try { $VideoControllers = @(Get-CimInstance Win32_VideoController -ErrorAction Stop) }
        catch { throw '无法读取电脑显卡信息。请检查显卡驱动，或选择其他渲染模式。' }
    }
    $devices = @(foreach ($controller in $VideoControllers) {
        if ($controller.ConfigManagerErrorCode -eq 0 -and $controller.PNPDeviceID -match ('^PCI\\VEN_' + $vendor + '(?:&|$)') -and
            (Test-ArtemisGraphicsDeviceId ([string]$controller.PNPDeviceID)) -and (Test-ArtemisGraphicsDeviceName ([string]$controller.Name))) {
            [pscustomobject]@{ Name = [string]$controller.Name; Id = [string]$controller.PNPDeviceID }
        }
    })
    return $devices | Sort-Object Id, Name -Unique
}

function Get-ArtemisSelectedVulkanDevice([string]$Renderer, [string]$DeviceId = '', [object[]]$VideoControllers) {
    $arguments = @{ Renderer = $Renderer }
    if ($PSBoundParameters.ContainsKey('VideoControllers')) { $arguments.VideoControllers = $VideoControllers }
    $devices = @(Get-ArtemisVulkanDevices @arguments)
    $vendorLabel = if ($Renderer -eq 'vulkan_amd') { 'AMD' } else { 'Intel' }
    if ($DeviceId) {
        if (-not (Test-ArtemisGraphicsDeviceId $DeviceId)) { throw '已选显卡标识无效。请重新选择显卡。' }
        $selected = @($devices | Where-Object { $_.Id -ieq $DeviceId })
    } else { $selected = $devices }
    if ($selected.Count -eq 0) { throw "未找到已选或可用的 $vendorLabel PCI 显卡。请检查驱动、启用设备或重新选择显卡。" }
    if ($selected.Count -ne 1) { throw "检测到多个 $vendorLabel 显卡。请在配置的『渲染设备』中选择具体显卡。" }
    # ANGLE selects by name. Two different adapters with the same name cannot
    # be distinguished reliably by this runtime, even when Windows IDs differ.
    if (@($devices | Where-Object { $_.Name -ieq $selected[0].Name }).Count -ne 1) {
        throw '存在名称相同的多个显卡，当前运行时无法唯一定位。请选择通用硬件 Vulkan 或其他渲染模式。'
    }
    return $selected[0].Name
}

function Get-ArtemisIntelVulkanDevice([object[]]$VideoControllers) {
    if (-not $PSBoundParameters.ContainsKey('VideoControllers')) {
        try { $VideoControllers = @(Get-CimInstance Win32_VideoController -ErrorAction Stop) }
        catch { throw '无法读取电脑显卡信息。请检查 Intel 显卡驱动，或选择其他渲染模式。' }
    }
    # PCI identifies the vendor; display names do not identify a GPU family or
    # distinguish integrated/discrete Arc devices. Pass the exact Windows name
    # to ANGLE and verify the actual Vulkan device after boot.
    $names = @($VideoControllers | Where-Object {
        $_.ConfigManagerErrorCode -eq 0 -and $_.PNPDeviceID -match '^PCI\\VEN_8086(?:&|$)' -and
        (Test-ArtemisGraphicsDeviceName ([string]$_.Name))
    } | ForEach-Object { [string]$_.Name } | Sort-Object -Unique)
    if ($names.Count -eq 0) { throw '未找到已启用且名称有效的 Intel PCI 显卡。请先启用显卡并安装驱动，或选择其他渲染模式。' }
    if ($names.Count -ne 1) { throw '检测到多个不同的 Intel 显卡，无法唯一选择。请暂时选择其他渲染模式。' }
    return $names[0]
}

function Get-ArtemisGraphicsEnvironment([string]$Renderer, [string]$EmulatorRoot, [string]$DeviceName = '') {
    if ($Renderer -notin @('auto', 'host', 'vulkan', 'vulkan_intel', 'vulkan_amd', 'software', 'swiftshader', 'swangle', 'lavapipe')) { throw '无效的图形渲染配置。' }
    if ($Renderer -eq 'host') { return @{} }
    # DeviceName comes from PCI-based selection above, not a model-name whitelist.
    if ($Renderer -in @('vulkan_intel', 'vulkan_amd') -and -not (Test-ArtemisGraphicsDeviceName $DeviceName)) {
        throw '指定显卡 Vulkan 需要已检测到的完整显卡名称。请重新打开配置或选择其他渲染模式。'
    }
    try {
        $manifestPath = Join-Path $EmulatorRoot 'modern-vulkan.json'
        $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        if ($manifest.schemaVersion -ne 1 -or $manifest.provider -cne 'angle-swiftshader-vulkan' -or
            $manifest.runtimeVersion -cne '37.3.9' -or $manifest.runtimeBuild -cne '16863232' -or
            $manifest.glesProvider -cne 'lib64/gles_swiftshader' -or
            $manifest.vulkanIcd -cne 'lib64/vulkan/vk_swiftshader_icd.json') { throw 'Unsupported provider manifest.' }
        foreach ($relative in @('lib64\gles_swiftshader\libEGL.dll', 'lib64\gles_swiftshader\libGLESv2.dll',
            'lib64\gles_swiftshader\vk_swiftshader.dll', 'lib64\gles_swiftshader\vk_swiftshader_icd.json',
            'lib64\gles_swiftshader\vulkan-1.dll', 'lib64\gles_swiftshader\d3dcompiler_47.dll',
            'lib64\vulkan\vk_swiftshader.dll', 'lib64\vulkan\vk_swiftshader_icd.json')) {
            if (-not (Test-Path -LiteralPath (Join-Path $EmulatorRoot $relative) -PathType Leaf)) { throw 'Missing provider file.' }
        }
        if ($Renderer -in @('vulkan', 'vulkan_intel', 'vulkan_amd')) {
            $properties = [IO.File]::ReadAllText((Join-Path $EmulatorRoot 'source.properties'))
            if ($properties -notmatch '(?m)^Pkg\.Revision=37\.3\.9\r?$' -or
                $properties -notmatch '(?m)^Pkg\.BuildId=16863232\r?$') { throw 'Unvalidated hardware Vulkan runtime.' }
        }
    } catch {
        throw 'ANGLE/Vulkan 渲染组件不完整或版本不匹配，请重新安装完整的 ArtemisOS 版本。'
    }
    if ($Renderer -in @('vulkan', 'vulkan_intel', 'vulkan_amd')) {
        # Windows host mode searches gles_swiftshader even for host EGL. The
        # validated 1.0.4 provider there is ANGLE; Vulkan selects the real GPU.
        # ANDROID_EGL_LIB/GLESv2_LIB are not consumed by this gfxstream loader.
        return @{
            ANGLE_DEFAULT_PLATFORM = 'vulkan'
            ANGLE_PREFERRED_DEVICE = $(if ($Renderer -in @('vulkan_intel', 'vulkan_amd')) { $DeviceName } else { $null })
            ANGLE_FEATURE_OVERRIDES_ENABLED = $null
            ANGLE_FEATURE_OVERRIDES_DISABLED = $null
            ANDROID_EGL_ON_EGL = '1'
            ANDROID_EMU_VK_ICD = $null
            ANDROID_GL_SOFTWARE_RENDERER = $null
            ANDROID_EMUGL_EXPERIMENTAL_FAST_PATH = $null
            # Isolate overlays before ANGLE starts, including capture layers
            # whose loader uses the provider-specific opt-out variables.
            VK_LOADER_LAYERS_DISABLE = '~implicit~'
            VK_LOADER_LAYERS_ALLOW = $null
            VK_LOADER_LAYERS_ENABLE = $null
            VK_INSTANCE_LAYERS = $null
            DISABLE_VULKAN_OW_OVERLAY_LAYER = '1'
            DISABLE_VULKAN_OW_OBS_CAPTURE = '1'
            DISABLE_VULKAN_OBS_CAPTURE = '1'
            VK_ICD_FILENAMES = $null
            VK_DRIVER_FILES = $null
            VK_ADD_DRIVER_FILES = $null
            VK_LOADER_DRIVERS_SELECT = $null
            VK_LOADER_DRIVERS_DISABLE = $null
        }
    }
    # Only choose ANGLE's provider here; the runtime enables EGL-on-EGL after selecting software GLES.
    if ($Renderer -in @('auto', 'lavapipe')) {
        return @{ ANGLE_DEFAULT_PLATFORM = 'swiftshader'; ANGLE_PREFERRED_DEVICE = $null }
    }
    # These overrides belong only to the emulator child, never the user's Windows environment.
    return @{
        ANGLE_DEFAULT_PLATFORM = 'swiftshader'
        ANGLE_PREFERRED_DEVICE = $null
        ANDROID_EGL_ON_EGL = '1'
        VK_ICD_FILENAMES = (Join-Path $EmulatorRoot 'lib64\vulkan\vk_swiftshader_icd.json')
        VK_DRIVER_FILES = $null
        VK_ADD_DRIVER_FILES = $null
        VK_LOADER_DRIVERS_SELECT = $null
        VK_LOADER_DRIVERS_DISABLE = $null
    }
}

function Get-ArtemisGraphicsRuntime([string]$Renderer) {
    if ($Renderer -in @('vulkan', 'vulkan_intel', 'vulkan_amd')) {
        # This runtime's host profile emits desktop GLSL, which ANGLE cannot use.
        # The ES profile name does not choose the actual ANGLE device: the Vulkan
        # environment selects the GPU. Disable guest Vulkan to keep its software
        # ICD setup from overriding that device selection process-wide.
        return [pscustomobject]@{ GpuMode = 'swiftshader'; DisabledFeatures = @('Vulkan') }
    }
    return [pscustomobject]@{ GpuMode = $Renderer; DisabledFeatures = @() }
}

function Assert-ArtemisHardwareVulkanRenderer([string]$SurfaceFlinger, [string]$ExpectedDevice = '') {
    $gles = @($SurfaceFlinger -split '\r?\n' | Where-Object { $_ -match '^GLES:' }) -join "`n"
    if ($gles -notmatch 'ANGLE.*Vulkan' -or
        $gles -match '(?i)SwiftShader|Subzero|llvmpipe|lavapipe|Microsoft Basic Render|\bCPU\b|software') {
        throw '硬件 Vulkan 未生效。请更新显卡驱动，或在配置中选择“硬件 OpenGL”。当前设备不支持时请手动选择软件渲染。'
    }
    if ($ExpectedDevice) {
        $pattern = 'Vulkan\s+[^()]*\(' + [Regex]::Escape($ExpectedDevice) + '(?:\s+\(0x[0-9a-fA-F]+\))?\)'
        if ($gles -cnotmatch $pattern) {
            throw "指定显卡 Vulkan 未生效：实际渲染设备与 $ExpectedDevice 不一致。请检查驱动，或在配置中选择其他渲染模式。"
        }
    }
    return $gles
}

function Test-ArtemisEmulatorOwnership($Process, [string]$InstallRoot, [int]$ExpectedPid, [string]$Serial) {
    if ($null -eq $Process -or $ExpectedPid -le 0 -or $Serial -notmatch '^emulator-(\d+)$') { return $false }
    $port = $matches[1]
    try {
        $expected = [IO.Path]::GetFullPath((Join-Path $InstallRoot 'sdk\emulator\emulator.exe'))
        return ([int]$Process.ProcessId -eq $ExpectedPid -and
            [string]::Equals([string]$Process.ExecutablePath, $expected, [StringComparison]::OrdinalIgnoreCase) -and
            [string]$Process.CommandLine -match ('(?:^|\s)-port\s+"?' + [Regex]::Escape($port) + '"?(?:\s|$)'))
    } catch { return $false }
}

function New-ArtemisSimProfile([string]$Carrier) {
    $numeric = switch ($Carrier) {
        'mobile' { '46000' }
        'telecom' { '46003' }
        'unicom' { '46001' }
        default { throw '无效的模拟运营商。' }
    }
    $modemRoot = Join-Path $PSScriptRoot 'sdk\system-images\android-35\google_apis\x86_64\data\misc\modem_simulator'
    $template = Join-Path $modemRoot 'iccprofile_for_sim0.xml'
    $operators = Join-Path $modemRoot 'etc\modem_simulator\files\numeric_operator.xml'
    if (-not (Test-Path -LiteralPath $template -PathType Leaf) -or -not (Test-Path -LiteralPath $operators -PathType Leaf)) {
        throw '模拟 SIM 配置文件不完整，请重新安装或更新 ArtemisOS。'
    }
    [xml]$operatorXml = [IO.File]::ReadAllText($operators, [Text.Encoding]::UTF8)
    if (@($operatorXml.SelectNodes("//string-array/item[@numeric='$numeric']")).Count -ne 1) {
        throw '模拟运营商配置表不完整，请重新安装或更新 ArtemisOS。'
    }
    [xml]$profile = [IO.File]::ReadAllText($template, [Text.Encoding]::UTF8)
    $identities = @($profile.SelectNodes("//EF[@name='EF_IMSI']/CIMI"))
    $adminData = @($profile.SelectNodes("//EF[@name='EF_AD']/SIMIO[@cmd='B0']"))
    if ($identities.Count -ne 1 -or $identities[0].InnerText -notmatch '^\d{15}$' -or
        $adminData.Count -ne 1 -or $adminData[0].InnerText -ne '144,0,00000003') {
        throw '模拟 SIM 模板格式不受支持，请重新安装或更新 ArtemisOS。'
    }
    # Keep the original test identity suffix; only the simulated MCC/MNC changes.
    $identities[0].InnerText = $numeric + $identities[0].InnerText.Substring(5)
    $adminData[0].InnerText = '144,0,00000002'
    $directory = Join-Path $script:ArtemisDataRoot 'sim-profiles'
    [void][IO.Directory]::CreateDirectory($directory)
    $path = Join-Path $directory ($Carrier + '.xml')
    $profile.Save($path)
    return $path
}

function Get-ArtemisResources([string]$Profile) {
    switch ($Profile) {
        'low'    { return [pscustomobject]@{ Cpu = 2; MemoryMB = 2560 } }
        'medium' { return [pscustomobject]@{ Cpu = 4; MemoryMB = 4096 } }
        'high'   { return [pscustomobject]@{ Cpu = 6; MemoryMB = 8192 } }
        default  { throw '无效的模拟器配置。' }
    }
}

function Set-ArtemisState([string]$Key, [string]$Value) {
    $values = Read-ArtemisKeyValues $script:ArtemisStatePath
    $values[$Key] = $Value
    [void][IO.Directory]::CreateDirectory($script:ArtemisDataRoot)
    $lines = foreach ($name in ($values.Keys | Sort-Object)) { "$name=$($values[$name])" }
    [IO.File]::WriteAllLines($script:ArtemisStatePath, [string[]]$lines, [Text.Encoding]::ASCII)
}
