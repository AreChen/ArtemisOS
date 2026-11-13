param(
    [Parameter(Mandatory = $true)][string]$SystemImage,
    [Parameter(Mandatory = $true)][string]$Output,
    [string]$SourceSdk,
    [string]$EmulatorDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $SourceSdk) { $SourceSdk = Join-Path $PSScriptRoot '..\stage\sdk' }

$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$buildRoot = [IO.Path]::GetFullPath((Join-Path $workspace 'build')).TrimEnd('\')
$source = (Resolve-Path -LiteralPath $SourceSdk).ProviderPath.TrimEnd('\')
$image = (Resolve-Path -LiteralPath $SystemImage).ProviderPath
$destination = [IO.Path]::GetFullPath($Output).TrimEnd('\')
$emulator = if ($EmulatorDirectory) { (Resolve-Path -LiteralPath $EmulatorDirectory).ProviderPath.TrimEnd('\') } else { Join-Path $source 'emulator' }
$expectedImage = 'system-images\android-35\google_apis\x86_64\system.img'
$sourceImage = Join-Path $source $expectedImage

if (-not $destination.StartsWith($buildRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The output must be a new directory inside this project build directory.'
}
if (Test-Path -LiteralPath $destination) { throw "Output already exists: $destination" }
foreach ($required in @($sourceImage, (Join-Path $emulator 'emulator.exe'), (Join-Path $emulator 'qemu\windows-x86_64\qemu-system-x86_64.exe'), (Join-Path $emulator 'qemu\windows-x86_64\qemu-system-x86_64-headless.exe'), $image)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing input: $required" }
}
if ((Get-Item -LiteralPath $image).Length -ne (Get-Item -LiteralPath $sourceImage).Length) {
    throw 'The replacement image must have the same disk layout and length as the source image.'
}
if ([IO.Path]::GetPathRoot($source) -ne [IO.Path]::GetPathRoot($destination) -or
    [IO.Path]::GetPathRoot($image) -ne [IO.Path]::GetPathRoot($destination) -or
    [IO.Path]::GetPathRoot($emulator) -ne [IO.Path]::GetPathRoot($destination)) {
    throw 'Inputs and output must be on the same volume because this tool creates hard links.'
}

[void][IO.Directory]::CreateDirectory($destination)
$excluded = [Collections.Generic.List[string]]::new()
$linked = 0
$inputs = @(
    foreach ($file in Get-ChildItem -LiteralPath $source -File -Recurse -Force) {
        $relative = $file.FullName.Substring($source.Length).TrimStart('\')
        if ($EmulatorDirectory -and $relative.StartsWith('emulator\', [StringComparison]::OrdinalIgnoreCase)) { continue }
        [PSCustomObject]@{ File = $file.FullName; Relative = $relative }
    }
    if ($EmulatorDirectory) {
        foreach ($file in Get-ChildItem -LiteralPath $emulator -File -Recurse -Force) {
            [PSCustomObject]@{ File = $file.FullName; Relative = ('emulator\' + $file.FullName.Substring($emulator.Length).TrimStart('\')) }
        }
    }
)
foreach ($inputFile in $inputs) {
    $relative = $inputFile.Relative
    if ($relative -match '^emulator\\qemu\\windows-x86_64\\qemu-system-(aarch64|armel|i386)(-headless)?\.exe$') {
        $excluded.Add($relative)
        continue
    }
    $linkSource = if ($relative -ieq $expectedImage) { $image } else { $inputFile.File }
    $linkPath = Join-Path $destination $relative
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $linkPath))
    [void](New-Item -ItemType HardLink -Path $linkPath -Target $linkSource)
    $linked++
}
if ($excluded.Count -ne 6) { throw "Expected six unused QEMU executables, found $($excluded.Count); output has been retained for inspection." }
Write-Host "Prepared $linked files in $destination, using the supplied system image and omitting $($excluded.Count) unused QEMU executables."
Write-Host 'The files are hard links to the inputs. Treat the output and its inputs as read-only during packaging.'
