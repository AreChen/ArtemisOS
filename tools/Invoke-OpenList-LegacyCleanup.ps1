<#
DEPRECATED HISTORICAL TOOL — DO NOT RUN for the current /d/ OTA repository.
This /sd/ share cleanup belongs to a completed historical migration. Current
publishing neither runs cleanup nor migrates old shares or remote data.

One-time cleanup of the verified 0.3.4/0.3.5/0.3.6 manifests and the
specified legacy object. By default this only reads OpenList. Deletion requires
-Execute and an explicit acknowledgement that all publishers are stopped.

OpenList's remove API has no conditional delete. A matching file can therefore
still be replaced between its last read and deletion if another writer is
active. Do not run -Execute until exclusive maintenance has been established.
No data is uploaded and the 1.0.0 no-update marker is never deleted.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Backup,
    [Parameter(Mandatory=$true)][string]$ClientRoot,
    [Parameter(Mandatory=$true)][System.Management.Automation.PSCredential]$Credential,
    [switch]$Execute,
    [switch]$ConfirmExclusiveMaintenance
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
if ($Execute -and -not $ConfirmExclusiveMaintenance) {
    throw 'Stop all repository publishers and confirm exclusive maintenance before deletion.'
}
$project = Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'stage\update\core.ps1')
Import-Module (Join-Path $PSScriptRoot 'OpenListLegacyCleanup.psm1') -Force -ErrorAction Stop
Add-Type -AssemblyName System.Net.Http

