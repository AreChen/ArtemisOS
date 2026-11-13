# A real TLS redirect must return signed bytes, never redirect HTML. Regressions
# in the downloader must fail before any installer or user instance is touched.
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'stage\update\core.ps1')
Add-Type -Path (Join-Path $PSScriptRoot 'fixtures\ota-tls-fixture.cs')
$oldValidation = [Net.ServicePointManager]::ServerCertificateValidationCallback
$oldProtocol = [Net.ServicePointManager]::SecurityProtocol
$servers = @()
$work=Join-Path $project ('build\ota-https-fixture-'+[guid]::NewGuid().ToString('N'))
function Assert([bool]$Value,[string]$Label) { if(-not $Value){throw "FAIL: $Label"}; Write-Host "PASS: $Label" }
function Rejected([scriptblock]$Action,[string]$Label,[string]$ReasonPattern='') {
    $failed=$false;$reason=''
    try{& $Action|Out-Null}catch{$failed=$true;$reason=$_.Exception.Message}
    Assert ($failed -and (-not $ReasonPattern -or $reason -match $ReasonPattern)) $Label
}
function Bytes([string]$Text) { return ,[Text.Encoding]::UTF8.GetBytes($Text) }
function Hash([byte[]]$Value) { $sha=[Security.Cryptography.SHA256]::Create();try{return [BitConverter]::ToString($sha.ComputeHash($Value)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()} }
try {
    $origin = New-Object ArtemisOtaTlsFixture.Server; $servers += $origin
    $cdn = New-Object ArtemisOtaTlsFixture.Server; $servers += $cdn
    [Net.ServicePointManager]::ServerCertificateValidationCallback=[Delegate]::CreateDelegate([Net.Security.RemoteCertificateValidationCallback],[ArtemisOtaTlsFixture.TestCertificates].GetMethod('Validate'))
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $cdn.Add('/file?temporary=opaque',200,(Bytes 'signed file bytes'),'application/octet-stream',$null)
    foreach($status in @(301,302,303,307,308)) {
        $origin.Add("/redirect-$status",$status,(Bytes '<html>redirect</html>'),'text/html',($cdn.BaseUri.Replace('127.0.0.1','localhost')+'file?temporary=opaque'))
        $actual=Read-UpdateBytes ([uri]($origin.BaseUri+"redirect-$status")) 1024
        Assert ([Text.Encoding]::UTF8.GetString($actual) -ceq 'signed file bytes') "HTTPS $status returns final bytes across hostnames"
    }
    Assert (@($cdn.Requests|Where-Object{$_.Authorization -or $_.Cookie -or $_.ProxyAuthorization}).Count -eq 0) 'no credentials or redirect cookies reach CDN'
    $origin.Add('/downgrade',302,(Bytes ''),'text/html','http://127.0.0.1:1/leak')
    Rejected {Read-UpdateBytes ([uri]($origin.BaseUri+'downgrade')) 1024} 'reject HTTPS to HTTP downgrade' 'HTTPS'
    $origin.Add('/cycle-a',302,(Bytes ''),'text/html','/cycle-b');$origin.Add('/cycle-b',308,(Bytes ''),'text/html','/cycle-a')
    Rejected {Read-UpdateBytes ([uri]($origin.BaseUri+'cycle-a')) 1024} 'reject redirect cycle'
    for($i=0;$i -lt 7;$i++){$origin.Add("/long-$i",302,(Bytes ''),'text/html',("/long-"+($i+1)))}
    $before=@($origin.Requests).Count
    Rejected {Read-UpdateBytes ([uri]($origin.BaseUri+'long-0')) 1024} 'reject redirect count beyond five'
    Assert ((@($origin.Requests).Count-$before) -eq 6) 'sixth redirect is rejected before seventh request'
    $origin.Add('/missing-location',302,(Bytes '<html>redirect</html>'),'text/html',$null)
    Rejected {Read-UpdateBytes ([uri]($origin.BaseUri+'missing-location')) 1024} 'reject missing Location'
    foreach($status in @(204,206,300,304,400,401,403,404,500)) {
        $origin.Add("/status-$status",$status,(Bytes 'error'),'text/plain',$null)
        Rejected {Read-UpdateBytes ([uri]($origin.BaseUri+"status-$status")) 1024} "reject non-file HTTP $status"
    }
    foreach($type in @('text/html','application/xhtml+xml','application/octet-stream')) {
        $route='/html-'+[guid]::NewGuid().ToString('N');$origin.Add($route,200,(Bytes '<!DOCTYPE html><html>login</html>'),$type,$null)
        Rejected {Read-UpdateBytes ([uri]($origin.BaseUri+$route.TrimStart('/'))) 1024} "reject login HTML with $type"
    }
    $origin.Add('/too-large',200,(Bytes 'larger than one byte'),'application/octet-stream',$null)
    Rejected {Read-UpdateBytes ([uri]($origin.BaseUri+'too-large')) 1} 'metadata size ceiling remains enforced'
    $httpError=''
    try { Read-UpdateBytes ([uri]'http://127.0.0.1:1/plaintext') 1024 | Out-Null } catch { $httpError=$_.Exception.Message }
    Assert ($httpError -match 'HTTPS') 'reject even initial loopback HTTP by transport policy'
    foreach($route in @('/five-0','/five-1','/five-2','/five-3','/five-4')) {
        $i=[int]$route.Substring($route.Length-1)
        $target=if($i -eq 4){$cdn.BaseUri+'file?temporary=opaque'}else{'/five-'+($i+1)}
        $origin.Add($route,302,(Bytes ''),'text/html',$target)
    }
    Assert ([Text.Encoding]::UTF8.GetString((Read-UpdateBytes ([uri]($origin.BaseUri+'five-0')) 1024)) -ceq 'signed file bytes') 'exactly five redirects allowed'
    foreach($location in @('https://user:password@localhost/secret','https://localhost/file#fragment','file:///C:/Windows/win.ini')) {
        $route='/unsafe-'+[guid]::NewGuid().ToString('N');$origin.Add($route,302,(Bytes ''),'text/html',$location)
        Rejected {Read-UpdateBytes ([uri]($origin.BaseUri+$route.TrimStart('/'))) 1024} 'reject credentials, fragment and non-HTTPS redirect targets'
    }

    # Exercise the signed download/stage/apply boundary twice, with small files
    # only. AVD, installed-app and preference markers are never update targets.
    $root=Join-Path $work 'installed'
    foreach($dir in @('update','sdk','data\avd','data\update')){[void][IO.Directory]::CreateDirectory((Join-Path $root $dir))}
    Copy-Item -Path (Join-Path $project 'stage\update\*.ps1') -Destination (Join-Path $root 'update')
    [IO.File]::WriteAllText((Join-Path $root 'version.ini'),"[ArtemisOS]`r`nVersion=1.0.2`r`n")
    [IO.File]::WriteAllText((Join-Path $root 'data\preferences.ini'),'keep preferences')
    [IO.File]::WriteAllText((Join-Path $root 'data\avd\userdata.img'),'keep installed apps and Android data')
    [IO.File]::WriteAllText((Join-Path $root 'update\fixture.txt'),'old file')
    [IO.File]::WriteAllText((Join-Path $root 'data\update\server.txt'),($origin.BaseUri+'d/fixture/ota/'))
    $rsa=New-Object Security.Cryptography.RSACryptoServiceProvider(2048);$rsa.PersistKeyInCsp=$false
    try {
        [IO.File]::WriteAllText((Join-Path $root 'update\trusted-key.xml'),$rsa.ToXmlString($false))
        foreach($from in @('1.0.2','1.0.3')) {
            $to=if($from -eq '1.0.2'){'1.0.3'}else{'1.0.4'}
            $records=@()
            foreach($path in @('version.ini','update/fixture.txt')) {
                $payload=if($path -eq 'version.ini'){Bytes "[ArtemisOS]`r`nVersion=$to`r`n"}else{Bytes "small payload $to"}
                $hash=Hash $payload;$old=Get-FileHash -LiteralPath (Join-Path $root $path) -Algorithm SHA256
                $records += [ordered]@{path=$path;base_sha256=$old.Hash.ToLowerInvariant();sha256=$hash;size=$payload.Length}
                $origin.Add(('/d/fixture/ota/objects/'+$hash),302,(Bytes '<html>redirect</html>'),'text/html',($cdn.BaseUri+'objects/'+$hash))
                $cdn.Add(('/objects/'+$hash),200,$payload,'application/octet-stream',$null)
            }
            $manifest=[ordered]@{schema=1;product='ArtemisOS-15';from=$from;to=$to;notes='small HTTPS fixture';files=$records}
            $json=Bytes ($manifest|ConvertTo-Json -Depth 6)
            $sig=Bytes ([Convert]::ToBase64String($rsa.SignData($json,'SHA256')))
            foreach($ext in @('json','sig')){
                $body=if($ext -eq 'json'){$json}else{$sig}
                $relative="manifests/$from.$ext"
                $origin.Add(('/d/fixture/ota/'+$relative),302,(Bytes ''),'text/html',($cdn.BaseUri+$relative))
                $cdn.Add(('/'+$relative),200,$body,'application/octet-stream',$null)
            }
            $offer=Get-UpdateOffer $root
            Assert ($offer.Manifest.to -ceq $to) "$from only offers next signed hop $to"
            $staging=Stage-UpdateOffer $root $offer
            & rtk proxy powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'update\apply.ps1') -Staging $staging -Serial emulator-5554 -NoRestart
            Assert ($LASTEXITCODE -eq 0 -and (Get-UpdateVersion $root) -ceq $to) "downloaded signed $from -> $to actually applies"
            Assert ([IO.File]::ReadAllText((Join-Path $root 'data\preferences.ini')) -ceq 'keep preferences' -and [IO.File]::ReadAllText((Join-Path $root 'data\avd\userdata.img')) -ceq 'keep installed apps and Android data') 'apps, data and preferences preserved'
        }
        $sentinel=[ordered]@{schema=1;product='ArtemisOS-15';from='1.0.4';to='1.0.4';notes='';files=@()}
        $json=Bytes ($sentinel|ConvertTo-Json -Depth 6);$sig=Bytes ([Convert]::ToBase64String($rsa.SignData($json,'SHA256')))
        $origin.Add('/d/fixture/ota/manifests/1.0.4.json',200,$json,'application/json',$null)
        $origin.Add('/d/fixture/ota/manifests/1.0.4.sig',200,$sig,'application/octet-stream',$null)
        Assert ($null -eq (Get-UpdateOffer $root)) 'valid signed no-update sentinel on new updater'
        [IO.File]::WriteAllText((Join-Path $root 'data\update\server.txt'),($origin.BaseUri+'badpair/'))
        $origin.Add('/badpair/manifests/1.0.4.json',200,$json,'application/json',$null)
        $badSig=[byte[]]$sig.Clone();$badSig[20]=if($badSig[20] -eq 65){66}else{65}
        $origin.Add('/badpair/manifests/1.0.4.sig',200,$badSig,'application/octet-stream',$null)
        Rejected {Get-UpdateOffer $root} 'mismatched manifest/signature pair fails closed'
        Assert ((Get-UpdateVersion $root) -ceq '1.0.4') 'signature failure changes no installed version'
        Rejected {Verify-UpdateManifest $root (Bytes ([Text.Encoding]::UTF8.GetString($json)+' ')) $sig -AllowNoUpdate} 'manifest byte tampering fails signature'
        $good=Bytes 'correct file';$hash=Hash $good
        $origin.Add('/wrong-size',200,(Bytes 'short'),'application/octet-stream',$null)
        Rejected {Save-UpdateObject ([uri]($origin.BaseUri+'wrong-size')) (Join-Path $work 'bad-size') $good.Length $hash} 'wrong object size rejected'
        $origin.Add('/wrong-hash',200,(Bytes 'changed file'),'application/octet-stream',$null)
        Rejected {Save-UpdateObject ([uri]($origin.BaseUri+'wrong-hash')) (Join-Path $work 'bad-hash') $good.Length $hash} 'same-sized corrupt object SHA256 rejected'
        $origin.Add('/object-html',200,(Bytes '<html>login</html>'),'application/octet-stream',$null)
        $html=Bytes '<html>login</html>'
        Rejected {Save-UpdateObject ([uri]($origin.BaseUri+'object-html')) (Join-Path $work 'bad-html') $html.Length (Hash $html)} 'HTML object rejected even with expected length/hash'
        $origin.AddFragmented('/fragmented-html',$html)
        Rejected {Save-UpdateObject ([uri]($origin.BaseUri+'fragmented-html')) (Join-Path $work 'fragmented-html') $html.Length (Hash $html)} 'HTML split across stream reads rejected'
        [IO.File]::AppendAllText((Join-Path $root 'version.ini'),'modified')
        $tampered=[pscustomobject]@{Bytes=$json;Signature=$sig;Base=[uri]$origin.BaseUri;Manifest=[pscustomobject]@{files=@([pscustomobject]@{path='version.ini';base_sha256=('0'*64);sha256=$hash;size=$good.Length})}}
        Rejected {Stage-UpdateOffer $root $tampered} 'old installed file SHA256 remains mandatory'
        [IO.File]::WriteAllText((Join-Path $root 'data\update\server.txt'),'http://127.0.0.1:1/')
        Rejected {Get-UpdateBaseUri $root} 'HTTP repository config rejected before downloading'
    } finally {$rsa.Dispose()}
    Write-Host 'PASS: OTA HTTPS download security suite'
} finally {
    [Net.ServicePointManager]::ServerCertificateValidationCallback=$oldValidation
    [Net.ServicePointManager]::SecurityProtocol=$oldProtocol
    foreach($server in $servers){$server.Dispose()}
}
