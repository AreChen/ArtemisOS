param([string[]]$Scenarios = @('normal','normal-isolation','cancel-before-backend','cancel-before-receipt','failed-backend-crashed','backend-crashed','wrapper-crashed','viewer-crashed','reconnect','renderer-reset','renderer-reset-limit','recovery-manual-race','recovery-coalesced','recovery-close-race','update','update-close-race','recovery-update-race'))
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fixtureRoot = Join-Path $root ('build\frontend-session-tests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$executable = Join-Path $fixtureRoot 'session-tests.exe'
$sources = @(Get-ChildItem -LiteralPath (Join-Path $root 'desktop\frontend') -Filter '*.cs' -File | Select-Object -ExpandProperty FullName)
$arguments = @('/nologo','/target:exe','/platform:x64','/optimize+','/main:ArtemisOS.Frontend.SessionFixture',('/out:'+$executable),'/reference:System.dll','/reference:System.Core.dll','/reference:System.Drawing.dll','/reference:System.Windows.Forms.dll','/reference:System.Management.dll','/reference:System.Web.Extensions.dll') + $sources + (Join-Path $PSScriptRoot 'frontend-session-fixture.cs')
& rtk proxy $compiler @arguments
if ($LASTEXITCODE -ne 0) { throw 'Session fixture compilation failed.' }
$failed = 0
foreach ($scenario in $Scenarios) {
    & rtk proxy $executable $scenario (Join-Path $fixtureRoot $scenario)
    if ($LASTEXITCODE -ne 0) { $failed++ }
}
Write-Output "Fixture evidence: $fixtureRoot"
if ($failed) { throw "$failed session scenarios failed." }
