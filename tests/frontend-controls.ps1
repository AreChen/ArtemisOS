param([string]$Product)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if(-not $Product){$Product=Join-Path $root 'stage\update\frontend\ArtemisFrontend.exe'}
$output=Join-Path $root ('build\frontend-controls-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($output)|Out-Null
$exe=Join-Path $output 'frontend-controls-tests.exe'
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& rtk proxy $compiler /nologo /target:exe /platform:x64 ('/out:'+$exe) /r:System.dll /r:System.Core.dll /r:System.Windows.Forms.dll (Join-Path $PSScriptRoot 'frontend-controls-tests.cs')
if($LASTEXITCODE -ne 0){throw 'Control test compilation failed.'}
& rtk proxy $exe $Product (Join-Path $output 'installation')
if($LASTEXITCODE -ne 0){throw 'Control test failed.'}
