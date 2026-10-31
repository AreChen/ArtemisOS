param(
    [Parameter(Mandatory = $true)][string]$Serial,
    [Parameter(Mandatory = $true)][int]$EmulatorPid,
    [ValidateSet('auto','swiftshader')][string]$Graphics = 'auto'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'core.ps1')
$dataRoot = Join-Path $root 'data\update'
[void][IO.Directory]::CreateDirectory($dataRoot)
$log = Join-Path $dataRoot 'bridge.log'
function Write-BridgeLog([string]$Message) {
    Add-Content -LiteralPath $log -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message" -Encoding UTF8
}
function Send-BridgeResponse($Stream, [int]$Code, $Body) {
    $json = $Body | ConvertTo-Json -Compress -Depth 8
    $bodyBytes = [Text.Encoding]::UTF8.GetBytes($json)
    $status = if ($Code -eq 200) { 'OK' } elseif ($Code -eq 403) { 'Forbidden' } else { 'Bad Request' }
    $headers = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $Code $status`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bodyBytes.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n")
    $Stream.Write($headers, 0, $headers.Length)
    $Stream.Write($bodyBytes, 0, $bodyBytes.Length)
    $Stream.Flush()
}
if ($Serial -notmatch '^emulator-\d+$' -or $EmulatorPid -le 0) { throw '模拟器参数无效。' }
$adb = Join-Path $root 'sdk\platform-tools\adb.exe'
$apk = Join-Path $PSScriptRoot 'ArtemisUpdate.apk'
if (-not (Test-Path -LiteralPath $apk -PathType Leaf)) { throw '更新应用不存在。' }
function Invoke-BridgeAdb([string[]]$Arguments) {
    $old = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $adb @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    return [pscustomobject]@{Code=$code;Output=(($output | ForEach-Object { "$_" }) -join "`n").Trim()}
}
$bytes = New-Object byte[] 32
$random = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $random.GetBytes($bytes) } finally { $random.Dispose() }
$token = ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
try {
    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    $ready = $false
    while ([DateTime]::UtcNow -lt $deadline -and (Get-Process -Id $EmulatorPid -ErrorAction SilentlyContinue)) {
        $boot = Invoke-BridgeAdb @('-s', $Serial, 'shell', 'getprop', 'sys.boot_completed')
        if ($boot.Code -eq 0 -and $boot.Output -eq '1') { $ready = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { throw '等待模拟器启动超时。' }
    $installed = Invoke-BridgeAdb @('-s', $Serial, 'install', '-r', $apk)
    if ($installed.Code -ne 0 -or $installed.Output -notmatch 'Success') { throw '无法安装安卓更新入口。' }
    $broadcast = Invoke-BridgeAdb @('-s', $Serial, 'shell', 'am', 'broadcast', '-n', 'cn.artemisos.updater/.BootstrapReceiver', '--es', 'token', $token, '--ei', 'port', [string]$port)
    if ($broadcast.Code -ne 0 -or $broadcast.Output -match 'Permission Denial|Error') { throw '无法初始化安卓更新入口。' }
    Write-BridgeLog '更新入口已就绪。'
    while (Get-Process -Id $EmulatorPid -ErrorAction SilentlyContinue) {
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 200; continue }
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 5000
        $client.SendTimeout = 5000
        $stream = $client.GetStream()
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII, $false, 4096, $true)
        $staged = $null
        $applyRequested = $false
        try {
            $first = $reader.ReadLine()
            if (-not $first -or $first.Length -gt 2048 -or $first -notmatch '^(GET|POST) (/v1/(?:status|check|install)) HTTP/1\.[01]$') { throw '请求无效。' }
            $method = $matches[1]
            $route = $matches[2]
            $headers = @{}
            $headerSize = 0
            while ($null -ne ($line = $reader.ReadLine()) -and $line.Length -gt 0) {
                $headerSize += $line.Length
                if ($headerSize -gt 8192 -or $line.Length -gt 2048 -or $line -notmatch '^([^:]+):\s*(.*)$') { throw '请求标头无效。' }
                $headers[$matches[1].Trim().ToLowerInvariant()] = $matches[2].Trim()
            }
            if ($headers['x-artemis-token'] -cne $token) {
                Send-BridgeResponse $stream 403 @{ok=$false;message='更新请求未获授权。'}
                continue
            }
            if (($route -eq '/v1/status' -and $method -ne 'GET') -or
                ($route -ne '/v1/status' -and $method -ne 'POST')) { throw '请求方法无效。' }
            if ($route -eq '/v1/status') {
                $body = @{ok=$true;message=('当前版本：' + (Get-UpdateVersion $root))}
            } elseif ($route -eq '/v1/check') {
                $offer = Get-UpdateOffer $root
                if ($null -eq $offer) {
                    $body = @{ok=$true;available=$false;message=('当前版本：' + (Get-UpdateVersion $root) + '，暂无新版本。')}
                } else {
                    $total = [long]0
                    foreach ($entry in @($offer.Manifest.files)) { $total += [long]$entry.size }
                    $body = @{ok=$true;available=$true;version=$offer.Manifest.to;notes=$offer.Manifest.notes;size=$total}
                }
            } else {
                $offer = Get-UpdateOffer $root
                if ($null -eq $offer) { throw '当前暂无可用更新。' }
                $staged = Stage-UpdateOffer $root $offer
                $body = @{ok=$true;message='更新已验证，即将重启模拟器。'}
            }
            Send-BridgeResponse $stream 200 $body
            if ($staged) { $applyRequested = $true }
        } catch {
            $message = $_.Exception.Message
            try { Send-BridgeResponse $stream 400 @{ok=$false;message=$message} } catch { }
            Write-BridgeLog "请求处理失败：$message"
        } finally {
            $reader.Dispose()
            $stream.Dispose()
            $client.Dispose()
        }
        if ($applyRequested) {
            $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $apply = Join-Path $PSScriptRoot 'apply.ps1'
            $args = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-WindowStyle','Hidden',
                '-File',('"' + $apply + '"'),'-Staging',('"' + $staged + '"'),'-Serial',$Serial,
                '-EmulatorPid',[string]$EmulatorPid,'-Graphics',$Graphics)
            Start-Process -FilePath $powershell -ArgumentList $args -WindowStyle Hidden | Out-Null
            break
        }
    }
} catch { Write-BridgeLog $_.Exception.Message; exit 1 }
finally { $listener.Stop() }
