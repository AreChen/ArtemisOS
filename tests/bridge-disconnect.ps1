# Integration test: an Android client that disconnects while a download is in
# progress must not cause the bridge to start the installer.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$project = Split-Path -Parent $PSScriptRoot
$work = Join-Path $project ('build\bridge-disconnect-' + [Guid]::NewGuid().ToString('N'))
$root = Join-Path $work 'installation'
$target = Join-Path $work 'target'
$serverRoot = Join-Path $work 'server'
foreach ($dir in @($root, $target, $serverRoot, (Join-Path $root 'sdk\platform-tools'), (Join-Path $root 'data\update'))) {
    [void][IO.Directory]::CreateDirectory($dir)
}
Copy-Item -LiteralPath (Join-Path $project 'stage\update') -Destination $root -Recurse
Copy-Item -LiteralPath (Join-Path $project 'stage\version.ini') -Destination $root
Copy-Item -LiteralPath (Join-Path $root 'update') -Destination $target -Recurse
$current = [IO.File]::ReadAllText((Join-Path $root 'version.ini'))
if ($current -notmatch '(?m)^Version=(\d+)\.(\d+)\.(\d+)\r?$') { throw '无法读取测试基线版本。' }
$nextVersion = '{0}.{1}.{2}' -f $matches[1], $matches[2], ([int]$matches[3] + 1)
[IO.File]::WriteAllText((Join-Path $target 'version.ini'), "[ArtemisOS]`nVersion=$nextVersion`n", [Text.Encoding]::ASCII)
& (Join-Path $project 'tools\Publish-Update.ps1') -BaseRoot $root -TargetRoot $target -Repository (Join-Path $serverRoot 'repository')

$fakeAdbSource = @'
using System;
using System.IO;
class FakeAdb {
    static void Main(string[] args) {
        string root = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "..", ".."));
        if (Array.IndexOf(args, "getprop") >= 0) { Console.WriteLine("1"); return; }
        if (Array.IndexOf(args, "install") >= 0) { Console.WriteLine("Success"); return; }
        if (Array.IndexOf(args, "broadcast") >= 0) {
            int token = Array.IndexOf(args, "token"), port = Array.IndexOf(args, "port");
            File.WriteAllText(Path.Combine(root, "data", "update", "fake-init.txt"), args[token + 1] + "\n" + args[port + 1]);
            Console.WriteLine("Broadcast completed"); return;
        }
        Environment.Exit(1);
    }
}
'@
$fakeAdbPath = Join-Path $work 'fake-adb.cs'
[IO.File]::WriteAllText($fakeAdbPath, $fakeAdbSource, [Text.Encoding]::UTF8)
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $compiler /nologo /target:exe (('/out:' + (Join-Path $root 'sdk\platform-tools\adb.exe'))) $fakeAdbPath
if ($LASTEXITCODE -ne 0) { throw '无法构建测试用 adb。' }

