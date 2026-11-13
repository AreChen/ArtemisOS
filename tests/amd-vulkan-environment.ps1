$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$project = Split-Path -Parent $PSScriptRoot
$testParent = Join-Path $project 'build\amd-vulkan-environment-tests'
$fixture = Join-Path $testParent ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$checks = 0
function Assert([bool]$Condition, [string]$Message) {
    $script:checks++
    if (-not $Condition) { throw $Message }
}
function Reject([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert $rejected $Message
}
function Adapter([string]$Name, [string]$Id, [int]$Status = 0) {
    [pscustomobject]@{ Name = $Name; PNPDeviceID = $Id; ConfigManagerErrorCode = $Status }
}
try {
    foreach ($file in @('settings.ps1', 'configure.ps1')) {
        Copy-Item -LiteralPath (Join-Path $project ('stage\' + $file)) -Destination $fixture
    }
    . (Join-Path $fixture 'settings.ps1')
    $apuId = 'PCI\VEN_1002&DEV_150E&SUBSYS_01231002&REV_C1\4&123456&0&0041'
    $discreteId = 'PCI\VEN_1002&DEV_744C&SUBSYS_00001002&REV_C8\6&654321&0&0009'
    $apu = Adapter 'AMD Radeon(TM) 890M' $apuId
    $discrete = Adapter 'AMD Radeon RX 7900 XTX' $discreteId
    $intel = Adapter 'Intel Graphics' 'PCI\VEN_8086&DEV_A780'
    $nvidia = Adapter 'NVIDIA GeForce RTX 3080 Ti' 'PCI\VEN_10DE&DEV_2208'
    $disabled = Adapter 'AMD Radeon Graphics' 'PCI\VEN_1002&DEV_15BF' 22
    $candidates = @(Get-ArtemisVulkanDevices -Renderer vulkan_amd -VideoControllers @($intel, $apu, $nvidia, $disabled, $discrete))
    Assert ($candidates.Count -eq 2 -and $candidates.Id -contains $apuId -and $candidates.Id -contains $discreteId) 'AMD PCI filtering selected disabled/foreign hardware or missed an AMD adapter.'
    foreach ($name in @('AMD Radeon Graphics', 'AMD Radeon(TM) 890M', 'AMD Radeon RX 7900 XTX', 'Graphics', 'Display Adapter')) {
        $device = Adapter $name $apuId
        Assert ((Get-ArtemisSelectedVulkanDevice -Renderer vulkan_amd -VideoControllers @($intel, $device)) -ceq $name) 'AMD support depends on a model-name whitelist.'
    }
    Assert ((Get-ArtemisSelectedVulkanDevice -Renderer vulkan_amd -DeviceId $apuId -VideoControllers @($discrete, $apu, $intel)) -ceq $apu.Name) 'Selecting the integrated AMD adapter by PCI identity failed.'
    Assert ((Get-ArtemisSelectedVulkanDevice -Renderer vulkan_amd -DeviceId $discreteId -VideoControllers @($apu, $discrete)) -ceq $discrete.Name) 'Selecting the discrete AMD adapter by PCI identity failed.'
    Assert ((Get-ArtemisSelectedVulkanDevice -Renderer vulkan_intel -DeviceId $intel.PNPDeviceID -VideoControllers @($apu, $intel)) -ceq $intel.Name) 'The shared device selector broke Intel PCI selection.'
    Reject { Get-ArtemisSelectedVulkanDevice -Renderer vulkan_amd -VideoControllers @($apu, $discrete) } 'A multi-AMD host selected an arbitrary GPU without user choice.'
    foreach ($devices in @(@(), @($intel, $nvidia), @($disabled))) {
        Reject { Get-ArtemisSelectedVulkanDevice -Renderer vulkan_amd -VideoControllers $devices } 'A missing or disabled AMD adapter was accepted.'
    }
    foreach ($id in @($intel.PNPDeviceID, $disabled.PNPDeviceID, 'PCI\VEN_1002&DEV_FFFF')) {
        Reject { Get-ArtemisSelectedVulkanDevice -Renderer vulkan_amd -DeviceId $id -VideoControllers @($apu, $discrete, $intel, $disabled) } 'A foreign, disabled or stale selected PCI identity was accepted.'
    }
    $sameName = Adapter $apu.Name $discreteId
    Reject { Get-ArtemisSelectedVulkanDevice -Renderer vulkan_amd -DeviceId $apuId -VideoControllers @($apu, $sameName) } 'Two adapters with identical ANGLE names were treated as uniquely targetable.'
    foreach ($badId in @('PCI\VEN_10020&DEV_150E', 'ROOT\VEN_1002', 'PCI\VEN_10DE&DEV_150E', "PCI\VEN_1002&DEV_150E`nanything")) {
        $bad = Adapter 'AMD Radeon Graphics' $badId
        Assert (@(Get-ArtemisVulkanDevices -Renderer vulkan_amd -VideoControllers @($bad)).Count -eq 0) 'An invalid PCI identity or AMD-looking foreign adapter passed detection.'
    }
    foreach ($badName in @('', ' ', ('x' * 256), "AMD`nGraphics", 'AMD "Graphics"')) {
        $bad = Adapter $badName $apuId
        Assert (@(Get-ArtemisVulkanDevices -Renderer vulkan_amd -VideoControllers @($bad)).Count -eq 0) 'An unsafe adapter name reached the launch selector.'
    }
    Assert ((Get-ArtemisPreferences).Graphics -ceq 'host') 'AMD support changed the default renderer.'
    Write-ArtemisPreferences 'medium' '0' '1' 'unicom' 'vulkan_amd' '1080p' 'native' $apuId
    [IO.File]::AppendAllText($script:ArtemisPreferencesPath, "future_key=keep=all`n", [Text.UTF8Encoding]::new($false))
    & (Join-Path $fixture 'configure.ps1') -NoGui -SetGraphics vulkan_amd -SetGraphicsDevice $apuId
    & (Join-Path $fixture 'configure.ps1') -NoGui -SetProfile high
    $saved = Get-ArtemisPreferences
    Assert ($saved.Graphics -ceq 'vulkan_amd' -and $saved.GraphicsDevice -ceq $apuId -and $saved.Frontend -ceq 'native' -and $saved.Profile -ceq 'high' -and $saved.Resolution -ceq '1080p' -and $saved.Carrier -ceq 'unicom') 'Configuring AMD or an unrelated preference lost selected GPU or other settings.'
    Write-ArtemisPreferences 'medium' '0' '1' 'unicom' 'vulkan_amd' '1080p'
    Assert ((Get-ArtemisPreferences).GraphicsDevice -ceq $apuId -and (Get-ArtemisPreferences).Frontend -ceq 'native') 'Legacy positional configuration reset newer preferences.'
    Assert ((Read-ArtemisKeyValues $script:ArtemisPreferencesPath)['future_key'] -ceq 'keep=all') 'An unknown preference was lost.'
    & (Join-Path $fixture 'configure.ps1') -NoGui -SetGraphics vulkan_intel
    Assert ([string]::IsNullOrEmpty((Get-ArtemisPreferences).GraphicsDevice)) 'Changing GPU vendor retained the old vendor PCI identity.'
    Assert ((Get-ArtemisGraphics 'vulkan_amd' 'auto') -ceq 'vulkan_amd') 'AMD normal launch changed renderer.'
    Assert ((Get-ArtemisGraphics 'vulkan_amd' 'swiftshader') -ceq 'swangle') 'The explicit software shortcut did not override AMD hardware mode.'
    $runtime = Get-ArtemisGraphicsRuntime 'vulkan_amd'
    Assert ($runtime.GpuMode -ceq 'swiftshader' -and $runtime.DisabledFeatures -contains 'Vulkan') 'AMD did not use the existing ANGLE GLES hardware profile.'
    foreach ($relative in @('lib64\gles_swiftshader\libEGL.dll', 'lib64\gles_swiftshader\libGLESv2.dll', 'lib64\gles_swiftshader\vk_swiftshader.dll', 'lib64\gles_swiftshader\vk_swiftshader_icd.json', 'lib64\gles_swiftshader\vulkan-1.dll', 'lib64\gles_swiftshader\d3dcompiler_47.dll', 'lib64\vulkan\vk_swiftshader.dll', 'lib64\vulkan\vk_swiftshader_icd.json')) {
        $path = Join-Path $fixture $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        [IO.File]::WriteAllText($path, 'fixture', [Text.Encoding]::ASCII)
    }
    $manifest = @{schemaVersion=1;runtimeVersion='37.3.9';runtimeBuild='16863232';provider='angle-swiftshader-vulkan';glesProvider='lib64/gles_swiftshader';vulkanIcd='lib64/vulkan/vk_swiftshader_icd.json'}
    [IO.File]::WriteAllText((Join-Path $fixture 'modern-vulkan.json'), ($manifest | ConvertTo-Json), [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $fixture 'source.properties'), "Pkg.Revision=37.3.9`nPkg.BuildId=16863232`n", [Text.Encoding]::ASCII)
    $oldPreferred = [Environment]::GetEnvironmentVariable('ANGLE_PREFERRED_DEVICE', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('ANGLE_PREFERRED_DEVICE', 'inherited foreign adapter', 'Process')
        $environment = Get-ArtemisGraphicsEnvironment 'vulkan_amd' $fixture $apu.Name
        Assert ($environment['ANGLE_DEFAULT_PLATFORM'] -ceq 'vulkan' -and $environment['ANGLE_PREFERRED_DEVICE'] -ceq $apu.Name -and $environment['ANDROID_EGL_ON_EGL'] -ceq '1') 'AMD hardware Vulkan environment omitted its selected device.'
        foreach ($key in @('VK_ICD_FILENAMES', 'VK_DRIVER_FILES', 'VK_ADD_DRIVER_FILES', 'VK_LOADER_DRIVERS_SELECT', 'VK_LOADER_DRIVERS_DISABLE', 'ANDROID_GL_SOFTWARE_RENDERER')) {
            Assert ($environment.ContainsKey($key) -and $null -eq $environment[$key]) 'A software Vulkan override leaked into the AMD hardware process.'
        }
        Assert ([Environment]::GetEnvironmentVariable('ANGLE_PREFERRED_DEVICE', 'Process') -ceq 'inherited foreign adapter') 'Building the AMD environment changed the parent process.'
        $software = Get-ArtemisGraphicsEnvironment 'swangle' $fixture
        Assert ($null -eq $software['ANGLE_PREFERRED_DEVICE']) 'The software override retained AMD device affinity.'
        Reject { Get-ArtemisGraphicsEnvironment 'vulkan_amd' $fixture } 'AMD mode accepted a missing exact GPU name.'
    } finally { [Environment]::SetEnvironmentVariable('ANGLE_PREFERRED_DEVICE', $oldPreferred, 'Process') }
    foreach ($device in @($apu, $discrete)) {
        $surface = "GLES: Google, Android Emulator OpenGL ES Translator (ANGLE (AMD, Vulkan 1.3.280 ($($device.Name) (0x0000150E)))), OpenGL ES 3.1"
        Assert ((Assert-ArtemisHardwareVulkanRenderer $surface $device.Name) -ceq $surface) 'A matching AMD Vulkan renderer was rejected.'
    }
    Reject { Assert-ArtemisHardwareVulkanRenderer 'GLES: ANGLE (NVIDIA, Vulkan 1.3.0 (NVIDIA GeForce RTX 3080 Ti))' $apu.Name } 'A foreign GPU passed selected-AMD verification.'
    Reject { Assert-ArtemisHardwareVulkanRenderer 'GLES: ANGLE (AMD, Vulkan 1.3.0 (AMD Radeon RX 7900 XTX))' 'AMD Radeon RX 7900' } 'A device-name substring passed exact verification.'
    Reject { Assert-ArtemisHardwareVulkanRenderer 'GLES: ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (Subzero)))' $apu.Name } 'A CPU fallback passed AMD hardware verification.'
    Write-Output "PASS: $checks AMD PCI selection, multi-GPU affinity, preferences, runtime policy and exact renderer checks. Synthetic adapters only; AMD hardware execution remains unverified."
} finally {
    $resolved = (Resolve-Path -LiteralPath $fixture).ProviderPath.TrimEnd('\')
    if (-not $resolved.StartsWith(([IO.Path]::GetFullPath($testParent).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
