<#
DEPRECATED HISTORICAL TOOL — DO NOT RUN for the current /d/ OTA repository.
This one-time /sd/ share migration remains only as a historical release record.
Current releases use Publish-OpenList.ps1 with -PublicBase and no legacy migration.

Prepare or publish the verified 0.3.6 -> 1.0.0 release bridge and remove only
the superseded 0.3.4/0.3.5 files. Without -Execute this script is read-only.

Credentials are passed as PSCredential; the existing share configuration is
read in memory from BaseRoot. Neither is written to disk or intentionally
included in output. Use only when no other publisher is writing this repository:
OpenList has no compare-and-swap for the two-file manifest pair.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$Backup,
    [Parameter(Mandatory = $true)][string]$BaseRoot,
    [Parameter(Mandatory = $true)][string]$TargetRoot,
    [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential]$Credential,
    [switch]$Execute
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$project = Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'stage\update\core.ps1')
Add-Type -AssemblyName System.Net.Http

$Repository = [IO.Path]::GetFullPath($Repository)
$Backup = [IO.Path]::GetFullPath($Backup)
$BaseRoot = [IO.Path]::GetFullPath($BaseRoot)
$TargetRoot = [IO.Path]::GetFullPath($TargetRoot)
$serverBase = Get-UpdateBaseUri $BaseRoot
if ($serverBase.Scheme -cne 'https' -or $serverBase.Host -cne 'cloudx.playones.com' -or
    $serverBase.Query -cne '?d' -or $serverBase.UserInfo -or $serverBase.Fragment -or
    $serverBase.AbsolutePath -cnotmatch '^/sd/([A-Za-z0-9_-]+)/$') {
    throw 'Unexpected configured update endpoint.'
}
$shareId = $Matches[1]
$serverOrigin = $serverBase.GetLeftPart([UriPartial]::Authority)
$remoteRoot = '/ota'
$oldObject = '6ed4bbc044d2311cb01c54dea352cc260b694c98f87d30c5703a876bb2aba60c'
$backupHashes = [ordered]@{
    'manifests/0.3.4.json' = '85112734d0cd7b15981dadd77281401d160cd45c3fd2f89d52c4a038e6043320'
    'manifests/0.3.4.sig' = 'd33e62d5645a48c4a662e25e3da406d227fc394f79d44578b75424b6abd9a8d8'
    'manifests/0.3.5.json' = '83e3b00cbbf17cca43a8b7dfd2525bee14cd3fd55912befa55b691f40ef87a0a'
    'manifests/0.3.5.sig' = 'fceadb7e1db87d4b052782bf8cead24ba7501000f6d5f9b17550549c0d052932'
    'manifests/0.3.6.json' = '65bc3269ab21b18e1d3fd4fb523c36751cecb8e278a1e0d1f2e79fb08d697798'
    'manifests/0.3.6.sig' = '26d925e4abb024910fc5397cce7c824bae27e6fa9fa94f60c780ba5d77a65170'
    ('objects/' + $oldObject) = $oldObject
}
$obsolete = @('manifests/0.3.4.json', 'manifests/0.3.4.sig',
    'manifests/0.3.5.json', 'manifests/0.3.5.sig', ('objects/' + $oldObject))
$handler = New-Object Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $false
$http = New-Object Net.Http.HttpClient($handler)
$http.Timeout = [TimeSpan]::FromMinutes(2)
$script:token = $null

