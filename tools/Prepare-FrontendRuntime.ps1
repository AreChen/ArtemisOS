[CmdletBinding()]
param([string]$TargetRoot = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$project = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($TargetRoot)) { $TargetRoot = Join-Path $project 'stage' }
$target = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\')
if (-not $target.StartsWith(($project + '\'),[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Runtime preparation is restricted to a staging directory inside this project.'
}
$source = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Genymobile.scrcpy_Microsoft.Winget.Source_8wekyb3d8bbwe\scrcpy-win64-v4.1'
$noticeSource = Join-Path $project 'third-party\scrcpy-4.1'
$iconSource = Join-Path $project 'stage\ArtemisOS15.ico'
$brandSource = Join-Path $project 'desktop\frontend\assets\brand.png'
$runtimeFiles = @('scrcpy.exe','scrcpy-server','SDL3.dll','avcodec-62.dll','avformat-62.dll','avutil-60.dll','swresample-6.dll','libusb-1.0.dll','LICENSE.txt')
foreach ($file in ($runtimeFiles + @('disconnected.png'))) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $file) -PathType Leaf)) { throw "The pinned official WinGet scrcpy 4.1 package is incomplete: $file" }
}
if (-not (Test-Path -LiteralPath $iconSource -PathType Leaf)) { throw 'The ArtemisOS source icon is missing.' }
if (-not (Test-Path -LiteralPath $brandSource -PathType Leaf)) { throw 'The ArtemisOS source brand PNG is missing.' }
$manifestPath = Join-Path $noticeSource 'sources.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'The frontend third-party source manifest is missing.' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.scrcpyVersion -cne '4.1' -or $manifest.redistributionReviewStatus -cne 'source-bundle-prepared-publication-required') { throw 'Unexpected frontend third-party manifest.' }
function Get-FrontendSha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
}
foreach ($record in $manifest.files) {
    $path = Join-Path $noticeSource $record.file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FrontendSha256 $path) -cne $record.sha256) {
        throw "The cached upstream license/build reference is missing or has changed: $($record.file)"
    }
}
$sourceBundle = Join-Path $noticeSource $manifest.sourceBundle.file
if (-not (Test-Path -LiteralPath $sourceBundle -PathType Leaf) -or
    (Get-Item -LiteralPath $sourceBundle).Length -ne $manifest.sourceBundle.size -or
    (Get-FrontendSha256 $sourceBundle) -cne $manifest.sourceBundle.sha256) {
    throw 'The separately published display source ZIP is missing or differs from the notice manifest.'
}
foreach ($record in $manifest.binaryFiles) {
    if ((Get-FrontendSha256 (Join-Path $source $record.file)) -cne $record.sha256) { throw "The local scrcpy package changed from the audited development copy: $($record.file)" }
}
$versionOutput = & rtk proxy (Join-Path $source 'scrcpy.exe') --version 2>&1
if ($LASTEXITCODE -ne 0 -or ($versionOutput -join "`n") -notmatch '(?m)^scrcpy 4\.1(?:\s|$)') { throw 'The local display runtime is not scrcpy 4.1.' }
$secureSource = Join-Path $project 'third-party\artemis-scrcpy-display'
$secureBuildTool = Join-Path $project 'tools\Build-SecureDisplayServer.ps1'
$secureBuild = Join-Path $project 'build\secure-display-server'
$secureMetadata = Join-Path $secureBuild 'manifest.json'
$secureServer = Join-Path $secureBuild 'scrcpy-server'
if (-not (Test-Path -LiteralPath $secureMetadata) -or -not (Test-Path -LiteralPath $secureServer)) {
    & $secureBuildTool -OutputDirectory $secureBuild
}
$secure = Get-Content -LiteralPath $secureMetadata -Raw | ConvertFrom-Json
# Fail closed on a stale or modified cached build. Rebuild explicitly after changing
# the server sources; do not silently ship the upstream nonsecure server instead.
if ($secure.variant -cne 'ArtemisOS-local-secure-display' -or $secure.protocolVersion -cne '4.1' -or
    $secure.serverSha256 -cne (Get-FrontendSha256 $secureServer) -or
    $secure.upstreamArchiveSha256 -cne (Get-FrontendSha256 (Join-Path $noticeSource 'source-archives\scrcpy-4.1.tar.gz')) -or
    $secure.patchSha256 -cne (Get-FrontendSha256 (Join-Path $secureSource 'secure-display.patch')) -or
    $secure.policySha256 -cne (Get-FrontendSha256 (Join-Path $secureSource 'src\ArtemisDisplayPolicy.java')) -or
    -not ($secure.PSObject.Properties.Name -contains 'buildScriptSha256') -or
    $secure.buildScriptSha256 -cne (Get-FrontendSha256 $secureBuildTool)) {
    throw 'The dedicated display server build is stale or has changed. Run tools\Build-SecureDisplayServer.ps1 before preparing the runtime.'
}
function Copy-FrontendFile([string]$From,[string]$To) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $To))
    $temporary = $To + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $previous = $temporary + '.previous'
    try {
        [IO.File]::Copy($From,$temporary,$false)
        if ([IO.File]::Exists($To)) { [IO.File]::Replace($temporary,$To,$previous) }
        else { [IO.File]::Move($temporary,$To) }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        if ([IO.File]::Exists($previous)) { [IO.File]::Delete($previous) }
    }
}
$frontend = Join-Path $target 'update\frontend'
$runtime = Join-Path $frontend 'runtime'
$assets = Join-Path $frontend 'assets'
$notices = Join-Path $frontend 'third-party'
foreach ($file in $runtimeFiles) { Copy-FrontendFile (Join-Path $source $file) (Join-Path $runtime $file) }
Copy-FrontendFile (Join-Path $source 'disconnected.png') (Join-Path $assets 'disconnected.png')
Copy-FrontendFile $iconSource (Join-Path $assets 'ArtemisOS15.ico')
# Only the explicit lightweight files are installed. Complete source archives
# are published separately from the same public installer/OTA download place.
foreach ($record in $manifest.files) { Copy-FrontendFile (Join-Path $noticeSource $record.file) (Join-Path $notices $record.file) }
Copy-FrontendFile $manifestPath (Join-Path $notices 'sources.json')
# Only this dedicated local viewer receives a privileged secure mirror. The ADB
# daemon, app FLAG_SECURE settings and independent screenshots are unchanged.
Copy-FrontendFile $secureServer (Join-Path $runtime 'scrcpy-server')
$secureNotices = Join-Path $notices 'artemis-display'
foreach ($item in @(Get-ChildItem -LiteralPath $secureSource -File -Recurse)) {
    $relative = $item.FullName.Substring($secureSource.Length).TrimStart('\')
    Copy-FrontendFile $item.FullName (Join-Path $secureNotices $relative)
}
Copy-FrontendFile $secureBuildTool (Join-Path $secureNotices 'Build-SecureDisplayServer.ps1')
Copy-FrontendFile (Join-Path $project 'tests\secure-display-server.ps1') (Join-Path $secureNotices 'secure-display-server.ps1')
Copy-FrontendFile $secureMetadata (Join-Path $secureNotices 'manifest.json')
Add-Type -AssemblyName System.Drawing
[void][IO.Directory]::CreateDirectory($assets)
$brand = [Drawing.Image]::FromFile($brandSource)
$bitmap = $null
$graphics = $null
$png = Join-Path $assets 'scrcpy.png'
$pngTemporary = $png + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
$pngPrevious = $pngTemporary + '.previous'
try {
    $bitmap = [Drawing.Bitmap]::new(256,256,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([Drawing.Color]::Transparent)
    $graphics.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceCopy
    $graphics.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
    $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $ratio = [Math]::Min(256.0 / $brand.Width,256.0 / $brand.Height)
    $width = [Math]::Max(1,[int][Math]::Round($brand.Width * $ratio))
    $height = [Math]::Max(1,[int][Math]::Round($brand.Height * $ratio))
    $rectangle = [Drawing.Rectangle]::new([int]((256-$width)/2),[int]((256-$height)/2),$width,$height)
    $graphics.DrawImage($brand,$rectangle)
    $graphics.Dispose(); $graphics = $null
    $bitmap.Save($pngTemporary,[Drawing.Imaging.ImageFormat]::Png)
    if ([IO.File]::Exists($png)) { [IO.File]::Replace($pngTemporary,$png,$pngPrevious) }
    else { [IO.File]::Move($pngTemporary,$png) }
} finally {
    if ($null -ne $graphics) { $graphics.Dispose() }
    if ($null -ne $bitmap) { $bitmap.Dispose() }
    $brand.Dispose()
    if ([IO.File]::Exists($pngTemporary)) { [IO.File]::Delete($pngTemporary) }
    if ([IO.File]::Exists($pngPrevious)) { [IO.File]::Delete($pngPrevious) }
}
$size = (Get-ChildItem -LiteralPath $runtime -File | Measure-Object -Property Length -Sum).Sum
Write-Host ('Prepared scrcpy 4.1 frontend runtime ({0:N2} MiB), branded assets and source/license references.' -f ($size / 1MB))
Write-Host 'Source materials are prepared; publish and verify the separate source ZIP before publishing binaries. Preparation does not verify public access.'
