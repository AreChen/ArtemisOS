$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$project = Split-Path -Parent $PSScriptRoot
$parent = Join-Path $project 'build\intel-vulkan-environment-tests'
$fixture = Join-Path $parent ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Rejected([scriptblock]$Action,[string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert $rejected $Message
}
try {
    Copy-Item -LiteralPath (Join-Path $project 'stage\settings.ps1') -Destination $fixture
    Copy-Item -LiteralPath (Join-Path $project 'stage\configure.ps1') -Destination $fixture
    . (Join-Path $fixture 'settings.ps1')
    Assert ((Get-ArtemisPreferences).Graphics -ceq 'host') 'The default changed without user selection.'
    Write-ArtemisPreferences 'medium' '0' '1' 'unicom' 'vulkan_intel' '1080p'
    & (Join-Path $fixture 'configure.ps1') -NoGui -SetGraphics vulkan_intel
    $saved = Get-ArtemisPreferences
    Assert ($saved.Graphics -ceq 'vulkan_intel' -and $saved.Profile -ceq 'medium' -and $saved.Cleanup -ceq '0' -and
        $saved.Carrier -ceq 'unicom' -and $saved.Resolution -ceq '1080p') 'Intel selection lost itself or another preference.'
    Assert ((Get-ArtemisGraphics 'vulkan_intel' 'auto') -ceq 'vulkan_intel') 'Normal launch lost the Intel selection.'
    Assert ((Get-ArtemisGraphics 'vulkan_intel' 'swiftshader') -ceq 'swangle') 'Software shortcut failed to override Intel.'
    $runtime = Get-ArtemisGraphicsRuntime 'vulkan_intel'
    Assert ($runtime.GpuMode -ceq 'swiftshader' -and $runtime.DisabledFeatures -contains 'Vulkan') 'Intel must use the existing ANGLE ES profile.'

    $intelName = 'Intel(R) UHD Graphics 770'
    $intel = [pscustomobject]@{Name=$intelName;PNPDeviceID='PCI\VEN_8086&DEV_A780';ConfigManagerErrorCode=0}
    $nvidia = [pscustomobject]@{Name='NVIDIA GeForce RTX 3080 Ti';PNPDeviceID='PCI\VEN_10DE&DEV_2208';ConfigManagerErrorCode=0}
    $disabled = [pscustomobject]@{Name='Intel(R) Iris(R) Xe Graphics';PNPDeviceID='PCI\VEN_8086&DEV_1234';ConfigManagerErrorCode=22}
    Assert ((Get-ArtemisIntelVulkanDevice -VideoControllers @($nvidia,$disabled,$intel)) -ceq $intelName) 'Enabled Intel selection failed on a multi-adapter host.'
    Assert ((Get-ArtemisIntelVulkanDevice -VideoControllers @($intel,$intel)) -ceq $intelName) 'Duplicate descriptions were treated as different devices.'
    Assert-Rejected { Get-ArtemisIntelVulkanDevice -VideoControllers @($nvidia,$disabled) } 'No enabled Intel adapter was accepted.'
    Assert-Rejected { Get-ArtemisIntelVulkanDevice -VideoControllers @() } 'An empty device list was accepted.'
    $otherIntel = [pscustomobject]@{Name='Intel(R) Iris(R) Xe Graphics';PNPDeviceID='PCI\VEN_8086&DEV_1234';ConfigManagerErrorCode=0}
    Assert-Rejected { Get-ArtemisIntelVulkanDevice -VideoControllers @($intel,$otherIntel) } 'An ambiguous Intel choice was silently made.'
    $fakeVendor = [pscustomobject]@{Name=$intelName;PNPDeviceID='PCI\VEN_10DE&DEV_2208';ConfigManagerErrorCode=0}
    Assert-Rejected { Get-ArtemisIntelVulkanDevice -VideoControllers @($fakeVendor) } 'An Intel-looking name from another vendor was accepted.'
    foreach ($name in @('Intel Graphics','Intel(R) Graphics','Intel(R) Arc(TM) Graphics','Intel(R) Arc(TM) 140V GPU','Display Adapter')) {
        $adapter = [pscustomobject]@{Name=$name;PNPDeviceID='PCI\VEN_8086&DEV_1234';ConfigManagerErrorCode=0}
        Assert ((Get-ArtemisIntelVulkanDevice -VideoControllers @($nvidia,$adapter)) -ceq $name) "Intel PCI adapter rejected because of its display name: $name"
    }
    $arc = [pscustomobject]@{Name='Intel(R) Arc(TM) A770 Graphics';PNPDeviceID='PCI\VEN_8086&DEV_56A0';ConfigManagerErrorCode=0}
    Assert ((Get-ArtemisIntelVulkanDevice -VideoControllers @($arc)) -ceq $arc.Name) 'Intel selection incorrectly claims to distinguish integrated and discrete adapters by name.'
    foreach ($badName in @('', ' ', ('x'*256), "Intel`nGraphics", 'Intel "Graphics"')) {
        $bad = [pscustomobject]@{Name=$badName;PNPDeviceID='PCI\VEN_8086&DEV_1234';ConfigManagerErrorCode=0}
        Assert-Rejected { Get-ArtemisIntelVulkanDevice -VideoControllers @($bad) } 'An unsafe or empty adapter name was accepted.'
    }
    foreach ($badId in @('PCI\VEN_80860&DEV_1234','ROOT\VEN_8086','PCI\VEN_10DE&DEV_1234','PCI\VEN_1002&DEV_1234')) {
        $bad = [pscustomobject]@{Name='Intel Graphics';PNPDeviceID=$badId;ConfigManagerErrorCode=0}
        Assert-Rejected { Get-ArtemisIntelVulkanDevice -VideoControllers @($bad) } 'A display name bypassed the Intel PCI vendor requirement.'
    }
    $disabledModern = [pscustomobject]@{Name='Intel Graphics';PNPDeviceID='PCI\VEN_8086&DEV_1234';ConfigManagerErrorCode=22}
    Assert-Rejected { Get-ArtemisIntelVulkanDevice -VideoControllers @($disabledModern) } 'A disabled modern Intel adapter was selected.'

    foreach ($relative in @('lib64\gles_swiftshader\libEGL.dll','lib64\gles_swiftshader\libGLESv2.dll',
        'lib64\gles_swiftshader\vk_swiftshader.dll','lib64\gles_swiftshader\vk_swiftshader_icd.json',
        'lib64\gles_swiftshader\vulkan-1.dll','lib64\gles_swiftshader\d3dcompiler_47.dll',
        'lib64\vulkan\vk_swiftshader.dll','lib64\vulkan\vk_swiftshader_icd.json')) {
        $path = Join-Path $fixture $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        [IO.File]::WriteAllText($path,'fixture',[Text.Encoding]::ASCII)
    }
    $manifest = @{schemaVersion=1;runtimeVersion='37.3.9';runtimeBuild='16863232';provider='angle-swiftshader-vulkan';glesProvider='lib64/gles_swiftshader';vulkanIcd='lib64/vulkan/vk_swiftshader_icd.json'}
    [IO.File]::WriteAllText((Join-Path $fixture 'modern-vulkan.json'),($manifest | ConvertTo-Json),[Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $fixture 'source.properties'),"Pkg.Revision=37.3.9`nPkg.BuildId=16863232`n",[Text.Encoding]::ASCII)
    $inherited = [Environment]::GetEnvironmentVariable('ANGLE_PREFERRED_DEVICE','Process')
    try {
        [Environment]::SetEnvironmentVariable('ANGLE_PREFERRED_DEVICE','inherited GPU','Process')
        $environment = Get-ArtemisGraphicsEnvironment 'vulkan_intel' $fixture $intelName
        Assert ($environment['ANGLE_PREFERRED_DEVICE'] -ceq $intelName -and $environment['ANGLE_DEFAULT_PLATFORM'] -ceq 'vulkan' -and
            $environment['ANDROID_EGL_ON_EGL'] -ceq '1') 'Intel Vulkan environment is incomplete.'
        Assert ($null -eq $environment['VK_DRIVER_FILES'] -and $null -eq $environment['VK_ICD_FILENAMES']) 'Intel mode relies on driver-file overrides ignored by elevated Windows processes.'
        Assert ([Environment]::GetEnvironmentVariable('ANGLE_PREFERRED_DEVICE','Process') -ceq 'inherited GPU') 'Creating policy mutated the parent process.'
        foreach ($mode in @('vulkan','swangle','auto','lavapipe')) {
            $other = Get-ArtemisGraphicsEnvironment $mode $fixture
            Assert ($other.ContainsKey('ANGLE_PREFERRED_DEVICE') -and $null -eq $other['ANGLE_PREFERRED_DEVICE']) "Inherited preferred device leaked into $mode."
        }
        Assert-Rejected { Get-ArtemisGraphicsEnvironment 'vulkan_intel' $fixture } 'Intel mode accepted a missing exact device name.'
        foreach ($name in @('Intel Graphics','Intel(R) Graphics','Intel(R) Arc(TM) 140V GPU','Display Adapter')) {
            # Vendor identity belongs to PCI detection; the selected display name is opaque here.
            $selected = Get-ArtemisGraphicsEnvironment 'vulkan_intel' $fixture $name
            Assert ($selected['ANGLE_PREFERRED_DEVICE'] -ceq $name) 'The exact selected name did not reach ANGLE.'
            $report = "GLES: ANGLE (Intel, Vulkan 1.3.0 ($name)), OpenGL ES 3.0"
            Assert ((Assert-ArtemisHardwareVulkanRenderer $report $name) -ceq $report) 'A modern Intel renderer name was rejected after boot.'
        }
        foreach ($badName in @('', ' ', ('x'*256), "Intel`rGraphics", 'Intel "Graphics"')) {
            Assert-Rejected { Get-ArtemisGraphicsEnvironment 'vulkan_intel' $fixture $badName } 'An unsafe preferred device was accepted.'
        }
    } finally { [Environment]::SetEnvironmentVariable('ANGLE_PREFERRED_DEVICE',$inherited,'Process') }

    $surface = 'GLES: Google (Google Inc. (Intel)), Android Emulator OpenGL ES Translator (ANGLE (Intel, Vulkan 1.4.323 (Intel(R) UHD Graphics 770 (0x0000A780)), Intel Corporation-101.7088)), OpenGL ES 3.0'
    Assert ((Assert-ArtemisHardwareVulkanRenderer $surface $intelName) -ceq $surface) 'The verified Intel renderer was rejected.'
    Assert-Rejected { Assert-ArtemisHardwareVulkanRenderer $surface 'Intel(R) UHD Graphics 77' } 'A device-name substring passed exact verification.'
    Assert-Rejected { Assert-ArtemisHardwareVulkanRenderer 'GLES: ANGLE (NVIDIA, Vulkan 1.3.0 (NVIDIA GeForce RTX 3080 Ti))' $intelName } 'A different hardware GPU was accepted as Intel.'
    Assert-Rejected { Assert-ArtemisHardwareVulkanRenderer 'GLES: ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (Subzero)))' $intelName } 'A CPU fallback was accepted as Intel.'
    Write-Host 'PASS: Intel preferences, device detection, exact renderer verification, environment isolation and software override.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $fixture).ProviderPath.TrimEnd('\')
    if (-not $resolved.StartsWith(([IO.Path]::GetFullPath($parent).TrimEnd('\') + '\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