function Hash-Bytes([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Equal-Bytes([byte[]]$Left, [byte[]]$Right) {
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    return [Convert]::ToBase64String($Left) -ceq [Convert]::ToBase64String($Right)
}

function Read-Local([string]$Root, [string]$Relative) {
    $path = Join-Path $Root ($Relative.Replace('/', '\'))
    $item = Get-Item -LiteralPath $path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 1048576) {
        throw 'Invalid local release file.'
    }
    return ,[IO.File]::ReadAllBytes($path)
}

function Invoke-OpenListJson([string]$Method, [string]$Path, $Body, [bool]$Authenticated) {
    $req = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $serverOrigin + $Path)
    try {
        if ($Authenticated) { [void]$req.Headers.TryAddWithoutValidation('Authorization', $script:token) }
        if ($null -ne $Body) {
            $req.Content = [Net.Http.StringContent]::new(($Body | ConvertTo-Json -Compress -Depth 12), [Text.Encoding]::UTF8, 'application/json')
        }
        try { $response = $http.SendAsync($req).GetAwaiter().GetResult() }
        catch { throw 'OpenList request failed.' }
        try {
            if (-not $response.IsSuccessStatusCode) { throw 'OpenList returned an HTTP error.' }
            try { return ($response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json) }
            catch { throw 'OpenList returned invalid JSON.' }
        } finally { $response.Dispose() }
    } finally { $req.Dispose() }
}

function Get-RemoteMeta([string]$Relative) {
    $result = Invoke-OpenListJson 'POST' '/api/fs/get' @{path=($remoteRoot + '/' + $Relative);password=''} $true
    if ($result.code -eq 200) { return $result.data }
    if ($result.code -eq 500 -and $result.message -ceq 'object not found') { return $null }
    throw 'Could not determine remote file state.'
}

function Read-Remote([string]$Relative) {
    $meta = Get-RemoteMeta $Relative
    if ($null -eq $meta) { return $null }
    if ($meta.is_dir) { throw 'A remote file is a directory.' }
    try { return ,(Read-UpdateBytes (Get-UpdateResourceUri $serverBase $Relative) 1048576) }
    catch { throw 'Could not read a shared file.' }
}

function Assert-Remote([string]$Relative, [byte[]]$Expected) {
    $actual = Read-Remote $Relative
    if (-not (Equal-Bytes $actual $Expected)) { throw 'Remote file differs from the expected bytes.' }
}

function Get-InventorySnapshot([string]$Directory, [string[]]$Allowed) {
    # A deliberately small page makes ignored pagination detectable even with
    # today's tiny directory. Probe one page past the end as well.
    $pageSize = 2
    $page = 1
    $total = $null
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $entries = New-Object 'System.Collections.Generic.List[string]'
    while ($true) {
        $response = Invoke-OpenListJson 'POST' '/api/fs/list' @{
            path=($remoteRoot + '/' + $Directory); password=''; page=$page; per_page=$pageSize; refresh=$true
        } $true
        if ($response.code -ne 200 -or $null -eq $response.data) { throw 'Could not list the update repository.' }
        $count = 0
        if (-not [int]::TryParse([string]$response.data.total, [ref]$count) -or $count -lt 0 -or $count -gt $Allowed.Count) {
            throw 'Invalid or unexpectedly large inventory total.'
        }
        if ($null -eq $total) { $total = $count }
        elseif ($total -ne $count) { throw 'Inventory total changed between pages.' }
        $items = @($response.data.content | Where-Object { $null -ne $_ })
        $remaining = [Math]::Max(0, $total - (($page - 1) * $pageSize))
        $expectedPageCount = [Math]::Min($pageSize, $remaining)
        if ($items.Count -ne $expectedPageCount) { throw 'Inventory pagination is incomplete or unsupported.' }
        foreach ($item in $items) {
            $name = [string]$item.name
            if ($item.is_dir -or $name -cnotin $Allowed -or -not $seen.Add($name)) {
                throw 'Unexpected or duplicate file in the update repository.'
            }
            $size = [long]0
            if (-not [long]::TryParse([string]$item.size, [ref]$size) -or $size -lt 0) { throw 'Invalid inventory file size.' }
            # Name, length and modification time must stay stable across both
            # complete enumerations. File content is also checked separately.
            $entries.Add(($name + "`n" + $size + "`n" + [string]$item.modified))
        }
        if ($expectedPageCount -eq 0) { break }
        $page++
    }
    if ($seen.Count -ne $total) { throw 'Inventory count does not match its total.' }
    return ,([string[]]@($entries | Sort-Object))
}

function Assert-Inventory([string]$Directory, [string[]]$Allowed) {
    $first = Get-InventorySnapshot $Directory $Allowed
    $second = Get-InventorySnapshot $Directory $Allowed
    if ($first.Count -ne $second.Count) { throw 'Inventory changed between complete snapshots.' }
    for ($i = 0; $i -lt $first.Count; $i++) {
        if ($first[$i] -cne $second[$i]) { throw 'Inventory changed between complete snapshots.' }
    }
}

function Upload-RecoverySignature([string]$LocalPath) {
    # This function is only called after exact old/new pair checks and after
    # validating the target marker and version object from the public share.
    $remotePath = $remoteRoot + '/manifests/0.3.6.sig'
    $encoded = '/' + ((@($remotePath.TrimStart('/').Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) })) -join '/')
    $req = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Put, $serverOrigin + '/api/fs/put')
    try {
        [void]$req.Headers.TryAddWithoutValidation('Authorization', $script:token)
        [void]$req.Headers.TryAddWithoutValidation('File-Path', $encoded)
        [void]$req.Headers.TryAddWithoutValidation('As-Task', 'false')
        $stream = [IO.File]::Open($LocalPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $req.Content = [Net.Http.StreamContent]::new($stream)
        $req.Content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
        $req.Content.Headers.ContentLength = $stream.Length
        try { $response = $http.SendAsync($req).GetAwaiter().GetResult() }
        catch { throw 'Signature recovery upload failed.' }
        try {
            if (-not $response.IsSuccessStatusCode) { throw 'Signature recovery upload failed.' }
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
            if ($body.code -ne 200) { throw 'Signature recovery upload failed.' }
        } finally { $response.Dispose() }
    } finally { $req.Dispose() }
}