$Backup = [IO.Path]::GetFullPath($Backup)
$ClientRoot = [IO.Path]::GetFullPath($ClientRoot)
$oldObject = '6ed4bbc044d2311cb01c54dea352cc260b694c98f87d30c5703a876bb2aba60c'
$expected = @{
    'manifests/0.3.4.json' = '85112734d0cd7b15981dadd77281401d160cd45c3fd2f89d52c4a038e6043320'
    'manifests/0.3.4.sig' = 'd33e62d5645a48c4a662e25e3da406d227fc394f79d44578b75424b6abd9a8d8'
    'manifests/0.3.5.json' = '83e3b00cbbf17cca43a8b7dfd2525bee14cd3fd55912befa55b691f40ef87a0a'
    'manifests/0.3.5.sig' = 'fceadb7e1db87d4b052782bf8cead24ba7501000f6d5f9b17550549c0d052932'
    'manifests/0.3.6.json' = '65bc3269ab21b18e1d3fd4fb523c36751cecb8e278a1e0d1f2e79fb08d697798'
    'manifests/0.3.6.sig' = '26d925e4abb024910fc5397cce7c824bae27e6fa9fa94f60c780ba5d77a65170'
    ('objects/' + $oldObject) = $oldObject
}
$backupBytes = @{}
foreach ($relative in $expected.Keys) {
    $path = Join-Path $Backup ($relative.Replace('/', '\'))
    Assert-UpdatePathSafe $path
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $item.Length -le 0 -or $item.Length -gt 1048576) { throw 'The local release backup is invalid.' }
    $bytes = [IO.File]::ReadAllBytes($path)
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected[$relative]) {
        throw 'The local release backup does not match its pinned hash.'
    }
    $backupBytes[$relative] = $bytes
}
$publicKeyPath = Join-Path $project 'stage\update\trusted-key.xml'
Assert-UpdatePathSafe $publicKeyPath
if ((Get-FileHash -LiteralPath $publicKeyPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne
    'de2c7be759256c476025456fa64d0acecee62c4d92c5d68fd4685b3c8964c3ae') {
    throw 'The release verification key does not match the pinned key.'
}
$publicKey = [IO.File]::ReadAllText($publicKeyPath)
$serverBase = Get-UpdateBaseUri $ClientRoot
if ($serverBase.Scheme -cne 'https' -or $serverBase.Host -cne 'cloudx.playones.com' -or
    -not $serverBase.IsDefaultPort -or $serverBase.Query -cne '?d' -or $serverBase.UserInfo -or
    $serverBase.Fragment -or $serverBase.AbsolutePath -cnotmatch '^/sd/([A-Za-z0-9_-]+)/$') {
    throw 'Unexpected configured update endpoint.'
}
$shareId = $Matches[1]
$serverOrigin = $serverBase.GetLeftPart([UriPartial]::Authority)
$remoteRoot = '/ota'
$handler = New-Object Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $false
$http = New-Object Net.Http.HttpClient($handler)
$http.Timeout = [TimeSpan]::FromMinutes(2)
$script:cleanupToken = $null

function Invoke-CleanupOpenListJson([string]$Method, [string]$Path, $Body, [bool]$Authenticated) {
    $req = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $serverOrigin + $Path)
    try {
        if ($Authenticated) { [void]$req.Headers.TryAddWithoutValidation('Authorization', $script:cleanupToken) }
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

try {
    $loginBody = @{username=$Credential.UserName;password=$Credential.GetNetworkCredential().Password}
    try { $login = Invoke-CleanupOpenListJson 'POST' '/api/auth/login' $loginBody $false }
    finally { $loginBody = $null }
    if ($login.code -ne 200 -or -not $login.data.token) { throw 'OpenList login failed.' }
    $script:cleanupToken = $login.data.token
    $login = $null
    $me = Invoke-CleanupOpenListJson 'GET' '/api/me' $null $true
    if ($me.code -ne 200 -or $me.data.disabled -or [int]$me.data.role -ne 0 -or
        $me.data.base_path -cne '/CLOUD/Footage/EAPIL/Artemis' -or ([int]$me.data.permission -band 8) -eq 0) {
        throw 'Unexpected cleanup account.'
    }
    $share = Invoke-CleanupOpenListJson 'GET' ('/api/share/get?id=' + [Uri]::EscapeDataString($shareId)) $null $true
    if ($share.code -ne 200 -or $share.data.disabled -or $share.data.pwd -or
        @($share.data.files).Count -ne 1 -or $share.data.files[0] -cne ($me.data.base_path + $remoteRoot) -or
        ($share.data.expires -and [DateTimeOffset]$share.data.expires -le [DateTimeOffset]::UtcNow)) {
        throw 'The share no longer identifies the dedicated update directory.'
    }
    $adapter = [pscustomobject]@{
        List = {
            param($directory, $page, $pageSize)
            if ($directory -cnotin @('manifests', 'objects')) { throw 'Invalid list directory.' }
            $response = Invoke-CleanupOpenListJson 'POST' '/api/fs/list' @{
                path=($remoteRoot + '/' + $directory);password='';page=$page;per_page=$pageSize;refresh=$true
            } $true
            if ($response.code -ne 200 -or $null -eq $response.data) { throw 'Cannot list the repository.' }
            return [pscustomobject]@{ total=$response.data.total; items=@($response.data.content | Where-Object { $null -ne $_ }) }
        }
        Read = {
            param($relative)
            if ($relative -cnotmatch '^(manifests/(0\.3\.[456]|1\.0\.0)\.(json|sig)|objects/[0-9a-f]{64})$') {
                throw 'Invalid read path.'
            }
            $meta = Invoke-CleanupOpenListJson 'POST' '/api/fs/get' @{path=($remoteRoot + '/' + $relative);password=''} $true
            if ($meta.code -eq 500 -and $meta.message -ceq 'object not found') { return $null }
            if ($meta.code -ne 200 -or $null -eq $meta.data -or $meta.data.is_dir) { throw 'Cannot inspect the remote file.' }
            try { return ,(Read-UpdateBytes (Get-UpdateResourceUri $serverBase $relative) 1048576) }
            catch { throw 'Cannot read the remote file through the update share.' }
        }
        Remove = {
            param($relative)
            if (-not $expected.ContainsKey($relative)) { throw 'Refusing to delete an unapproved file.' }
            $parts = $relative.Split('/')
            if ($parts.Count -ne 2 -or $parts[0] -cnotin @('manifests', 'objects')) { throw 'Invalid deletion path.' }
            $response = Invoke-CleanupOpenListJson 'POST' '/api/fs/remove' @{
                dir=($remoteRoot + '/' + $parts[0]);names=@($parts[1]);follow_seed=$false
            } $true
            if ($response.code -ne 200) { throw 'The remote deletion failed.' }
        }
    }
    $result = Invoke-VerifiedLegacyCleanup -Adapter $adapter -ExpectedHashes $expected -BackupBytes $backupBytes -PublicKey $publicKey -Execute:$Execute
    if ($result.DryRun) {
        Write-Host 'Read-only preflight passed. No remote files were changed.'
        foreach ($path in $result.Planned) { Write-Host ('Would remove: ' + $path) }
    } else {
        foreach ($path in $result.Removed) { Write-Host ('Removed verified legacy file: ' + $path) }
        Write-Host 'Cleanup completed; the signed 1.0.0 marker was preserved and reverified.'
    }
} catch {
    # Do not include credential, token, share URL or raw network exceptions.
    Write-Host 'The cleanup stopped. No later deletions were attempted.'
    throw 'OpenList cleanup failed; inspect the repository before retrying.'
} finally {
    $script:cleanupToken = $null
    $Credential = $null
    $shareId = $null
    $serverBase = $null
    $http.Dispose()
}
