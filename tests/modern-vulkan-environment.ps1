$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$project = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $project 'build\modern-vulkan-environment-tests'
[void][IO.Directory]::CreateDirectory($testRoot)
$fixture = Join-Path $testRoot ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert $rejected $Message
}
try {
    . (Join-Path $project 'stage\settings.ps1')
    Assert ($null -ne (Get-Command Get-ArtemisGraphicsEnvironment -ErrorAction SilentlyContinue)) 'Modern Vulkan launch environment has not been implemented.'
    foreach ($mode in @('host')) {
        Assert ((Get-ArtemisGraphicsEnvironment $mode (Join-Path $fixture 'missing')).Count -eq 0) 'Hardware rendering must not depend on the software provider or change its environment.'
    }
    foreach ($mode in @('auto', 'lavapipe', 'software', 'swiftshader', 'swangle')) {
        Assert-Rejected { Get-ArtemisGraphicsEnvironment $mode $fixture } 'Software rendering accepted an absent or incomplete modern provider.'
    }
    $paths = @('lib64\gles_swiftshader\libEGL.dll', 'lib64\gles_swiftshader\libGLESv2.dll', 'lib64\gles_swiftshader\vk_swiftshader.dll', 'lib64\gles_swiftshader\vk_swiftshader_icd.json', 'lib64\gles_swiftshader\vulkan-1.dll', 'lib64\gles_swiftshader\d3dcompiler_47.dll', 'lib64\vulkan\vk_swiftshader.dll', 'lib64\vulkan\vk_swiftshader_icd.json')
    foreach ($relative in $paths) {
        $path = Join-Path $fixture $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        [IO.File]::WriteAllText($path, 'test-provider', [Text.Encoding]::ASCII)
    }
    $manifest = @{schemaVersion=1;runtimeVersion='37.3.9';runtimeBuild='16863232';provider='angle-swiftshader-vulkan';glesProvider='lib64/gles_swiftshader';vulkanIcd='lib64/vulkan/vk_swiftshader_icd.json'}
    [IO.File]::WriteAllText((Join-Path $fixture 'modern-vulkan.json'), ($manifest | ConvertTo-Json), [Text.Encoding]::UTF8)
    foreach ($mode in @('auto', 'lavapipe')) {
        $environment = Get-ArtemisGraphicsEnvironment $mode $fixture
        Assert ($environment['ANGLE_DEFAULT_PLATFORM'] -ceq 'swiftshader') 'Automatic GLES fallback could select hardware ANGLE.'
        Assert (-not $environment.ContainsKey('ANDROID_EGL_ON_EGL')) 'Automatic/Lavapipe rendering forced EGL-on-EGL before the runtime selected a software GLES provider.'
        Assert (-not $environment.ContainsKey('VK_ICD_FILENAMES') -and -not $environment.ContainsKey('VK_DRIVER_FILES')) 'Automatic/Lavapipe Vulkan device selection was overridden.'
    }
    foreach ($relative in $paths) {
        $path = Join-Path $fixture $relative
        Remove-Item -LiteralPath $path
        Assert-Rejected { Get-ArtemisGraphicsEnvironment 'swangle' $fixture } "Incomplete provider was accepted: $relative"
        [IO.File]::WriteAllText($path, 'test-provider', [Text.Encoding]::ASCII)
    }
    $original = [Environment]::GetEnvironmentVariable('VK_DRIVER_FILES', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('VK_DRIVER_FILES', 'inherited-user-driver.json', 'Process')
        foreach ($mode in @('software', 'swiftshader', 'swangle')) {
            $environment = Get-ArtemisGraphicsEnvironment $mode $fixture
            Assert ($environment['ANGLE_DEFAULT_PLATFORM'] -ceq 'swiftshader') 'Software rendering could select a hardware ANGLE device.'
            Assert ($environment['ANDROID_EGL_ON_EGL'] -ceq '1') 'The ANGLE EGL provider was not selected.'
            Assert ($environment['VK_ICD_FILENAMES'] -ceq (Join-Path $fixture 'lib64\vulkan\vk_swiftshader_icd.json')) 'The software ICD escaped the installed runtime.'
            foreach ($key in @('VK_DRIVER_FILES', 'VK_ADD_DRIVER_FILES', 'VK_LOADER_DRIVERS_SELECT', 'VK_LOADER_DRIVERS_DISABLE')) {
                Assert ($environment.ContainsKey($key) -and $null -eq $environment[$key]) "Inherited driver override was not cleared: $key"
            }
        }
        Assert ([Environment]::GetEnvironmentVariable('VK_DRIVER_FILES', 'Process') -ceq 'inherited-user-driver.json') 'Reading launch policy mutated the parent environment.'
    } finally { [Environment]::SetEnvironmentVariable('VK_DRIVER_FILES', $original, 'Process') }
    $manifest.provider = 'unknown'
    [IO.File]::WriteAllText((Join-Path $fixture 'modern-vulkan.json'), ($manifest | ConvertTo-Json), [Text.Encoding]::UTF8)
    Assert-Rejected { Get-ArtemisGraphicsEnvironment 'swangle' $fixture } 'An unknown provider was accepted.'
    $manifest.provider = 'angle-swiftshader-vulkan'
    $manifest.vulkanIcd = '../external.json'
    [IO.File]::WriteAllText((Join-Path $fixture 'modern-vulkan.json'), ($manifest | ConvertTo-Json), [Text.Encoding]::UTF8)
    Assert-Rejected { Get-ArtemisGraphicsEnvironment 'swangle' $fixture } 'An external ICD path was accepted.'
    Assert ((Get-ArtemisGraphics 'software' 'auto') -ceq 'swangle') 'The software alias was not normalized to the modern backend.'
    Assert ((Get-ArtemisGraphics 'host' 'swiftshader') -ceq 'swangle') 'The software shortcut did not use the modern backend.'
    Write-Host 'Modern Vulkan environment, hardware isolation and failure guards passed.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $fixture).ProviderPath.TrimEnd('\')
    if (-not $resolved.StartsWith(([IO.Path]::GetFullPath($testRoot).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
