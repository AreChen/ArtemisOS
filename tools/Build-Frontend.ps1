param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'stage\update\frontend' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw '需要 Windows .NET Framework 4.8 的 C# 编译器。' }
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$destination = Join-Path $OutputDirectory 'ArtemisFrontend.exe'
$temporary = Join-Path $OutputDirectory ('ArtemisFrontend-' + [guid]::NewGuid().ToString('N') + '.exe')
$sources = @(Get-ChildItem -LiteralPath (Join-Path $root 'desktop\frontend') -Filter '*.cs' -File | Select-Object -ExpandProperty FullName)
$arguments = @('/nologo','/target:winexe','/platform:x64','/optimize+','/debug:pdbonly',('/out:'+$temporary),
    '/reference:System.dll','/reference:System.Core.dll','/reference:System.Drawing.dll','/reference:System.Windows.Forms.dll',
    '/reference:System.Management.dll','/reference:System.Web.Extensions.dll',
    ('/win32manifest:'+(Join-Path $root 'desktop\frontend\frontend.manifest')),('/win32icon:'+(Join-Path $root 'stage\ArtemisOS15.ico'))) + $sources
try {
    & rtk proxy $compiler @arguments
    if ($LASTEXITCODE -ne 0) { throw "Frontend 编译失败 ($LASTEXITCODE)。" }
    # Replacing the file keeps any existing hardlink target unchanged.
    if (Test-Path -LiteralPath $destination) { [IO.File]::Delete($destination) }
    [IO.File]::Move($temporary,$destination)
    $pdb = [IO.Path]::ChangeExtension($temporary,'.pdb')
    if (Test-Path -LiteralPath $pdb) { Move-Item -LiteralPath $pdb -Destination (Join-Path $OutputDirectory 'ArtemisFrontend.pdb') -Force }
    Get-Item -LiteralPath $destination | Select-Object FullName,Length
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}