$serverCode = @'
const http = require('http'), fs = require('fs'), path = require('path');
const root = path.join(__dirname, 'repository');
http.createServer((req, res) => {
  if (req.url === '/health') { res.end('ok'); return; }
  if (!/^\/(manifests\/\d+\.\d+\.\d+\.(json|sig)|objects\/[a-f0-9]{64})$/.test(req.url)) { res.writeHead(404).end(); return; }
  const file = path.join(root, req.url.slice(1));
  fs.stat(file, (err, stat) => {
    if (err) { res.writeHead(404).end(); return; }
    const send = () => { res.writeHead(200, { 'Content-Length': stat.size }); fs.createReadStream(file).pipe(res); };
    if (req.url.startsWith('/objects/')) {
      fs.writeFileSync(path.join(__dirname, 'object-requested'), '1');
      setTimeout(send, 2000);
    } else send();
  });
}).listen(Number(process.env.ARTEMIS_BRIDGE_TEST_PORT), '127.0.0.1');
'@
$serverFile = Join-Path $serverRoot 'server.js'
[IO.File]::WriteAllText($serverFile, $serverCode, [Text.Encoding]::UTF8)
$portProbe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$portProbe.Start()
$port = ([Net.IPEndPoint]$portProbe.LocalEndpoint).Port
$portProbe.Stop()
[IO.File]::WriteAllText((Join-Path $root 'data\update\server.txt'), "http://127.0.0.1:$port/", [Text.Encoding]::ASCII)
$node = (Get-Command node.exe -ErrorAction Stop).Source
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$server = $null
$keeper = $null
$bridge = $null
try {
    $oldPort = $env:ARTEMIS_BRIDGE_TEST_PORT
    $env:ARTEMIS_BRIDGE_TEST_PORT = [string]$port
    try {
        $server = Start-Process -FilePath $node -ArgumentList ('"' + $serverFile + '"') -WindowStyle Hidden -RedirectStandardOutput (Join-Path $work 'server.out') -RedirectStandardError (Join-Path $work 'server.err') -PassThru
    } finally {
        if ($null -eq $oldPort) { Remove-Item Env:ARTEMIS_BRIDGE_TEST_PORT -ErrorAction SilentlyContinue }
        else { $env:ARTEMIS_BRIDGE_TEST_PORT = $oldPort }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        try { $health = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/health" -TimeoutSec 1; break }
        catch { Start-Sleep -Milliseconds 250 }
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $health -or $health.StatusCode -ne 200) { throw '测试服务器未启动。' }
    $keeper = Start-Process -FilePath $powershell -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 120' -WindowStyle Hidden -PassThru
    $bridgeArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + (Join-Path $root 'update\bridge.ps1') + '"'),'-Serial','emulator-5554','-EmulatorPid',[string]$keeper.Id)
    $bridge = Start-Process -FilePath $powershell -ArgumentList $bridgeArgs -WindowStyle Hidden -RedirectStandardOutput (Join-Path $work 'bridge.out') -RedirectStandardError (Join-Path $work 'bridge.err') -PassThru
    $initPath = Join-Path $root 'data\update\fake-init.txt'
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not (Test-Path -LiteralPath $initPath) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250 }
    if (-not (Test-Path -LiteralPath $initPath)) { throw '测试桥接程序未启动。' }
    $init = [IO.File]::ReadAllLines($initPath)
    $token = $init[0]
    $bridgePort = [int]$init[1]
    $client = New-Object Net.Sockets.TcpClient
    $client.Connect([Net.IPAddress]::Loopback, $bridgePort)
    $newline = [string][char]13 + [char]10
    $request = 'POST /v1/install HTTP/1.1' + $newline + 'Host: 127.0.0.1' + $newline + 'X-Artemis-Token: ' + $token + $newline + 'Content-Length: 0' + $newline + $newline
    $requestBytes = [Text.Encoding]::ASCII.GetBytes($request)
    $client.GetStream().Write($requestBytes, 0, $requestBytes.Length)
    $marker = Join-Path $serverRoot 'object-requested'
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath $marker) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $marker)) { throw '更新文件未开始下载。' }
    $client.LingerState = New-Object Net.Sockets.LingerOption($true, 0)
    $client.Close()
    $bridgeLog = Join-Path $root 'data\update\bridge.log'
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 250
        $contents = if (Test-Path -LiteralPath $bridgeLog) { [IO.File]::ReadAllText($bridgeLog) } else { '' }
    } while ($contents -notmatch '请求处理失败' -and [DateTime]::UtcNow -lt $deadline)
    if ($contents -notmatch '请求处理失败') { throw '未观察到连接中断。' }
    if ($bridge.HasExited -or [IO.File]::ReadAllText((Join-Path $root 'version.ini')) -ne $current -or
        (Test-Path -LiteralPath (Join-Path $root 'data\update\pending\applying.flag'))) {
        throw '连接中断后不应开始安装或退出更新入口。'
    }
    $status = Invoke-RestMethod -UseBasicParsing -Uri "http://127.0.0.1:$bridgePort/v1/status" -Headers @{ 'X-Artemis-Token' = $token } -TimeoutSec 5
    if (-not $status.ok) { throw '连接中断后更新入口没有继续响应。' }
    Write-Host '通过：下载时客户端断开不会开始安装，更新入口可继续使用。'
} finally {
    foreach ($process in @($bridge, $keeper, $server)) {
        if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -ErrorAction SilentlyContinue }
    }
}
