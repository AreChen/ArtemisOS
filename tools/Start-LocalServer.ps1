param(
    [ValidateRange(1024, 65535)][int]$Port = 18765,
    [string]$InstallRoot,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$project = Split-Path -Parent $PSScriptRoot
$node = (Get-Command node.exe -ErrorAction Stop).Source
$entry = Join-Path $project 'server\server.js'
$build = Join-Path $project 'build'
$record = Join-Path $build 'local-server.json'
$url = "http://127.0.0.1:$Port/"
$config = $null
if (Test-Path -LiteralPath $record -PathType Leaf) {
    $existing = [IO.File]::ReadAllText($record) | ConvertFrom-Json
    $existingProcess = Get-CimInstance Win32_Process -Filter ("ProcessId = " + [int]$existing.pid)
    if ($existingProcess -and $existingProcess.Name -ieq 'node.exe' -and $existingProcess.CommandLine.Contains($entry)) {
        throw '记录中的本机测试服务器已在运行，请先停止它。'
    }
}
if ($InstallRoot) {
    $InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
    $versionFile = Join-Path $InstallRoot 'version.ini'
    if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf) -or
        [IO.File]::ReadAllText($versionFile) -notmatch '(?m)^Version=\d+\.\d+\.\d+\r?$') {
        throw '目标目录不是有效的 ArtemisOS 安装。'
    }
    $config = Join-Path $InstallRoot 'data\update\server.txt'
    if ((Test-Path -LiteralPath $config -PathType Leaf) -and
        [IO.File]::ReadAllText($config).Trim() -ne $url -and -not $Force) {
        throw '该安装已有其他更新服务器配置；确认后使用 -Force 覆盖。'
    }
}
$probe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
try { $probe.Start() } catch { throw "本机端口 $Port 已被占用。" } finally { $probe.Stop() }
[void][IO.Directory]::CreateDirectory($build)
$previous = $env:ARTEMIS_UPDATE_TEST_PORT
$env:ARTEMIS_UPDATE_TEST_PORT = [string]$Port
try {
    $process = Start-Process -FilePath $node -ArgumentList ('"' + $entry + '"') -WorkingDirectory $project -WindowStyle Hidden -RedirectStandardOutput (Join-Path $build 'local-server.stdout.log') -RedirectStandardError (Join-Path $build 'local-server.stderr.log') -PassThru
} finally {
    if ($null -eq $previous) { Remove-Item Env:ARTEMIS_UPDATE_TEST_PORT -ErrorAction SilentlyContinue }
    else { $env:ARTEMIS_UPDATE_TEST_PORT = $previous }
}
try {
    Start-Sleep -Seconds 1
    if ($process.HasExited) { throw '本机更新服务器启动失败，请检查 build/local-server.stderr.log。' }
    $health = Invoke-RestMethod -Uri ($url + 'health') -TimeoutSec 5 -UseBasicParsing
    if ($health.product -ne 'ArtemisOS-local-update-server') { throw '本机更新服务器校验失败。' }
    if ($config) {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $config))
        [IO.File]::WriteAllText($config, $url, [Text.Encoding]::ASCII)
    }
    [IO.File]::WriteAllText($record, (@{pid=$process.Id;port=$Port;entry=$entry} | ConvertTo-Json),
        (New-Object Text.UTF8Encoding($false)))
} catch {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -ErrorAction SilentlyContinue }
    throw
}
Write-Host "本机测试服务器已启动：$url"
if ($config) { Write-Host "已为当前安装配置该测试服务器：$InstallRoot" }
