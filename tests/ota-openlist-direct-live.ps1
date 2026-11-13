# Read-only production validation. Never uploads, changes server settings,
# follows a login session, or downloads a complete large runtime object.
param([string]$Output = 'build\ota-direct-live-result.json', [ValidateSet('1.0.6','1.0.7','1.0.8','1.0.9','1.1.0','1.1.1')][string]$LatestVersion='1.0.6')
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'stage\update\core.ps1')
$base=[uri]'https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/'
$work=Join-Path $project ('build\ota-direct-live-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $work 'update'))
Copy-Item -LiteralPath (Join-Path $project 'stage\update\trusted-key.xml') -Destination (Join-Path $work 'update\trusted-key.xml')
[IO.File]::WriteAllText((Join-Path $work 'update\server.txt'),$base.AbsoluteUri)
$checks=@();$offers=@{}
function Assert([bool]$Value,[string]$Label){if(-not $Value){throw "FAIL: $Label"};Write-Host "PASS: $Label"}
$knownVersions=@(2..9|ForEach-Object {'1.0.'+$_})+@('1.1.0','1.1.1')
$latestIndex=[Array]::IndexOf($knownVersions,$LatestVersion)
if($latestIndex -lt 0){throw 'Unknown signed release chain.'}
$versions=@($knownVersions[0..$latestIndex])
for($versionIndex=0;$versionIndex -lt $versions.Count;$versionIndex++){
    $version=$versions[$versionIndex]
    [IO.File]::WriteAllText((Join-Path $work 'version.ini'),"[ArtemisOS]`r`nVersion=$version`r`n")
    $offer=Get-UpdateOffer $work
    if($version -eq $LatestVersion){
        Assert ($null -eq $offer) "latest $LatestVersion signed no-update sentinel via new endpoint"
        $checks += [ordered]@{from=$version;noUpdate=$true;signatureValid=$true}
    }else{
        $expected=$versions[$versionIndex+1]
        Assert ($offer.Manifest.to -ceq $expected) "$version next signed hop is $expected"
        $offers[$version]=$offer
        $checks += [ordered]@{from=$version;to=$offer.Manifest.to;signatureValid=$true}
    }
}
$small=@($offers['1.0.2'].Manifest.files|Where-Object path -eq 'version.ini')[0]
$smallUri=Get-UpdateResourceUri $base ('objects/'+$small.sha256)
$initial=[Net.HttpWebRequest]::Create($smallUri);$initial.AllowAutoRedirect=$false;$initial.UseDefaultCredentials=$false;$initial.CookieContainer=$null
$initialResponse=$initial.GetResponse()
try{
    $initialStatus=[int]$initialResponse.StatusCode
    Assert ($initialStatus -eq 302) 'OpenList object origin returns 302'
}finally{$initialResponse.Dispose()}
$response=Open-UpdateResponse $smallUri
try{
    $smallFinalHost=$response.ResponseUri.Host
    Assert ($response.StatusCode -eq 200 -and $smallFinalHost -match '(?i)(?:^|\.)ctyunxs\.cn$' -and $response.ContentType -notmatch '(?i)html') 'small file final response is Tianyi bytes, not OpenList proxy or HTML'
}finally{$response.Dispose()}
Save-UpdateObject $smallUri (Join-Path $work 'small-verified-object') ([long]$small.size) $small.sha256
Assert ((Get-Item -LiteralPath (Join-Path $work 'small-verified-object')).Length -eq $small.size) 'small actual object downloaded with exact signed size and SHA256'
$large=@($offers['1.0.3'].Manifest.files|Sort-Object size -Descending)[0]
Assert ($large.size -gt 1048576) 'large signed runtime object selected'
$largeResponse=Open-UpdateResponse (Get-UpdateResourceUri $base ('objects/'+$large.sha256)) -RangeEnd 1023
$sampleRead=0
try{
    $largeHost=$largeResponse.ResponseUri.Host
    Assert ($largeHost -match '(?i)(?:^|\.)ctyunxs\.cn$') 'large object final response comes directly from Tianyi'
    $largeStatus=[int]$largeResponse.StatusCode
    $range=$largeResponse.Headers['Content-Range']
    if($largeStatus -eq 206){
        Assert ($range -eq "bytes 0-1023/$($large.size)") 'large object honors 1 KiB Range and signed total size'
        $sample=New-Object byte[] 1024;$stream=$largeResponse.GetResponseStream()
        try{while($sampleRead -lt 1024){$n=$stream.Read($sample,$sampleRead,1024-$sampleRead);if($n -eq 0){break};$sampleRead+=$n}}finally{$stream.Dispose()}
        Assert ($sampleRead -eq 1024) 'only 1 KiB of large object read'
        Assert-UpdateContentPrefix $sample $sampleRead
    }else{
        # A storage provider may ignore Range. Inspect headers and close;
        # never fall back to downloading the complete object for this check.
        Assert ($largeStatus -eq 200 -and $largeResponse.ContentLength -eq $large.size) 'Range ignored: signed size checked from headers only'
    }
}finally{$largeResponse.Dispose()}
$result=[ordered]@{observedUtc=[DateTime]::UtcNow.ToString('o');base=$base.AbsoluteUri;readOnly=$true;chain=$checks;smallObject=[ordered]@{originStatus=$initialStatus;finalHost=$smallFinalHost;size=$small.size;sha256=$small.sha256;verified=$true};largeObject=[ordered]@{sha256=$large.sha256;signedSize=$large.size;finalHost=$largeHost;status=$largeStatus;contentRange=$range;bodyBytesRead=$sampleRead;fullHashVerified=$false}}
$outputPath=Join-Path $project $Output
[IO.File]::WriteAllText($outputPath,($result|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
Write-Host "PASS: read-only live validation; evidence $Output"
