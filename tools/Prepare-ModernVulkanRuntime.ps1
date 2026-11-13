param(
    [Parameter(Mandatory = $true)][string]$SourceEmulator,
    [Parameter(Mandatory = $true)][string]$Output
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$workspace = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath.TrimEnd('\')
$buildRoot = [IO.Path]::GetFullPath((Join-Path $workspace 'build')).TrimEnd('\')
$destination = [IO.Path]::GetFullPath($Output).TrimEnd('\')
if (-not $destination.StartsWith($buildRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The output must be a new directory inside this project build directory.'
}
if (Test-Path -LiteralPath $destination) { throw "Output already exists: $destination" }

function Assert-RegularAncestors([string]$Path) {
    $current = $Path
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $entry = Get-Item -LiteralPath $current -Force
            if (-not $entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Runtime paths cannot traverse files or reparse points: $current"
            }
        }
        $next = [IO.Path]::GetDirectoryName($current.TrimEnd('\'))
        if (-not $next -or $next -eq $current) { break }
        $current = $next
    }
}

$source = (Resolve-Path -LiteralPath $SourceEmulator).ProviderPath.TrimEnd('\')
Assert-RegularAncestors $source
Assert-RegularAncestors (Split-Path -Parent $destination)
if ($destination.StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $source.StartsWith($destination + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Source and output runtime directories must not overlap.'
}
if ([IO.Path]::GetPathRoot($source) -ne [IO.Path]::GetPathRoot($destination)) {
    throw 'Source and output must be on the same volume because unchanged files use hard links.'
}
$propertiesPath = Join-Path $source 'source.properties'
$properties = if (Test-Path -LiteralPath $propertiesPath -PathType Leaf) { [IO.File]::ReadAllText($propertiesPath) } else { '' }
if ([regex]::Matches($properties, '(?m)^Pkg\.Revision=37\.3\.9\s*$').Count -ne 1 -or
    [regex]::Matches($properties, '(?m)^Pkg\.BuildId=16863232\s*$').Count -ne 1 -or
    [regex]::Matches($properties, '(?m)^Pkg\.Revision=').Count -ne 1 -or
    [regex]::Matches($properties, '(?m)^Pkg\.BuildId=').Count -ne 1) {
    throw 'This adapter requires official Android Emulator 37.3.9, build 16863232.'
}
foreach ($generated in @('modern-vulkan.json', 'ARTEMIS-GRAPHICS-NOTICE.txt')) {
    if (Test-Path -LiteralPath (Join-Path $source $generated)) { throw 'Use an unmodified official runtime as the source, not an adapted output.' }
}
$providerNames = @('d3dcompiler_47.dll', 'libEGL.dll', 'libGLESv2.dll',
    'vk_swiftshader_icd.json', 'vk_swiftshader.dll', 'vulkan-1.dll')
foreach ($relative in @('emulator.exe', 'qemu\windows-x86_64\qemu-system-x86_64.exe',
    'qemu\windows-x86_64\qemu-system-x86_64-headless.exe') + @($providerNames | ForEach-Object { 'lib64\gles_angle\' + $_ })) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $relative) -PathType Leaf)) { throw "Missing official runtime input: $relative" }
}
$allEntries = @(Get-ChildItem -LiteralPath $source -Recurse -Force)
if (@($allEntries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
    throw 'The source runtime cannot contain reparse points.'
}
$sourceFiles = @($allEntries | Where-Object { -not $_.PSIsContainer })
$unused = @($sourceFiles | Where-Object {
    $_.FullName.Substring($source.Length).TrimStart('\') -match '^qemu\\windows-x86_64\\qemu-system-(aarch64|armel|i386)(-headless)?\.exe$'
})
if ($unused.Count -ne 6) { throw 'Use the complete official runtime; all six optional QEMU executables are required as packaging inputs.' }
$angleVersion = (Get-Item -LiteralPath (Join-Path $source 'lib64\gles_angle\libGLESv2.dll')).VersionInfo.FileVersion
if ([string]::IsNullOrWhiteSpace($angleVersion)) { throw 'The ANGLE DLL has no version resource.' }

$mappings = @(
    foreach ($name in $providerNames) { [pscustomobject]@{ path=('lib64/gles_swiftshader/' + $name); sourcePath=('lib64/gles_angle/' + $name) } }
    foreach ($name in @('vk_swiftshader.dll', 'vk_swiftshader_icd.json')) { [pscustomobject]@{ path=('lib64/vulkan/' + $name); sourcePath=('lib64/gles_angle/' + $name) } }
)
$providerHashes = @{}
foreach ($mapping in $mappings) {
    if (-not $providerHashes.ContainsKey($mapping.sourcePath)) {
        $providerHashes[$mapping.sourcePath] = (Get-FileHash -LiteralPath (Join-Path $source $mapping.sourcePath.Replace('/', '\')) -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

[void][IO.Directory]::CreateDirectory($destination)
$linked = 0
foreach ($file in $sourceFiles) {
    $relative = $file.FullName.Substring($source.Length).TrimStart('\')
    if ($relative.StartsWith('lib64\gles_swiftshader\', [StringComparison]::OrdinalIgnoreCase) -or
        $relative -in @('lib64\vulkan\vk_swiftshader.dll', 'lib64\vulkan\vk_swiftshader_icd.json')) { continue }
    $target = Join-Path $destination $relative
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
    [void](New-Item -ItemType HardLink -Path $target -Target $file.FullName)
    $linked++
}
$manifestFiles = @(
    foreach ($mapping in $mappings) {
        $inputPath = Join-Path $source $mapping.sourcePath.Replace('/', '\')
        $targetPath = Join-Path $destination $mapping.path.Replace('/', '\')
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $targetPath))
        [IO.File]::Copy($inputPath, $targetPath, $false)
        $copiedHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($copiedHash -cne $providerHashes[$mapping.sourcePath]) { throw "Provider copy failed integrity verification: $($mapping.path)" }
        [ordered]@{ path=$mapping.path; sourcePath=$mapping.sourcePath; sha256=$copiedHash }
    }
)
$manifest = [ordered]@{
    schemaVersion = 1
    runtimeVersion = '37.3.9'
    runtimeBuild = '16863232'
    provider = 'angle-swiftshader-vulkan'
    angleVersion = $angleVersion
    glesProvider = 'lib64/gles_swiftshader'
    vulkanIcd = 'lib64/vulkan/vk_swiftshader_icd.json'
    files = $manifestFiles
}
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $destination 'modern-vulkan.json'), ($manifest | ConvertTo-Json -Depth 6), $utf8)
$notice = @'
ArtemisOS modern Vulkan software graphics adapter

Base runtime: official Android Emulator 37.3.9, build 16863232 for Windows x64.
The QEMU and emulator executables are unmodified. All provider DLLs and ICD
metadata are byte-for-byte copies of this package's official gles_angle files.
Their existing third-party licenses and notices continue to apply.

This loader adaptation maps the bundled ANGLE + Vulkan SwiftShader provider
into the Windows software backend directory. Legacy SwiftShader GLES libraries,
including libGLES_CM.dll, are not included in that directory. This is an
ArtemisOS integration, not an upstream-supported Windows SwANGLE mode.

The launcher must scope these settings to the child emulator process:
  -gpu swangle
  ANGLE_DEFAULT_PLATFORM=swiftshader
  ANDROID_EGL_ON_EGL=1
  VK_ICD_FILENAMES=<this runtime>/lib64/vulkan/vk_swiftshader_icd.json
The hardware backend must not inherit those software-only settings.

modern-vulkan.json records all eight exact provider mappings and SHA-256 hashes.
Unchanged runtime files are hard links to the source; treat both trees as
immutable build inputs. Use a separate copy for execution or modification.
The six non-x86_64 QEMU executables remain for Prepare-SlimSdk.ps1 to exclude.
'@
[IO.File]::WriteAllText((Join-Path $destination 'ARTEMIS-GRAPHICS-NOTICE.txt'), $notice, $utf8)
Write-Host "Prepared modern Vulkan runtime in $destination ($linked unchanged hard links, $($manifestFiles.Count) independent provider copies)."
Write-Host 'Keep source and output immutable during packaging; this tool does not validate runtime stability.'