function Publish-Bridge {
    & (Join-Path $project 'tools\Publish-OpenList.ps1') -Repository $Repository -FromVersion '0.3.6' `
        -TargetVersion '1.0.0' -RemoteRoot $remoteRoot -ShareId $shareId -Server ([Uri]$serverOrigin) `
        -PublicKeyPath (Join-Path $TargetRoot 'update\trusted-key.xml') -Credential $Credential
}

function Remove-Obsolete([string]$Relative, [byte[]]$Expected) {
    if ($Relative -cnotin $obsolete) { throw 'Refusing to delete an unapproved file.' }
    $actual = Read-Remote $Relative
    if ($null -eq $actual) { return }
    if (-not (Equal-Bytes $actual $Expected)) { throw 'Obsolete remote file changed.' }
    $parts = $Relative.Split('/')
    if ($parts.Count -ne 2) { throw 'Invalid obsolete file name.' }
    $response = Invoke-OpenListJson 'POST' '/api/fs/remove' @{
        dir=($remoteRoot + '/' + $parts[0]); names=@($parts[1]); follow_seed=$false
    } $true
    if ($response.code -ne 200) { throw 'An obsolete file could not be removed.' }
    if ($null -ne (Get-RemoteMeta $Relative)) { throw 'Removed file remains visible.' }
    Write-Host ('Removed verified obsolete file: ' + $Relative)
}

