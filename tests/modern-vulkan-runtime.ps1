param([string]$SourceEmulator = (Join-Path $PSScriptRoot '..\stage\sdk\emulator'))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$project = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath.TrimEnd('\')
$builder = Join-Path $project 'tools\Prepare-ModernVulkanRuntime.ps1'
$source = (Resolve-Path -LiteralPath $SourceEmulator).ProviderPath.TrimEnd('\')
$parent = Join-Path $project 'build\modern-vulkan-runtime-tests'
[void][IO.Directory]::CreateDirectory($parent)
$fixture = Join-Path $parent ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Hash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Assert-Rejected([string]$InputRoot, [string]$Destination, [string]$ExpectedMessage) {
    $rejected = $false
    try { & $builder -SourceEmulator $InputRoot -Output $Destination | Out-Null }
    catch {
        $rejected = $true
        Assert ($_.Exception.Message -match $ExpectedMessage) ("Wrong rejection: " + $_.Exception.Message)
    }
    Assert $rejected "Unsafe or unsupported invocation accepted: $Destination"
}

try {
    Assert (Test-Path -LiteralPath $builder -PathType Leaf) 'Modern Vulkan runtime preparation is not implemented.'
    $oldPaths = @('lib64\gles_swiftshader\libGLESv2.dll', 'lib64\gles_swiftshader\libEGL.dll',
        'lib64\gles_swiftshader\libGLES_CM.dll', 'lib64\vulkan\vk_swiftshader.dll',
        'lib64\vulkan\vk_swiftshader_icd.json', 'source.properties')
    $before = @{}
    foreach ($relative in $oldPaths) { $before[$relative] = Hash (Join-Path $source $relative) }
    $output = Join-Path $fixture 'runtime'
    & $builder -SourceEmulator $source -Output $output

    $metadata = Get-Content -LiteralPath (Join-Path $output 'modern-vulkan.json') -Raw | ConvertFrom-Json
    Assert ($metadata.schemaVersion -eq 1 -and $metadata.runtimeVersion -ceq '37.3.9' -and
        $metadata.runtimeBuild -ceq '16863232' -and $metadata.provider -ceq 'angle-swiftshader-vulkan') 'Invalid runtime identity.'
    $angleVersion = (Get-Item -LiteralPath (Join-Path $source 'lib64\gles_angle\libGLESv2.dll')).VersionInfo.FileVersion
    Assert ($metadata.angleVersion -ceq $angleVersion) 'ANGLE version did not come from the source DLL.'
    Assert ($metadata.glesProvider -ceq 'lib64/gles_swiftshader' -and
        $metadata.vulkanIcd -ceq 'lib64/vulkan/vk_swiftshader_icd.json') 'Invalid provider paths.'

    $names = @('d3dcompiler_47.dll', 'libEGL.dll', 'libGLESv2.dll', 'vk_swiftshader_icd.json',
        'vk_swiftshader.dll', 'vulkan-1.dll')
    $expected = @{}
    foreach ($name in $names) { $expected['lib64/gles_swiftshader/' + $name] = 'lib64/gles_angle/' + $name }
    foreach ($name in @('vk_swiftshader.dll', 'vk_swiftshader_icd.json')) {
        $expected['lib64/vulkan/' + $name] = 'lib64/gles_angle/' + $name
    }
    Assert (@($metadata.files).Count -eq 8) 'Expected exactly eight provider mappings.'
    $seen = @{}
    foreach ($file in $metadata.files) {
        Assert ($expected.ContainsKey([string]$file.path) -and -not $seen.ContainsKey([string]$file.path)) 'Unexpected or duplicate provider mapping.'
        $seen[[string]$file.path] = $true
        Assert ($file.sourcePath -ceq $expected[[string]$file.path]) 'Provider source path is incorrect.'
        $sourceHash = Hash (Join-Path $source $file.sourcePath.Replace('/', '\'))
        Assert ($file.sha256 -ceq $sourceHash -and
            (Hash (Join-Path $output $file.path.Replace('/', '\'))) -ceq $sourceHash) 'Provider is not byte-for-byte identical to official ANGLE input.'
    }
    Assert (-not (Test-Path -LiteralPath (Join-Path $output 'lib64\gles_swiftshader\libGLES_CM.dll'))) 'Legacy GLES_CM leaked into the modern provider.'
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $output 'lib64\gles_swiftshader') -File).Count -eq 6) 'Unexpected files in the modern GLES provider.'
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $output 'qemu\windows-x86_64') -File |
        Where-Object Name -Match '^qemu-system-(aarch64|armel|i386)(-headless)?\.exe$').Count -eq 6) 'Slim SDK preparation still needs all six optional QEMU inputs.'
    Assert ((Hash (Join-Path $output 'emulator.exe')) -ceq (Hash (Join-Path $source 'emulator.exe'))) 'Official emulator launcher changed.'
    Assert ((Hash (Join-Path $output 'lib64\vulkan\vulkan-1.dll')) -ceq
        (Hash (Join-Path $source 'lib64\vulkan\vulkan-1.dll'))) 'Unmapped official Vulkan loader changed.'
    $notice = Get-Content -LiteralPath (Join-Path $output 'ARTEMIS-GRAPHICS-NOTICE.txt') -Raw
    Assert ($notice -match 'ANGLE_DEFAULT_PLATFORM=swiftshader' -and $notice -match 'ANDROID_EGL_ON_EGL=1' -and
        $notice -match 'VK_ICD_FILENAMES' -and $notice -match 'QEMU') 'Runtime notice is missing loader requirements or provenance.'
    foreach ($relative in $oldPaths) {
        Assert ((Hash (Join-Path $source $relative)) -ceq $before[$relative]) "Official source changed: $relative"
    }

    $originalManifest = Hash (Join-Path $output 'modern-vulkan.json')
    Assert-Rejected $source $output 'already exists'
    Assert ((Hash (Join-Path $output 'modern-vulkan.json')) -ceq $originalManifest) 'Repeated output was modified before rejection.'
    $outside = Join-Path $project ('modern-vulkan-forbidden-' + [Guid]::NewGuid().ToString('N'))
    Assert-Rejected $source $outside 'inside.*build'
    Assert (-not (Test-Path -LiteralPath $outside)) 'Out-of-bounds output was created.'
    Assert-Rejected $source $source 'inside.*build|already exists|overlap'
    $wrong = Join-Path $fixture 'wrong-version'
    [void][IO.Directory]::CreateDirectory($wrong)
    [IO.File]::WriteAllText((Join-Path $wrong 'source.properties'), "Pkg.Revision=37.3.6`nPkg.BuildId=16696583`n", [Text.Encoding]::ASCII)
    $wrongOutput = Join-Path $fixture 'wrong-version-output'
    Assert-Rejected $wrong $wrongOutput '37\.3\.9.*16863232'
    Assert (-not (Test-Path -LiteralPath $wrongOutput)) 'Unsupported version wrote an output directory.'
    Write-Host 'PASS: modern Vulkan provider mappings, immutable official input, manifest, and output guards.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $fixture).ProviderPath.TrimEnd('\')
    if (-not $resolved.StartsWith($parent + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup target.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
