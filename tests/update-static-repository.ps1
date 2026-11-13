# Integration test for a public, read-only static update repository. All keys,
# files, servers, and installation data below belong only to this test.
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'stage\update\core.ps1')

$testId = [Guid]::NewGuid().ToString('N')
$testName = 'ArtemisOS-static-update-test-' + $testId
$tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
$work = [IO.Path]::GetFullPath((Join-Path $tempRoot $testName))
if (-not $work.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path -Leaf $work) -cne $testName) { throw 'Invalid test directory.' }
$root = Join-Path $work 'installation'
$repository = Join-Path $work 'repository'
$rsa = $null
$servers = @()
$serverStops = @()
$oldCertificateCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
$oldSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
$fixtureTlsKey = $null
$fixtureTlsCertificate = $null

function Assert-True([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAILED: $Name" }
    Write-Host "PASS: $Name"
}
function Assert-Rejected([scriptblock]$Action, [string]$Name) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-True $rejected $Name
}
function Get-BytesHash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Set-RepositoryBase([string]$Value) {
    [IO.File]::WriteAllText((Join-Path $root 'data\update\server.txt'), $Value, [Text.Encoding]::ASCII)
}

# The server accepts one request per connection and records only the request
# path and whether credential-bearing headers were present, never their values.
function Start-TestRepository([string]$Name, [byte[]]$Certificate) {
    $portPath = Join-Path $work ($Name + '.port')
    $logPath = Join-Path $work ($Name + '.log')
    $redirectPath = Join-Path $work ($Name + '.redirect')
    $stopPath = Join-Path $work ($Name + '.stop')
    if ($Certificate) { [IO.File]::WriteAllBytes((Join-Path $work ($Name + '.pfx')), $Certificate) }
    $job = Start-Job -ArgumentList $repository, $portPath, $logPath, $redirectPath, (Join-Path $work ($Name + '.pfx')), $stopPath -ScriptBlock {
        param($repository, $portPath, $logPath, $redirectPath, $certificatePath, $stopPath)
        $listener = $null
        $certificate = $null
        try {
            if ([IO.File]::Exists($certificatePath)) {
                $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
                    $certificatePath, '', [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::DefaultKeySet)
            }
            $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
            $listener.Start()
            [IO.File]::WriteAllText($portPath, [string]([Net.IPEndPoint]$listener.LocalEndpoint).Port)
            while (-not [IO.File]::Exists($stopPath)) {
                if (-not $listener.Pending()) { Start-Sleep -Milliseconds 50; continue }
                $client = $listener.AcceptTcpClient()
                $stream = $null
                $reader = $null
                try {
                    $client.ReceiveTimeout = 10000
                    $client.SendTimeout = 10000
                    $stream = $client.GetStream()
                    if ($certificate) {
                        $stream = [Net.Security.SslStream]::new($stream, $false)
                        $stream.AuthenticateAsServer($certificate, $false, [Security.Authentication.SslProtocols]::Tls12, $false)
                    }
                    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 8192, $true)
                    $line = $reader.ReadLine()
                    if ($line -notmatch '^GET (\S+) HTTP/1\.[01]$') { continue }
                    $path = $matches[1]
                    $questionMark = $path.IndexOf('?')
                    $query = if ($questionMark -ge 0) { $path.Substring($questionMark) } else { '' }
                    if ($questionMark -ge 0) { $path = $path.Substring(0, $questionMark) }
                    $hasCredentials = $false
                    while (($line = $reader.ReadLine()) -and $line.Length -gt 0) {
                        if ($line -match '^(?i:authorization|proxy-authorization|cookie):') { $hasCredentials = $true }
                    }
                    [IO.File]::AppendAllText($logPath, "$path direct=$($query -ceq '?d') credentials=$hasCredentials`n", [Text.Encoding]::ASCII)
                    $status = '404 Not Found'
                    $length = [long]0
                    $chunked = $false
                    $location = $null
                    $file = $null
                    if ($path -match '^/error/manifests/\d+\.\d+\.\d+\.(json|sig)$') {
                        $status = '500 Internal Server Error'
                    } elseif ($path -match '^/redirect/manifests/\d+\.\d+\.\d+\.(json|sig)$') {
                        $status = '302 Found'
                        $location = [IO.File]::ReadAllText($redirectPath)
                    } elseif (($query -eq '' -and $path -match '^/artemis/public/(manifests/\d+\.\d+\.\d+\.(json|sig)|objects/[0-9a-f]{64})$') -or
                        ($query -ceq '?d' -and $path -match '^/(?:prefix|chunked)/sd/test-share/(manifests/\d+\.\d+\.\d+\.(json|sig)|objects/[0-9a-f]{64})$')) {
                        $file = Join-Path $repository ($matches[1].Replace('/', '\'))
                        if ([IO.File]::Exists($file)) {
                            $status = '200 OK'
                            $length = ([IO.FileInfo]$file).Length
                            $chunked = $path.StartsWith('/chunked/')
                        }
                    }
                    $headers = "HTTP/1.1 $status`r`n"
                    if ($chunked) { $headers += "Transfer-Encoding: chunked`r`n" }
                    else { $headers += "Content-Length: $length`r`n" }
                    $headers += "Connection: close`r`n"
                    if ($location) { $headers += "Location: $location`r`n" }
                    $headers += "`r`n"
                    $headerBytes = [Text.Encoding]::ASCII.GetBytes($headers)
                    $stream.Write($headerBytes, 0, $headerBytes.Length)
                    if ($status -eq '200 OK') {
                        $input = [IO.File]::OpenRead($file)
                        try {
                            if ($chunked) {
                                $buffer = New-Object byte[] 65536
                                while (($count = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                                    $head = [Text.Encoding]::ASCII.GetBytes(('{0:x}' -f $count) + "`r`n")
                                    $stream.Write($head, 0, $head.Length)
                                    $stream.Write($buffer, 0, $count)
                                    $tail = [Text.Encoding]::ASCII.GetBytes("`r`n")
                                    $stream.Write($tail, 0, $tail.Length)
                                }
                                $end = [Text.Encoding]::ASCII.GetBytes("0`r`n`r`n")
                                $stream.Write($end, 0, $end.Length)
                            } else { $input.CopyTo($stream) }
                        } finally { $input.Dispose() }
                    }
                    $stream.Flush()
                } catch {
                    # A deliberately rejected TLS connection or disconnected
                    # test client must not stop the fixture server.
                } finally {
                    if ($reader) { $reader.Dispose() }
                    if ($stream) { $stream.Dispose() }
                    $client.Dispose()
                }
            }
        } finally {
            if ($listener) { $listener.Stop() }
            if ($certificate) { $certificate.Dispose() }
        }
    }
    $script:servers += $job
    $script:serverStops += $stopPath
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not [IO.File]::Exists($portPath) -and [DateTime]::UtcNow -lt $deadline) {
        if ($job.State -ne 'Running') { throw 'The fixture server failed to start.' }
        Start-Sleep -Milliseconds 100
    }
    if (-not [IO.File]::Exists($portPath)) { throw 'The fixture server timed out.' }
    return [pscustomobject]@{ Port = [int][IO.File]::ReadAllText($portPath); Log = $logPath; Redirect = $redirectPath }
}

try {
    foreach ($dir in @('update', 'data\update', 'data\avd', 'sdk')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $root $dir))
    }
    foreach ($dir in @('manifests', 'objects')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $repository $dir))
    }
    $originalVersion = "[ArtemisOS]`nVersion=0.3.0`n"
    $versionPath = Join-Path $root 'version.ini'
    [IO.File]::WriteAllText($versionPath, $originalVersion, [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $root 'data\avd\sentinel.txt'), 'test fixture', [Text.Encoding]::ASCII)
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(2048)
    $rsa.PersistKeyInCsp = $false
    [IO.File]::WriteAllText((Join-Path $root 'update\trusted-key.xml'), $rsa.ToXmlString($false), [Text.Encoding]::ASCII)

    $versionBytes = [Text.Encoding]::ASCII.GetBytes("[ArtemisOS]`nVersion=0.3.1`n")
    $largeBytes = New-Object byte[] (5 * 1024 * 1024 + 123)
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($largeBytes) } finally { $random.Dispose() }
    $versionHash = Get-BytesHash $versionBytes
    $largeHash = Get-BytesHash $largeBytes
    [IO.File]::WriteAllBytes((Join-Path $repository ('objects\' + $versionHash)), $versionBytes)
    $largePath = Join-Path $repository ('objects\' + $largeHash)
    [IO.File]::WriteAllBytes($largePath, $largeBytes)
    $manifest = [ordered]@{
        schema = 1; product = 'ArtemisOS-15'; from = '0.3.0'; to = '0.3.1'; notes = 'test'
        files = @(
            [ordered]@{ path = 'version.ini'; base_sha256 = (Get-FileHash -LiteralPath $versionPath -Algorithm SHA256).Hash.ToLowerInvariant(); sha256 = $versionHash; size = $versionBytes.Length },
            [ordered]@{ path = 'sdk/test-large.bin'; base_sha256 = '-'; sha256 = $largeHash; size = $largeBytes.Length }
        )
    }
    $manifestBytes = [Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 5))
    $signatureBytes = [Text.Encoding]::ASCII.GetBytes([Convert]::ToBase64String($rsa.SignData($manifestBytes, 'SHA256')))
    $manifestPath = Join-Path $repository 'manifests\0.3.0.json'
    [IO.File]::WriteAllBytes($manifestPath, $manifestBytes)
    $signaturePath = Join-Path $repository 'manifests\0.3.0.sig'
    [IO.File]::WriteAllBytes($signaturePath, $signatureBytes)

    # The production downloader now requires HTTPS even on loopback. Pin a
    # fresh fixture certificate in this process only; do not weaken production.
    $fixtureTlsKey = [Security.Cryptography.RSA]::Create(2048)
    $fixtureRequest = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=localhost', $fixtureTlsKey, [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $fixtureTlsCertificate = $fixtureRequest.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1),[DateTimeOffset]::UtcNow.AddMinutes(20))
    Add-Type -TypeDefinition @'
using System;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class ArtemisStaticTestCertificate {
    public static string ExpectedThumbprint;
    public static bool Validate(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors errors) {
        return certificate != null && String.Equals(certificate.GetCertHashString(), ExpectedThumbprint, StringComparison.OrdinalIgnoreCase);
    }
}
'@
    [ArtemisStaticTestCertificate]::ExpectedThumbprint = $fixtureTlsCertificate.Thumbprint
    [Net.ServicePointManager]::ServerCertificateValidationCallback = [Delegate]::CreateDelegate(
        [Net.Security.RemoteCertificateValidationCallback], [ArtemisStaticTestCertificate].GetMethod('Validate'))
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $fixturePfx = $fixtureTlsCertificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx)
    $http = Start-TestRepository 'https-main' $fixturePfx
    $httpBase = "https://127.0.0.1:$($http.Port)/artemis/public"
    Set-RepositoryBase $httpBase
    $base = Get-UpdateBaseUri $root
    Assert-True ($base.AbsoluteUri -eq ($httpBase + '/')) 'loopback base retains its path prefix'
    $offer = Get-UpdateOffer $root
    Assert-True ($offer.Manifest.to -eq '0.3.1') 'signed manifest and signature from static repository'
    $staged = Stage-UpdateOffer $root $offer
    Assert-True ((Get-Item -LiteralPath (Join-Path $staged $largeHash)).Length -eq $largeBytes.Length -and
        (Get-FileHash -LiteralPath (Join-Path $staged $largeHash) -Algorithm SHA256).Hash.ToLowerInvariant() -eq $largeHash) 'stream and hash a 5 MiB object'
    Assert-True ([IO.File]::ReadAllText($versionPath) -eq $originalVersion -and
        [IO.File]::ReadAllText((Join-Path $root 'data\avd\sentinel.txt')) -eq 'test fixture') 'staging does not change installation or instance data'

    $shareBase = "https://127.0.0.1:$($http.Port)/prefix/sd/test-share?d"
    Set-RepositoryBase $shareBase
    $shareUri = Get-UpdateBaseUri $root
    Assert-True ($shareUri.AbsoluteUri -eq "https://127.0.0.1:$($http.Port)/prefix/sd/test-share/?d") 'explicit OpenList share base is normalized'
    $shareOffer = Get-UpdateOffer $root
    $shareStaged = Stage-UpdateOffer $root $shareOffer
    Assert-True ($shareOffer.Manifest.to -eq '0.3.1' -and
        (Get-FileHash -LiteralPath (Join-Path $shareStaged $largeHash) -Algorithm SHA256).Hash.ToLowerInvariant() -eq $largeHash) 'OpenList direct mode fetches and verifies manifest, signature, and large object'
    $shareRequests = [IO.File]::ReadAllText($http.Log)
    Assert-True ($shareRequests -match '(?m)^/prefix/sd/test-share/manifests/0\.3\.0\.json direct=True credentials=False' -and
        $shareRequests -match '(?m)^/prefix/sd/test-share/manifests/0\.3\.0\.sig direct=True credentials=False' -and
        $shareRequests -match "(?m)^/prefix/sd/test-share/objects/$largeHash direct=True credentials=False") 'only the direct-read marker is added to each share request'
    Set-RepositoryBase "https://127.0.0.1:$($http.Port)/chunked/sd/test-share?d"
    $chunkedOffer = Get-UpdateOffer $root
    $chunkedStaged = Stage-UpdateOffer $root $chunkedOffer
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $chunkedStaged $largeHash) -Algorithm SHA256).Hash.ToLowerInvariant() -eq $largeHash) 'chunked responses without Content-Length are streamed and verified'
    Set-RepositoryBase $httpBase

    [IO.File]::WriteAllText($versionPath, "[ArtemisOS]`nVersion=0.2.0`n", [Text.Encoding]::ASCII)
    $missingManifestError = ''
    try { $null = Get-UpdateOffer $root } catch { $missingManifestError = $_.Exception.Message }
    Assert-True ($missingManifestError -eq '更新清单不存在，无法确认是否有新版本。') "missing manifest reports an error instead of no update (404): $missingManifestError"
    [IO.File]::WriteAllText($versionPath, $originalVersion, [Text.Encoding]::ASCII)
    [IO.File]::WriteAllBytes($manifestPath, [Text.Encoding]::UTF8.GetBytes(([Text.Encoding]::UTF8.GetString($manifestBytes) + ' ')))
    Assert-Rejected { Get-UpdateOffer $root } 'tampered manifest fails signature verification'
    [IO.File]::WriteAllBytes($manifestPath, $manifestBytes)
    $largeBytes[100] = $largeBytes[100] -bxor 1
    [IO.File]::WriteAllBytes($largePath, $largeBytes)
    Assert-Rejected { Stage-UpdateOffer $root $offer } 'same-sized object with wrong hash is rejected'
    $largeBytes[100] = $largeBytes[100] -bxor 1
    [IO.File]::WriteAllBytes($largePath, $largeBytes)
    [IO.File]::AppendAllText($versionPath, "`n", [Text.Encoding]::ASCII)
    Assert-Rejected { Stage-UpdateOffer $root $offer } 'changed installation baseline is rejected'
    [IO.File]::WriteAllText($versionPath, $originalVersion, [Text.Encoding]::ASCII)

    $sentinel = [ordered]@{ schema = 1; product = 'ArtemisOS-15'; from = '0.3.0'; to = '0.3.0'; notes = ''; files = @() }
    $sentinelBytes = [Text.Encoding]::UTF8.GetBytes(($sentinel | ConvertTo-Json -Depth 5))
    $sentinelSignature = [Text.Encoding]::ASCII.GetBytes([Convert]::ToBase64String($rsa.SignData($sentinelBytes, 'SHA256')))
    [IO.File]::WriteAllBytes($manifestPath, $sentinelBytes)
    [IO.File]::WriteAllBytes($signaturePath, $sentinelSignature)
    Assert-True ($null -eq (Get-UpdateOffer $root)) 'valid signed no-update marker means no update'
    Assert-Rejected { Verify-UpdateManifest $root $sentinelBytes $sentinelSignature } 'no-update marker is rejected by installation verification'
    [IO.File]::WriteAllBytes($manifestPath, [Text.Encoding]::UTF8.GetBytes(([Text.Encoding]::UTF8.GetString($sentinelBytes) + ' ')))
    Assert-Rejected { Get-UpdateOffer $root } 'tampered no-update marker is rejected'
    $sentinel.product = 'Not-ArtemisOS'
    $wrongProduct = [Text.Encoding]::UTF8.GetBytes(($sentinel | ConvertTo-Json -Depth 5))
    $wrongProductSignature = [Text.Encoding]::ASCII.GetBytes([Convert]::ToBase64String($rsa.SignData($wrongProduct, 'SHA256')))
    Assert-Rejected { Verify-UpdateManifest $root $wrongProduct $wrongProductSignature -AllowNoUpdate } 'signed marker for another product is rejected'
    $sentinel.product = 'ArtemisOS-15'
    $sentinel.from = '0.2.9'
    $sentinel.to = '0.2.9'
    $wrongVersion = [Text.Encoding]::UTF8.GetBytes(($sentinel | ConvertTo-Json -Depth 5))
    $wrongVersionSignature = [Text.Encoding]::ASCII.GetBytes([Convert]::ToBase64String($rsa.SignData($wrongVersion, 'SHA256')))
    Assert-Rejected { Verify-UpdateManifest $root $wrongVersion $wrongVersionSignature -AllowNoUpdate } 'signed marker for another installed version is rejected'
    $sentinel.from = '0.3.0'
    $sentinel.to = '0.3.0'
    $sentinel.files = $null
    $nullFiles = [Text.Encoding]::UTF8.GetBytes(($sentinel | ConvertTo-Json -Depth 5))
    $nullFilesSignature = [Text.Encoding]::ASCII.GetBytes([Convert]::ToBase64String($rsa.SignData($nullFiles, 'SHA256')))
    Assert-Rejected { Verify-UpdateManifest $root $nullFiles $nullFilesSignature -AllowNoUpdate } 'marker must contain an explicit empty file array'
    $sentinel.files = @()
    $sentinel.to = '0.3.1'
    $emptyUpdate = [Text.Encoding]::UTF8.GetBytes(($sentinel | ConvertTo-Json -Depth 5))
    $emptyUpdateSignature = [Text.Encoding]::ASCII.GetBytes([Convert]::ToBase64String($rsa.SignData($emptyUpdate, 'SHA256')))
    Assert-Rejected { Verify-UpdateManifest $root $emptyUpdate $emptyUpdateSignature -AllowNoUpdate } 'signed future version with empty files is rejected'
    $sentinel.to = '0.3.0'
    $sentinel.files = @([ordered]@{ path = 'version.ini'; base_sha256 = '-'; sha256 = ('a' * 64); size = 1 })
    $nonemptyMarker = [Text.Encoding]::UTF8.GetBytes(($sentinel | ConvertTo-Json -Depth 5))
    $nonemptyMarkerSignature = [Text.Encoding]::ASCII.GetBytes([Convert]::ToBase64String($rsa.SignData($nonemptyMarker, 'SHA256')))
    Assert-Rejected { Verify-UpdateManifest $root $nonemptyMarker $nonemptyMarkerSignature -AllowNoUpdate } 'same-version marker containing files is rejected'
    [IO.File]::WriteAllBytes($manifestPath, $manifestBytes)
    [IO.File]::WriteAllBytes($signaturePath, $signatureBytes)
    Set-RepositoryBase "https://127.0.0.1:$($http.Port)/error"
    Assert-Rejected { Get-UpdateOffer $root } 'HTTP 500 is an error rather than no update'

    Set-RepositoryBase 'https://example.invalid/artemis/public'
    $httpsBase = Get-UpdateBaseUri $root
    Assert-True ($httpsBase.AbsoluteUri -eq 'https://example.invalid/artemis/public/') 'HTTPS base retains its path prefix'
    foreach ($invalid in @('https://example.invalid/public?probe=1', 'https://example.invalid/public#probe',
            'https://placeholder@example.invalid/public', 'http://192.0.2.1/public',
            'https://example.invalid/public?d', 'https://example.invalid/sd/share?D',
            'https://example.invalid/sd/share?d=', 'https://example.invalid/sd/share?%64', 'https://example.invalid/sd/share?d&probe=1',
            'https://example.invalid/sd/share/child?d', 'https://placeholder@example.invalid/sd/share?d',
            'https://example.invalid/sd/share?d#probe', 'http://192.0.2.1/sd/share?d')) {
        Set-RepositoryBase $invalid
        Assert-Rejected { Get-UpdateBaseUri $root } 'userinfo, query, fragment, or non-loopback HTTP rejected'
    }

    # HTTPS redirects are allowed, but plaintext destinations remain forbidden.
    [IO.File]::WriteAllText($http.Redirect, "http://127.0.0.1:$($http.Port)/outside-prefix", [Text.Encoding]::ASCII)
    Set-RepositoryBase "https://127.0.0.1:$($http.Port)/redirect"
    Assert-Rejected { Get-UpdateOffer $root } 'plaintext redirect from HTTPS repository is rejected'
    $requests = [IO.File]::ReadAllText($http.Log)
    Assert-True ($requests -notmatch '(?m)^/outside-prefix ' -and $requests -notmatch 'credentials=True') 'no redirect outside prefix or credential headers'

    # Real HTTPS transport uses a freshly generated certificate and a callback
    # pinned to that certificate only for this test process. It never alters an
    # OS trust store. Windows PowerShell 5.1 lacks CertificateRequest on some
    # systems. The test uses Windows PowerShell's certificate callback; newer
    # PowerShell versions exercise the loopback HTTP and validation cases.
    $certificateType = 'System.Security.Cryptography.X509Certificates.CertificateRequest' -as [type]
    if ($certificateType -and $PSVersionTable.PSEdition -eq 'Desktop') {
        $tlsKey = [Security.Cryptography.RSA]::Create(2048)
        $certificate = $null
        try {
            $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
                'CN=localhost', $tlsKey, [Security.Cryptography.HashAlgorithmName]::SHA256,
                [Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $san = [Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
            $san.AddDnsName('localhost')
            $san.AddIpAddress([Net.IPAddress]::Loopback)
            $request.CertificateExtensions.Add($san.Build())
            $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1), [DateTimeOffset]::UtcNow.AddMinutes(10))
            if (-not ('ArtemisStaticTestCertificate' -as [type])) {
                Add-Type -TypeDefinition @'
using System;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class ArtemisStaticTestCertificate {
    public static string ExpectedThumbprint;
    public static bool Validate(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors errors) {
        return certificate != null && String.Equals(certificate.GetCertHashString(), ExpectedThumbprint, StringComparison.OrdinalIgnoreCase);
    }
}
'@
            }
            [ArtemisStaticTestCertificate]::ExpectedThumbprint = $certificate.Thumbprint
            [Net.ServicePointManager]::ServerCertificateValidationCallback = [Delegate]::CreateDelegate(
                [Net.Security.RemoteCertificateValidationCallback], [ArtemisStaticTestCertificate].GetMethod('Validate'))
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $pfx = $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx)
            $https = Start-TestRepository 'https' $pfx
            Set-RepositoryBase "https://127.0.0.1:$($https.Port)/artemis/public"
            $tlsOffer = Get-UpdateOffer $root
            Assert-True ($tlsOffer.Manifest.to -eq '0.3.1') 'HTTPS static repository resolves prefixed signed manifest'
            $tlsStaged = Stage-UpdateOffer $root $tlsOffer
            Assert-True ((Get-FileHash -LiteralPath (Join-Path $tlsStaged $largeHash) -Algorithm SHA256).Hash.ToLowerInvariant() -eq $largeHash) 'HTTPS object downloaded and verified'
            Set-RepositoryBase "https://127.0.0.1:$($https.Port)/prefix/sd/test-share?d"
            $tlsShareOffer = Get-UpdateOffer $root
            $tlsShareStaged = Stage-UpdateOffer $root $tlsShareOffer
            Assert-True ((Get-FileHash -LiteralPath (Join-Path $tlsShareStaged $largeHash) -Algorithm SHA256).Hash.ToLowerInvariant() -eq $largeHash) 'HTTPS OpenList direct mode downloads and verifies objects'
            $httpBefore = [IO.File]::ReadAllText($http.Log)
            [IO.File]::WriteAllText($https.Redirect, "http://127.0.0.1:$($http.Port)/outside-prefix", [Text.Encoding]::ASCII)
            Set-RepositoryBase "https://127.0.0.1:$($https.Port)/redirect"
            Assert-Rejected { Get-UpdateOffer $root } 'HTTPS to HTTP redirect is rejected'
            Assert-True ([IO.File]::ReadAllText($http.Log) -eq $httpBefore) 'HTTPS downgrade did not contact loopback target'
            Assert-True ([IO.File]::ReadAllText($https.Log) -notmatch 'credentials=True') 'HTTPS requests carry no credential headers'
        } finally {
            [Net.ServicePointManager]::ServerCertificateValidationCallback = $oldCertificateCallback
            [Net.ServicePointManager]::SecurityProtocol = $oldSecurityProtocol
            if ($certificate) { $certificate.Dispose() }
            $tlsKey.Dispose()
        }
    } else {
        Write-Host 'SKIP: HTTPS transport requires Windows PowerShell 5.1 with CertificateRequest support.'
    }
} finally {
    [Net.ServicePointManager]::ServerCertificateValidationCallback = $oldCertificateCallback
    [Net.ServicePointManager]::SecurityProtocol = $oldSecurityProtocol
    foreach ($stopPath in $serverStops) { [IO.File]::WriteAllText($stopPath, 'stop', [Text.Encoding]::ASCII) }
    foreach ($job in $servers) {
        if (-not (Wait-Job -Job $job -Timeout 5)) { Stop-Job -Job $job -ErrorAction SilentlyContinue }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
    if ($rsa) { $rsa.Dispose() }
    if ($fixtureTlsCertificate) { $fixtureTlsCertificate.Dispose() }
    if ($fixtureTlsKey) { $fixtureTlsKey.Dispose() }
    # Only remove the unique, non-reparse-point fixture created by this run.
    if (Test-Path -LiteralPath $work) {
        $item = Get-Item -LiteralPath $work -Force
        if ([IO.Path]::GetFullPath($item.FullName) -ieq $work -and
            $work.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            $item.Name -ceq $testName -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Remove-Item -LiteralPath $work -Recurse -Force
        }
    }
}