try {
    $saved = @{}
    foreach ($relative in $backupHashes.Keys) {
        $bytes = Read-Local $Backup $relative
        if ((Hash-Bytes $bytes) -cne $backupHashes[$relative]) { throw 'A backup file does not match the verified snapshot.' }
        $saved[$relative] = $bytes
    }
    $newJson = Read-Local $Repository 'manifests/0.3.6.json'
    $newSig = Read-Local $Repository 'manifests/0.3.6.sig'
    $targetJson = Read-Local $Repository 'manifests/1.0.0.json'
    $targetSig = Read-Local $Repository 'manifests/1.0.0.sig'
    $bridge = Verify-UpdateManifest $BaseRoot $newJson $newSig
    $target = Verify-UpdateManifest $TargetRoot $targetJson $targetSig -AllowNoUpdate
    if ($bridge.from -cne '0.3.6' -or $bridge.to -cne '1.0.0' -or $bridge.files.Count -ne 1 -or
        $bridge.files[0].path -cne 'version.ini' -or $target.from -cne '1.0.0' -or
        $target.to -cne '1.0.0' -or $target.files.Count -ne 0) { throw 'Unexpected signed release.' }
    $newHash = [string]$bridge.files[0].sha256
    $newObject = Read-Local $Repository ('objects/' + $newHash)
    if ((Hash-Bytes $newObject) -cne $newHash -or $newObject.Length -ne [long]$bridge.files[0].size -or
        (Hash-Bytes ([IO.File]::ReadAllBytes((Join-Path $BaseRoot 'version.ini')))) -cne $bridge.files[0].base_sha256 -or
        (Hash-Bytes ([IO.File]::ReadAllBytes((Join-Path $TargetRoot 'version.ini')))) -cne $newHash) {
        throw 'Release object or baseline does not match.'
    }
    $loginBody = @{username=$Credential.UserName;password=$Credential.GetNetworkCredential().Password}
    try { $login = Invoke-OpenListJson 'POST' '/api/auth/login' $loginBody $false }
    finally { $loginBody = $null }
    if ($login.code -ne 200 -or -not $login.data.token) { throw 'OpenList login failed.' }
    $script:token = $login.data.token
    $login = $null
    $me = Invoke-OpenListJson 'GET' '/api/me' $null $true
    if ($me.code -ne 200 -or $me.data.disabled -or [int]$me.data.role -ne 0 -or
        $me.data.base_path -cne '/CLOUD/Footage/EAPIL/Artemis' -or ([int]$me.data.permission -band 8) -eq 0) {
        throw 'Unexpected publishing account.'
    }
    $share = Invoke-OpenListJson 'GET' ('/api/share/get?id=' + [Uri]::EscapeDataString($shareId)) $null $true
    if ($share.code -ne 200 -or $share.data.disabled -or $share.data.pwd -or
        @($share.data.files).Count -ne 1 -or $share.data.files[0] -cne ($me.data.base_path + $remoteRoot) -or
        ($share.data.expires -and [DateTimeOffset]$share.data.expires -le [DateTimeOffset]::UtcNow)) {
        throw 'The share no longer matches the dedicated update directory.'
    }
    $manifestNames = @('0.3.4.json','0.3.4.sig','0.3.5.json','0.3.5.sig','0.3.6.json','0.3.6.sig','1.0.0.json','1.0.0.sig')
    Assert-Inventory 'manifests' $manifestNames
    Assert-Inventory 'objects' @($oldObject, $newHash)
    Assert-Remote 'manifests/1.0.0.json' $targetJson
    Assert-Remote 'manifests/1.0.0.sig' $targetSig
    $oldJson = $saved['manifests/0.3.6.json']; $oldSig = $saved['manifests/0.3.6.sig']
    $remoteJson = Read-Remote 'manifests/0.3.6.json'
    $remoteSig = Read-Remote 'manifests/0.3.6.sig'
    $state = if ((Equal-Bytes $remoteJson $oldJson) -and (Equal-Bytes $remoteSig $oldSig)) { 'old' }
    elseif ((Equal-Bytes $remoteJson $newJson) -and (Equal-Bytes $remoteSig $oldSig)) { 'interrupted' }
    elseif ((Equal-Bytes $remoteJson $newJson) -and (Equal-Bytes $remoteSig $newSig)) { 'published' }
    else { throw 'The remote bridge pair is not a recognized safe state.' }
    $remoteObject = Read-Remote ('objects/' + $newHash)
    if ($null -ne $remoteObject -and -not (Equal-Bytes $remoteObject $newObject)) { throw 'The new update object differs.' }
    if ($state -ne 'old' -and $null -eq $remoteObject) { throw 'The new update object is missing.' }
    foreach ($relative in $obsolete) {
        $actual = Read-Remote $relative
        if ($null -eq $actual) {
            if ($state -ne 'published') { throw 'A legacy file disappeared before the bridge was published.' }
        } elseif (-not (Equal-Bytes $actual $saved[$relative])) { throw 'A legacy file differs from its backup.' }
    }
    # Reuse the client's actual offer checks with the same in-memory share base.
    function Get-UpdateBaseUri([string]$Root) { return $serverBase }
    if ($null -ne (Get-UpdateOffer $TargetRoot)) { throw 'The target version unexpectedly has an update.' }
    if ($state -eq 'old' -and $null -ne (Get-UpdateOffer $BaseRoot)) { throw 'The old marker unexpectedly offers an update.' }
    if ($state -eq 'published') {
        $offer = Get-UpdateOffer $BaseRoot
        if ($null -eq $offer -or $offer.Manifest.to -cne '1.0.0') { throw 'The bridge is not available to the client.' }
    }
    Write-Host ('Read-only preflight passed. Bridge state: ' + $state)
    if (-not $Execute) {
        Write-Host 'No remote files were changed. Use -Execute only after release validation.'
        return
    }
    if ($state -eq 'old') {
        Publish-Bridge
    } elseif ($state -eq 'interrupted') {
        # Recheck exactly the recognized partial state immediately before repair.
        Assert-Remote 'manifests/0.3.6.json' $newJson
        Assert-Remote 'manifests/0.3.6.sig' $oldSig
        Assert-Remote ('objects/' + $newHash) $newObject
        Upload-RecoverySignature (Join-Path $Repository 'manifests\0.3.6.sig')
    }
    Assert-Remote 'manifests/0.3.6.json' $newJson
    Assert-Remote 'manifests/0.3.6.sig' $newSig
    Assert-Remote 'manifests/1.0.0.json' $targetJson
    Assert-Remote 'manifests/1.0.0.sig' $targetSig
    Assert-Remote ('objects/' + $newHash) $newObject
    $offer = Get-UpdateOffer $BaseRoot
    if ($null -eq $offer -or $offer.Manifest.to -cne '1.0.0' -or $null -ne (Get-UpdateOffer $TargetRoot)) {
        throw 'Client verification failed; obsolete files were retained.'
    }
    Assert-Inventory 'manifests' $manifestNames
    Assert-Inventory 'objects' @($oldObject, $newHash)
    foreach ($relative in $obsolete) { Remove-Obsolete $relative $saved[$relative] }
    Assert-Remote 'manifests/0.3.6.json' $newJson
    Assert-Remote 'manifests/0.3.6.sig' $newSig
    Assert-Remote 'manifests/1.0.0.json' $targetJson
    Assert-Remote 'manifests/1.0.0.sig' $targetSig
    Assert-Remote ('objects/' + $newHash) $newObject
    if ($null -eq (Get-UpdateOffer $BaseRoot) -or $null -ne (Get-UpdateOffer $TargetRoot)) {
        throw 'Final client verification failed.'
    }
    Write-Host 'Published and verified the 0.3.6 bridge; only approved obsolete files were removed.'
} catch {
    # Avoid leaking credentials or share URLs through HTTP exception text.
    Write-Host 'The operation stopped; sensitive error details were suppressed.'
    throw 'OpenList release operation failed.'
} finally {
    $script:token = $null
    $Credential = $null
    $shareId = $null
    $serverBase = $null
    $http.Dispose()
}
