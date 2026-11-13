$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$project = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $project 'build\hardware-vulkan-environment-tests'
$fixture = Join-Path $testRoot ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Rejected([scriptblock]$Action,[string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert $rejected $Message
}
try {
    # These exercise real preference/configuration behavior, not source-text matching.
    Copy-Item -LiteralPath (Join-Path $project 'stage\settings.ps1') -Destination $fixture
    Copy-Item -LiteralPath (Join-Path $project 'stage\configure.ps1') -Destination $fixture
    . (Join-Path $fixture 'settings.ps1')
    Assert ((Get-ArtemisPreferences).Graphics -ceq 'host') 'The existing hardware default changed.'
    Write-ArtemisPreferences 'medium' '0' '1' 'unicom' 'host' '1080p'
    & (Join-Path $fixture 'configure.ps1') -NoGui -SetGraphics vulkan
    $saved = Get-ArtemisPreferences
    Assert ($saved.Graphics -ceq 'vulkan' -and $saved.Profile -ceq 'medium' -and $saved.Cleanup -ceq '0' -and
        $saved.Carrier -ceq 'unicom' -and $saved.VideoCompat -ceq '1' -and $saved.Resolution -ceq '1080p') 'Selecting Vulkan lost the new mode or another preference.'
    Assert ((Get-ArtemisGraphics $saved.Graphics 'auto') -ceq 'vulkan') 'Hardware Vulkan was confused with host OpenGL or CPU rendering.'
    Assert ((Get-ArtemisGraphics $saved.Graphics 'swiftshader') -ceq 'swangle') 'The software shortcut no longer overrides a Vulkan preference.'
    Assert ((Get-ArtemisPreferences).Graphics -ceq 'vulkan') 'A one-time shortcut modified the saved preference.'
    $runtime = Get-ArtemisGraphicsRuntime $saved.Graphics
    Assert ($runtime.GpuMode -ceq 'swiftshader' -and $runtime.DisabledFeatures -contains 'Vulkan') 'Hardware ANGLE must use ES shaders and prevent guest Vulkan from overriding its GPU ICD.'
    foreach ($mode in @('host','auto','swangle','lavapipe','swiftshader')) {
        $runtime = Get-ArtemisGraphicsRuntime $mode
        Assert ($runtime.GpuMode -ceq $mode -and $runtime.DisabledFeatures.Count -eq 0) "The existing $mode runtime policy changed."
    }
    Assert-Rejected { Get-ArtemisGraphicsEnvironment 'vulkan' $fixture } 'Missing modern providers were accepted.'

    $providerFiles = @('lib64\gles_swiftshader\libEGL.dll','lib64\gles_swiftshader\libGLESv2.dll',
        'lib64\gles_swiftshader\vk_swiftshader.dll','lib64\gles_swiftshader\vk_swiftshader_icd.json',
        'lib64\gles_swiftshader\vulkan-1.dll','lib64\gles_swiftshader\d3dcompiler_47.dll',
        'lib64\vulkan\vk_swiftshader.dll','lib64\vulkan\vk_swiftshader_icd.json')
    foreach ($relative in $providerFiles) {
        $path = Join-Path $fixture $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        [IO.File]::WriteAllText($path,'fixture-provider',[Text.Encoding]::ASCII)
    }
    $manifest = @{schemaVersion=1;runtimeVersion='37.3.9';runtimeBuild='16863232';provider='angle-swiftshader-vulkan';glesProvider='lib64/gles_swiftshader';vulkanIcd='lib64/vulkan/vk_swiftshader_icd.json'}
    [IO.File]::WriteAllText((Join-Path $fixture 'modern-vulkan.json'),($manifest | ConvertTo-Json),[Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $fixture 'source.properties'),"Pkg.Revision=37.3.9`nPkg.BuildId=16863232`n",[Text.Encoding]::ASCII)
    $original = [Environment]::GetEnvironmentVariable('VK_DRIVER_FILES','Process')
    try {
        [Environment]::SetEnvironmentVariable('VK_DRIVER_FILES','inherited-swiftshader.json','Process')
        $environment = Get-ArtemisGraphicsEnvironment 'vulkan' $fixture
        Assert ($environment['VK_LOADER_LAYERS_DISABLE'] -eq '~implicit~') 'Implicit overlays were not isolated before ANGLE loads.'
        foreach ($key in @('VK_LOADER_LAYERS_ALLOW','VK_LOADER_LAYERS_ENABLE','VK_INSTANCE_LAYERS')) {
            Assert ($environment.ContainsKey($key) -and $null -eq $environment[$key]) "Inherited overlay override $key was not cleared."
        }
        foreach ($key in @('DISABLE_VULKAN_OW_OVERLAY_LAYER','DISABLE_VULKAN_OW_OBS_CAPTURE','DISABLE_VULKAN_OBS_CAPTURE')) {
            Assert ($environment[$key] -eq '1') "Overlay opt-out $key was not applied to the child."
        }
        Assert ($environment['ANGLE_DEFAULT_PLATFORM'] -ceq 'vulkan' -and $environment['ANDROID_EGL_ON_EGL'] -ceq '1') 'ANGLE hardware Vulkan was not selected.'
        foreach ($key in @('VK_ICD_FILENAMES','VK_DRIVER_FILES','VK_ADD_DRIVER_FILES','VK_LOADER_DRIVERS_SELECT','VK_LOADER_DRIVERS_DISABLE','ANDROID_GL_SOFTWARE_RENDERER')) {
            Assert ($environment.ContainsKey($key) -and $null -eq $environment[$key]) "A software driver override could leak into hardware mode: $key"
        }
        Assert ([Environment]::GetEnvironmentVariable('VK_DRIVER_FILES','Process') -ceq 'inherited-swiftshader.json') 'Building child policy mutated the parent environment.'
        Assert ((Get-ArtemisGraphicsEnvironment 'host' (Join-Path $fixture 'absent')).Count -eq 0) 'Original host OpenGL now depends on the Vulkan adaptation.'
    } finally { [Environment]::SetEnvironmentVariable('VK_DRIVER_FILES',$original,'Process') }
    Remove-Item -LiteralPath (Join-Path $fixture $providerFiles[0])
    Assert-Rejected { Get-ArtemisGraphicsEnvironment 'vulkan' $fixture } 'An incomplete EGL provider was accepted.'
    [IO.File]::WriteAllText((Join-Path $fixture $providerFiles[0]),'fixture-provider',[Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $fixture 'source.properties'),"Pkg.Revision=37.3.6`nPkg.BuildId=16696583`n",[Text.Encoding]::ASCII)
    Assert-Rejected { Get-ArtemisGraphicsEnvironment 'vulkan' $fixture } 'An unvalidated runtime version was accepted.'

    # A successful launch must be identifiable as hardware Vulkan, not merely as ANGLE/Vulkan.
    foreach ($device in @('NVIDIA GeForce RTX 3080 Ti','NVIDIA RTX 6000 Ada Generation','Quadro RTX 4000','Intel Graphics','Intel(R) Arc(TM) Graphics','Intel(R) Iris(R) Xe Graphics','AMD Radeon Graphics','AMD Radeon(TM) 890M')) {
        $surface = "GLES: Google, Android Emulator OpenGL ES Translator (ANGLE ($device, Vulkan 1.3.0 ($device))), OpenGL ES 3.1"
        Assert ((Assert-ArtemisHardwareVulkanRenderer $surface) -ceq $surface) 'A hardware renderer report was rejected.'
    }
    foreach ($bad in @('', 'GLES: NVIDIA OpenGL 4.6', 'GLES: ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (Subzero)))',
        'GLES: ANGLE (Mesa, Vulkan 1.3.0 (llvmpipe))', 'GLES: ANGLE (Mesa, Vulkan 1.3.0 (lavapipe))', 'GLES: ANGLE (Generic, Vulkan 1.3.0 (CPU device))')) {
        Assert-Rejected { Assert-ArtemisHardwareVulkanRenderer $bad } "A missing or nonhardware renderer passed: $bad"
    }
    # A failed hardware startup must only stop the instance owned by its launcher.
    $owner = [pscustomobject]@{ProcessId=123;ExecutablePath=(Join-Path $fixture 'sdk\emulator\emulator.exe');CommandLine='emulator.exe -avd ArtemisOS_15 -gpu host -port 5554'}
    Assert (Test-ArtemisEmulatorOwnership $owner $fixture 123 'emulator-5554') 'The matching launcher was not recognized.'
    foreach ($badSerial in @('emulator-55540','other-5554','emulator-5555')) {
        Assert (-not (Test-ArtemisEmulatorOwnership $owner $fixture 123 $badSerial)) 'A different serial could stop this instance.'
    }
    Assert (-not (Test-ArtemisEmulatorOwnership $owner $fixture 124 'emulator-5554')) 'A different PID could stop this instance.'
    Assert (-not (Test-ArtemisEmulatorOwnership $owner $fixture 0 'emulator-5554')) 'An unspecified PID could stop this instance.'
    $owner.ExecutablePath = Join-Path $testRoot 'another\sdk\emulator\emulator.exe'
    Assert (-not (Test-ArtemisEmulatorOwnership $owner $fixture 123 'emulator-5554')) 'Another installation could stop this instance.'
    Assert (-not (Test-ArtemisEmulatorOwnership $null $fixture 123 'emulator-5554')) 'An absent process was accepted.'
    Write-Host 'Hardware Vulkan preferences, software isolation, provider guards, renderer validation and shutdown ownership passed.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $fixture).ProviderPath.TrimEnd('\')
    if (-not $resolved.StartsWith(([IO.Path]::GetFullPath($testRoot).TrimEnd('\') + '\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
