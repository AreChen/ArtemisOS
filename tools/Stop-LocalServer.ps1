$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$project = Split-Path -Parent $PSScriptRoot
$record = Join-Path $project 'build\local-server.json'
if (-not (Test-Path -LiteralPath $record -PathType Leaf)) { Write-Host '没有记录中的本机测试服务器。'; return }
$server = [IO.File]::ReadAllText($record) | ConvertFrom-Json
$process = Get-CimInstance Win32_Process -Filter ("ProcessId = " + [int]$server.pid)
$expected = Join-Path $project 'server\server.js'
if ($process -and $process.Name -ieq 'node.exe' -and $process.CommandLine.Contains($expected)) {
    Stop-Process -Id $process.ProcessId
    Write-Host '本机测试服务器已停止。'
} elseif ($process) { throw '记录的进程与服务器不符，未停止其他程序。' }
else { Write-Host '本机测试服务器已经停止。' }
Remove-Item -LiteralPath $record -Force
