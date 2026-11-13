$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$project = Split-Path -Parent $PSScriptRoot
$fixtureParent = Join-Path $project 'build\frontend-core-tests'
$fixture = Join-Path $fixtureParent ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
try {
    $core = Join-Path $project 'desktop\frontend\FrontendCore.cs'
    if (-not (Test-Path -LiteralPath $core -PathType Leaf)) { throw 'FAIL: the frontend core API is not implemented.' }
    $testExe = Join-Path $fixture 'frontend core tests.exe'
    & rtk proxy $csc /nologo /target:exe /langversion:5 /warnaserror /r:System.Management.dll "/out:$testExe" $core (Join-Path $PSScriptRoot 'frontend-core-tests.cs')
    if ($LASTEXITCODE -ne 0) { throw 'The frontend core tests did not compile.' }
    & rtk proxy $testExe $fixture
    if ($LASTEXITCODE -ne 0) { throw 'The frontend core tests failed.' }
    $prepare = Join-Path $project 'tools\Prepare-FrontendRuntime.ps1'
    if (-not (Test-Path -LiteralPath $prepare -PathType Leaf)) { throw 'FAIL: the fixed-version frontend runtime preparation is not implemented.' }
    $stage = Join-Path $fixture 'stage'
    & $prepare -TargetRoot $stage
    $runtime = Join-Path $stage 'update\frontend\runtime'
    $assets = Join-Path $stage 'update\frontend\assets'
    foreach ($file in @('scrcpy.exe','scrcpy-server','SDL3.dll','avcodec-62.dll','avformat-62.dll','avutil-60.dll','swresample-6.dll','libusb-1.0.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $runtime $file) -PathType Leaf)) { throw "Missing frontend runtime dependency: $file" }
    }
    if (Test-Path -LiteralPath (Join-Path $runtime 'adb.exe')) { throw 'The frontend must reuse the installation ADB.' }
    foreach ($file in @('scrcpy.png','disconnected.png','ArtemisOS15.ico')) {
        if (-not (Test-Path -LiteralPath (Join-Path $assets $file) -PathType Leaf)) { throw "Missing branded asset: $file" }
    }
    Add-Type -AssemblyName System.Drawing
    $brand = [Drawing.Bitmap]::new((Join-Path $assets 'scrcpy.png'))
    try {
        if ($brand.Width -ne 256 -or $brand.Height -ne 256 -or $brand.GetPixel(0,0).A -ne 0) { throw 'The branded image must be a transparent 256-pixel PNG, not the corrupt ICO frame.' }
        $center = $brand.GetPixel(128,128)
        if ($center.A -lt 240 -or $center.R -lt 180 -or $center.G -lt 180 -or $center.B -lt 180) { throw 'The center of the ArtemisOS logo was not preserved.' }
    } finally { $brand.Dispose() }
    $provenance = Get-Content -LiteralPath (Join-Path $stage 'update\frontend\third-party\sources.json') -Raw | ConvertFrom-Json
    if ($provenance.redistributionReviewStatus -cne 'pending' -or $provenance.scrcpyVersion -cne '4.1') { throw 'The development copy incorrectly claims release clearance or changed version.' }
    & $prepare -TargetRoot $stage
    if (@(Get-ChildItem -LiteralPath (Join-Path $stage 'update\frontend') -Recurse -File -Filter '*.previous').Count -ne 0) { throw 'Repeated runtime preparation left a backup file.' }
    Write-Host 'PASS: fixed scrcpy runtime, branded assets, shared ADB and explicit pending redistribution review.'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture).TrimEnd('\')
    $allowed = [IO.Path]::GetFullPath($fixtureParent).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe frontend test cleanup.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
