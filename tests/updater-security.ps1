$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'stage\update\core.ps1')
$fixture = Join-Path $project ('build\security-test-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'update'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'data\update\pending'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'data\avd'))
[IO.File]::WriteAllText((Join-Path $fixture 'version.ini'), "[ArtemisOS]`nVersion=0.3.0`n", [Text.Encoding]::ASCII)
[IO.File]::WriteAllText((Join-Path $fixture 'launch.ps1'), 'original launcher', [Text.Encoding]::ASCII)
[IO.File]::WriteAllText((Join-Path $fixture 'data\avd\sentinel.txt'), 'private user data', [Text.Encoding]::ASCII)
Copy-Item -LiteralPath (Join-Path $project 'stage\update\recovery.ps1') -Destination (Join-Path $fixture 'update\recovery.ps1')
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(2048)
$rsa.PersistKeyInCsp = $false
[IO.File]::WriteAllText((Join-Path $fixture 'update\trusted-key.xml'), $rsa.ToXmlString($false))
function Assert-Rejected([scriptblock]$Action, [string]$Name) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw "安全测试未拒绝：$Name" }
    Write-Host "通过：$Name"
}
function New-SignedManifest([string]$Path = 'version.ini', [string]$From = '0.3.0') {
    $manifest = [ordered]@{
        schema=1; product='ArtemisOS-15'; from=$From; to='0.3.1'; notes='test'
        files=@([ordered]@{path=$Path;base_sha256=('-' * 1);sha256=('a' * 64);size=3})
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 5))
    $signature = [Text.Encoding]::ASCII.GetBytes([Convert]::ToBase64String($rsa.SignData($bytes, 'SHA256')))
    return [pscustomobject]@{Bytes=$bytes;Signature=$signature}
}
try {
    $valid = New-SignedManifest
    [void](Verify-UpdateManifest $fixture $valid.Bytes $valid.Signature)
    Write-Host '通过：有效签名和版本。'
    $altered = [byte[]]$valid.Bytes.Clone()
    $altered[0] = $altered[0] -bxor 1
    Assert-Rejected { Verify-UpdateManifest $fixture $altered $valid.Signature } '签名内容被篡改'
    $wrongVersion = New-SignedManifest -From '0.2.9'
    Assert-Rejected { Verify-UpdateManifest $fixture $wrongVersion.Bytes $wrongVersion.Signature } '来源版本不匹配'
    foreach ($path in @('../data/avd/sentinel.txt', 'data/avd/sentinel.txt', 'update/recovery.ps1')) {
        $invalid = New-SignedManifest -Path $path
        Assert-Rejected { Verify-UpdateManifest $fixture $invalid.Bytes $invalid.Signature } "禁止更新路径 $path"
    }
    $config = Join-Path $fixture 'data\update\server.txt'
    [IO.File]::WriteAllText($config, 'http://192.168.1.1/', [Text.Encoding]::ASCII)
    Assert-Rejected { Get-UpdateBaseUri $fixture } '非本机明文 HTTP'
    [IO.File]::WriteAllText($config, 'http://127.0.0.1:18765/', [Text.Encoding]::ASCII)
    [void](Get-UpdateBaseUri $fixture)
    $pending = Join-Path $fixture 'data\update\pending'
    Copy-Item -LiteralPath (Join-Path $fixture 'launch.ps1') -Destination (Join-Path $pending '0000.bak')
    $hash = (Get-FileHash -LiteralPath (Join-Path $pending '0000.bak') -Algorithm SHA256).Hash.ToLowerInvariant()
    $journal = [ordered]@{schema=1;files=@(
        [ordered]@{path='launch.ps1';existed=$true;backup='0000.bak';sha256=$hash},
        [ordered]@{path='update/test-marker.txt';existed=$false;backup='0001.bak';sha256='-'}
    )} | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText((Join-Path $pending 'transaction.json'), $journal)
    [IO.File]::WriteAllText((Join-Path $pending 'applying.flag'), '1')
    [IO.File]::WriteAllText((Join-Path $fixture 'launch.ps1'), 'partially updated')
    [IO.File]::WriteAllText((Join-Path $fixture 'update\test-marker.txt'), 'new')
    & (Join-Path $fixture 'update\recovery.ps1')
    if ([IO.File]::ReadAllText((Join-Path $fixture 'launch.ps1')) -ne 'original launcher' -or
        (Test-Path -LiteralPath (Join-Path $fixture 'update\test-marker.txt')) -or
        [IO.File]::ReadAllText((Join-Path $fixture 'data\avd\sentinel.txt')) -ne 'private user data') {
        throw '中断恢复结果不正确。'
    }
    Write-Host '通过：中断恢复并保留用户数据。'
} finally { $rsa.Dispose() }
