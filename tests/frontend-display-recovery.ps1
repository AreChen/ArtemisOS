$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$output=Join-Path $root ('build\frontend-display-recovery-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($output)
$exe=Join-Path $output 'display-recovery-tests.exe'
$sources=@(Get-ChildItem (Join-Path $root 'desktop\frontend') -Filter '*.cs' -File | Select-Object -ExpandProperty FullName)
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& rtk proxy $compiler /nologo /target:exe /platform:x64 /langversion:5 /main:FrontendDisplayRecoveryTests ('/out:'+$exe) /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Management.dll /r:System.Web.Extensions.dll @sources (Join-Path $PSScriptRoot 'frontend-display-recovery-tests.cs')
if($LASTEXITCODE -ne 0){throw 'Display recovery test compilation failed.'}
& rtk proxy $exe (Join-Path $output 'isolated-root')
if($LASTEXITCODE -ne 0){throw 'Display recovery regression failed.'}
