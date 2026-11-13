$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$output=Join-Path $root ('build\frontend-render-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($output)|Out-Null
$exe=Join-Path $output 'frontend-render-tests.exe'
$sources=@(Get-ChildItem (Join-Path $root 'desktop\frontend') -Filter '*.cs' -File | Select-Object -ExpandProperty FullName)
& rtk proxy (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe') /nologo /target:exe /platform:x64 /main:FrontendRenderTests ('/out:'+$exe) /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Management.dll /r:System.Web.Extensions.dll @sources (Join-Path $PSScriptRoot 'frontend-render-tests.cs')
if($LASTEXITCODE -ne 0){throw 'Render test compilation failed.'}
& rtk proxy $exe
if($LASTEXITCODE -ne 0){throw 'Render test failed.'}
