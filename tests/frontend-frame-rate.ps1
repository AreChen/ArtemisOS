param([switch]$AllCore)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$project = Split-Path -Parent $PSScriptRoot
$fixtureParent = Join-Path $project 'build\frontend-frame-rate-tests'
$fixture = Join-Path $fixtureParent ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
try {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $core = Join-Path $project 'desktop\frontend\FrontendCore.cs'
    $testExe = Join-Path $fixture 'frontend frame rate tests.exe'
    & rtk proxy $csc /nologo /target:exe /langversion:5 /warnaserror /r:System.Management.dll "/out:$testExe" $core (Join-Path $PSScriptRoot 'frontend-core-tests.cs')
    if ($LASTEXITCODE -ne 0) { throw 'The focused frontend FPS tests did not compile.' }
    if ($AllCore) { & rtk proxy $testExe $fixture }
    else { & rtk proxy $testExe $fixture --frame-rate-only }
    if ($LASTEXITCODE -ne 0) { throw 'The focused frontend FPS tests failed.' }
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture).TrimEnd('\')
    $allowed = [IO.Path]::GetFullPath($fixtureParent).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe frontend FPS fixture cleanup.' }
    if (Test-Path -LiteralPath $resolved) {
        if ((Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unexpected frontend FPS fixture reparse point.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
