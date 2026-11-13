$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$output = Join-Path $root ('build\frontend-menu-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($output) | Out-Null
$exe = Join-Path $output 'frontend-menu-tests.exe'
$sources = @(Get-ChildItem (Join-Path $root 'desktop\frontend') -Filter '*.cs' -File | Select-Object -ExpandProperty FullName)
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& rtk proxy $compiler /nologo /target:exe /platform:x64 /main:FrontendMenuTests ('/out:'+$exe) /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Management.dll /r:System.Web.Extensions.dll @sources (Join-Path $PSScriptRoot 'frontend-menu-tests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Menu test compilation failed.' }
& rtk proxy $exe (Join-Path $output 'installation')
if ($LASTEXITCODE -ne 0) { throw 'Menu test failed.' }
