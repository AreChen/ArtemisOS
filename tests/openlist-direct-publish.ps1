$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop
$project = Split-Path -Parent $PSScriptRoot
Add-Type -Path (Join-Path $PSScriptRoot 'fixtures\openlist-publish-tls-fixture.cs')
$oldCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
$oldProtocol = [Net.ServicePointManager]::SecurityProtocol
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::ServerCertificateValidationCallback = [Delegate]::CreateDelegate(
    [Net.Security.RemoteCertificateValidationCallback], [ArtemisPublishTlsFixture.Certificates].GetMethod('Validate'))
$fixture = [IO.Path]::GetFullPath((Join-Path $project ('build\openlist-direct-test-' + [Guid]::NewGuid().ToString('N'))))
$repository = Join-Path $fixture 'repository'
[void][IO.Directory]::CreateDirectory((Join-Path $repository 'manifests'))
[void][IO.Directory]::CreateDirectory((Join-Path $repository 'objects'))
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(2048)
$rsa.PersistKeyInCsp = $false
$publicKey = Join-Path $fixture 'public.xml'
[IO.File]::WriteAllText($publicKey, $rsa.ToXmlString($false))
$credential = New-Object Management.Automation.PSCredential('fixture', (ConvertTo-SecureString 'fixture' -AsPlainText -Force))
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Sign-FixtureManifest([string]$Version, $Manifest) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Manifest | ConvertTo-Json -Depth 8))
    [IO.File]::WriteAllBytes((Join-Path $repository "manifests\$Version.json"), $bytes)
    [IO.File]::WriteAllText((Join-Path $repository "manifests\$Version.sig"), [Convert]::ToBase64String($rsa.SignData($bytes, 'SHA256')))
}
function Invoke-FixturePublish($Api, [switch]$Sentinel, [switch]$ExpectFailure) {
    $arguments = @{Repository=$repository; TargetVersion='0.3.6'; RemoteRoot='/ota';
        Server=[Uri]$Api.BaseUri; PublicBase=[Uri]($Api.BaseUri + 'd/fixture/ota/');
        Credential=$credential; PublicKeyPath=$publicKey}
    if ($Sentinel) { $arguments.SentinelOnly=$true } else { $arguments.FromVersion='0.3.5' }
    $output = New-Object 'System.Collections.Generic.List[string]'
    $failed = $false
    try { & (Join-Path $project 'tools\Publish-OpenList.ps1') @arguments 6>&1 | ForEach-Object { [void]$output.Add([string]$_) } }
    catch { $failed=$true; if (-not $ExpectFailure) { throw } }
    if ($ExpectFailure) {
        Assert $failed ('Publisher accepted a controlled verification failure: ' + $Api.Fault)
        Assert (@($output | Where-Object { $_ -like 'Published *' }).Count -eq 0) 'Publisher reported success before final verification.'
    } else {
        Assert (-not $failed) 'Publisher unexpectedly failed.'
        Assert (@($output | Where-Object { $_ -like 'Published *' }).Count -eq 1) 'Publisher did not report verified completion once.'
    }
}
function With-Fixture([scriptblock]$Action) {
    $api = New-Object ArtemisPublishTlsFixture.Server
    $cdn = New-Object ArtemisPublishTlsFixture.Server($api)
    $api.DownloadTarget=$cdn
    try { & $Action $api $cdn }
    finally { $cdn.Dispose(); $api.Dispose() }
}
try {
    Sign-FixtureManifest '0.3.6' ([ordered]@{schema=1;product='ArtemisOS-15';from='0.3.6';to='0.3.6';files=@()})
    $object = [Text.Encoding]::UTF8.GetBytes('controlled small OTA object')
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash=[BitConverter]::ToString($sha.ComputeHash($object)).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    [IO.File]::WriteAllBytes((Join-Path $repository "objects\$hash"), $object)
    Sign-FixtureManifest '0.3.5' ([ordered]@{schema=1;product='ArtemisOS-15';from='0.3.5';to='0.3.6';files=@(@{path='version.ini';sha256=$hash;size=$object.Length})})

    # Removing credential isolation or complete pair readback must fail this real TLS test.
    With-Fixture { param($api,$cdn)
        $old = [Text.Encoding]::UTF8.GetBytes('{"schema":1,"product":"ArtemisOS-15","from":"0.3.5","to":"0.3.5","files":[]}')
        $api.Files['/ota/manifests/0.3.5.json']=$old
        $api.Files['/ota/manifests/0.3.5.sig']=[Text.Encoding]::ASCII.GetBytes([Convert]::ToBase64String($rsa.SignData($old,'SHA256')))
        Invoke-FixturePublish $api
        $writes=@($api.Requests | Where-Object { $_.Method -eq 'PUT' })
        Assert (($writes.FilePath -join ',') -ceq "/ota/objects/$hash,/ota/manifests/0.3.6.json,/ota/manifests/0.3.6.sig,/ota/manifests/0.3.5.json,/ota/manifests/0.3.5.sig") 'Objects and target sentinel must precede the source update pair.'
        Assert (@($writes | Where-Object { -not $_.Authorization }).Count -eq 0) 'An upload lacked explicit authentication.'
        Assert (@($api.Requests | Where-Object { $_.Cookie -or $_.ProxyAuthorization }).Count -eq 0) 'API transport reused cookies or proxy credentials.'
        Assert (@($api.Requests | Where-Object { $_.Path -like '/d/*' -and ($_.Authorization -or $_.Cookie -or $_.ProxyAuthorization) }).Count -eq 0) 'Anonymous direct download carried publisher credentials.'
        Assert ($cdn.Requests.Count -gt 0) 'Real updater download transport did not follow the CDN redirect.'
        Assert (@($cdn.Requests | Where-Object { $_.Authorization -or $_.Cookie -or $_.ProxyAuthorization }).Count -eq 0) 'The CDN received publisher credentials or cookies.'
        $tail=@($cdn.Requests | Select-Object -Last 4)
        Assert (($tail.Path -join ',') -ceq '/blob/manifests/0.3.5.json,/blob/manifests/0.3.5.sig,/blob/manifests/0.3.6.json,/blob/manifests/0.3.6.sig') 'Final verification did not read both full manifest/signature pairs.'
        foreach ($entry in $writes) {
            $relative=$entry.FilePath.Substring('/ota/'.Length)
            Assert ([Convert]::ToBase64String($api.Files[$entry.FilePath]) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $repository $relative)))) 'Uploaded content differs from the local repository.'
        }
        Invoke-FixturePublish $api
        Assert (@($api.Requests | Where-Object { $_.Method -eq 'PUT' }).Count -eq 5) 'Retry overwrote an existing identical source update.'
    }
    With-Fixture { param($api,$cdn)
        Invoke-FixturePublish $api -Sentinel
        Invoke-FixturePublish $api -Sentinel
        Assert (@($api.Requests | Where-Object { $_.Method -eq 'PUT' }).Count -eq 2) 'Sentinel retry rewrote existing signed files.'
    }
    foreach ($fault in @('FinalSignature','CorruptUpload','HtmlManifest','UploadRedirect')) {
        With-Fixture { param($api,$cdn)
            $api.Fault=$fault
            Invoke-FixturePublish $api -Sentinel -ExpectFailure
            Assert (@($cdn.Requests | Where-Object { $_.Path -eq '/credential-leak' }).Count -eq 0) 'An authenticated upload followed a redirect.'
            if ($fault -eq 'FinalSignature') {
                Assert (@($api.Requests | Where-Object { $_.Method -eq 'PUT' }).Count -eq 2) 'Final signature failure must happen after both files were independently verified.'
            }
        }
    }
    # Identical source JSON with a damaged existing signature must never be repaired by overwriting it.
    With-Fixture { param($api,$cdn)
        $api.Fault='DamagedSource'
        $api.Files['/ota/manifests/0.3.5.json']=[IO.File]::ReadAllBytes((Join-Path $repository 'manifests\0.3.5.json'))
        $api.Files['/ota/manifests/0.3.5.sig']=[Text.Encoding]::ASCII.GetBytes('damaged existing signature')
        Invoke-FixturePublish $api -ExpectFailure
        Assert (@($api.Requests | Where-Object { $_.Method -eq 'PUT' }).Count -eq 0) 'A damaged existing signed source pair allowed writes.'
    }
    With-Fixture { param($api,$cdn)
        $api.Fault='ExistingSourceUpdate'
        $other = [Text.Encoding]::UTF8.GetBytes('{"schema":1,"product":"ArtemisOS-15","from":"0.3.5","to":"0.3.7","files":[{"path":"version.ini"}]}')
        $api.Files['/ota/manifests/0.3.5.json']=$other
        $api.Files['/ota/manifests/0.3.5.sig']=[Text.Encoding]::ASCII.GetBytes([Convert]::ToBase64String($rsa.SignData($other,'SHA256')))
        Invoke-FixturePublish $api -ExpectFailure
        Assert (@($api.Requests | Where-Object { $_.Method -eq 'PUT' }).Count -eq 0) 'An existing valid source update was overwritten.'
    }
    # Even a correctly hashed object cannot be an HTML login page disguised as octet-stream.
    $html=[Text.Encoding]::ASCII.GetBytes('<html>login page</html>')
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $htmlHash=[BitConverter]::ToString($sha.ComputeHash($html)).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    [IO.File]::WriteAllBytes((Join-Path $repository "objects\$htmlHash"),$html)
    Sign-FixtureManifest '0.3.5' ([ordered]@{schema=1;product='ArtemisOS-15';from='0.3.5';to='0.3.6';files=@(@{path='version.ini';sha256=$htmlHash;size=$html.Length})})
    With-Fixture { param($api,$cdn)
        $api.Fault='HtmlObject'
        Invoke-FixturePublish $api -ExpectFailure
        Assert (@($api.Requests | Where-Object { $_.Method -eq 'PUT' }).Count -eq 1) 'An HTML object allowed manifest publication.'
    }
    Write-Host 'Passed: direct TLS publication, authenticated upload isolation, anonymous CDN redirects, signed final readback, ordering, sentinel retry and fail-closed publication.'
} finally {
    [Net.ServicePointManager]::ServerCertificateValidationCallback=$oldCallback
    [Net.ServicePointManager]::SecurityProtocol=$oldProtocol
    $rsa.Dispose()
    $build=[IO.Path]::GetFullPath((Join-Path $project 'build')) + [IO.Path]::DirectorySeparatorChar
    if (-not $fixture.StartsWith($build,[StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid fixture cleanup path.' }
    if ([IO.Directory]::Exists($fixture)) { [IO.Directory]::Delete($fixture,$true) }
}
