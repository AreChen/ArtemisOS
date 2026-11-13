<##
.SYNOPSIS
Uploads an already signed static update repository to an explicitly scoped
OpenList directory. This script never creates or changes a share.

.EXAMPLE
./Publish-OpenList.ps1 -Repository C:\staged-ota -FromVersion 0.3.4 `
  -TargetVersion 0.3.5 -RemoteRoot /ota `
  -Credential (Get-Credential)

.EXAMPLE
./Publish-OpenList.ps1 -Repository C:\staged-ota -SentinelOnly `
  -TargetVersion 0.3.6 -RemoteRoot /ota `
  -Credential (Get-Credential)

SentinelOnly publishes only the signed no-update marker for TargetVersion; it
never reads or publishes an older version's manifest or any update objects.

PublicBase must expose the account base path plus RemoteRoot through /d/.
Anonymous downloads use the same redirect-safe transport as the updater. A
publisher must be the only writer during the entire upload; OpenList does not
offer a compare-and-swap transaction for the JSON/signature pair.
##>
[CmdletBinding(DefaultParameterSetName = 'Update')]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true, ParameterSetName = 'Update')][string]$FromVersion,
    [Parameter(Mandatory = $true, ParameterSetName = 'Sentinel')][switch]$SentinelOnly,
    [Parameter(Mandatory = $true)][string]$TargetVersion,
    [Parameter(Mandatory = $true)][string]$RemoteRoot,
    [uri]$PublicBase = 'https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/',
    [uri]$Server = 'https://cloudx.playones.com',
    [string]$PublicKeyPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'stage\update\trusted-key.xml'),
    [System.Management.Automation.PSCredential]$Credential
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
Add-Type -AssemblyName System.Net.Http
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'stage\update\core.ps1')

if ($Server.Scheme -ne 'https' -or $Server.UserInfo -or $Server.Query -or $Server.Fragment -or
    $Server.AbsolutePath -ne '/') { throw 'Server must be an HTTPS origin without a path, credentials, query or fragment.' }
if ($RemoteRoot -notmatch '^/[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*$' -or
    @($RemoteRoot.Split('/') | Where-Object { $_ -eq '..' -or $_.EndsWith('.') }).Count) {
    throw 'RemoteRoot must be a non-root, safe absolute path relative to the account base.'
}
if (-not $PublicBase.IsAbsoluteUri -or $PublicBase.Scheme -ne 'https' -or
    $PublicBase.UserInfo -or $PublicBase.Query -or $PublicBase.Fragment -or
    $PublicBase.GetLeftPart([UriPartial]::Authority) -cne $Server.GetLeftPart([UriPartial]::Authority) -or
    -not $PublicBase.AbsolutePath.StartsWith('/d/', [StringComparison]::Ordinal) -or
    -not $PublicBase.AbsolutePath.EndsWith('/')) { throw 'PublicBase must be a direct HTTPS /d/ directory on Server.' }
if ($TargetVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid target version.' }
if (-not $SentinelOnly -and ($FromVersion -notmatch '^\d+\.\d+\.\d+$' -or
    [version]$TargetVersion -le [version]$FromVersion)) { throw 'Invalid source or target version.' }
$Repository = [IO.Path]::GetFullPath($Repository)
$PublicKeyPath = [IO.Path]::GetFullPath($PublicKeyPath)
if (-not (Test-Path -LiteralPath $PublicKeyPath -PathType Leaf)) { throw 'Trusted public key is missing.' }
if (-not $Credential) { $Credential = Get-Credential -Message 'OpenList scoped publishing account' }
if (-not $Credential) { throw 'No publishing credentials supplied.' }

$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
$rsa.PersistKeyInCsp = $false
$rsa.FromXmlString([IO.File]::ReadAllText($PublicKeyPath))
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $false
$handler.UseCookies = $false
$handler.UseDefaultCredentials = $false
$handler.Credentials = $null
$http = New-Object System.Net.Http.HttpClient($handler)
$http.Timeout = [TimeSpan]::FromMinutes(30)
$script:ApiToken = $null
$script:ServerOrigin = $Server.GetLeftPart([UriPartial]::Authority)

function Invoke-OpenListJson([string]$Method, [string]$Path, $Body, [bool]$Authenticate) {
    $req = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $script:ServerOrigin + $Path)
    try {
        if ($Authenticate) { [void]$req.Headers.TryAddWithoutValidation('Authorization', $script:ApiToken) }
        if ($null -ne $Body) {
            $json = $Body | ConvertTo-Json -Compress -Depth 12
            $req.Content = [Net.Http.StringContent]::new($json, [Text.Encoding]::UTF8, 'application/json')
        }
        try { $response = $http.SendAsync($req).GetAwaiter().GetResult() }
        catch { throw 'OpenList API request failed.' }
        try {
            if (-not $response.IsSuccessStatusCode) { throw "OpenList API returned HTTP $([int]$response.StatusCode)." }
            try { return ($response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json) }
            catch { throw 'OpenList API returned invalid JSON.' }
        } finally { $response.Dispose() }
    } finally { $req.Dispose() }
}

function Get-RemoteMeta([string]$Path) {
    $result = Invoke-OpenListJson 'POST' '/api/fs/get' @{path=$Path;password=''} $true
    if ($result.code -eq 200) { return $result.data }
    if ($result.code -eq 500 -and $result.message -eq 'object not found') { return $null }
    throw "Cannot determine whether an OpenList path exists (API code $($result.code))."
}

function Ensure-RemoteDirectory([string]$Path) {
    $meta = Get-RemoteMeta $Path
    if ($null -ne $meta) {
        if (-not $meta.is_dir) { throw 'Expected remote directory is a file.' }
        return
    }
    $created = Invoke-OpenListJson 'POST' '/api/fs/mkdir' @{path=$Path} $true
    if ($created.code -ne 200) { throw "Could not create remote directory (API code $($created.code))." }
}

function Get-PublicUrl([string]$RelativePath) {
    if ($RelativePath -notmatch '^(objects/[0-9a-f]{64}|manifests/\d+\.\d+\.\d+\.(json|sig))$') {
        throw 'Invalid public repository path.'
    }
    $parts = @($RelativePath.Split('/') | ForEach-Object { [uri]::EscapeDataString($_) })
    return [Uri]::new($PublicBase, ($parts -join '/'))
}

function Open-PublicFile([string]$RelativePath) {
    return Open-UpdateResponse (Get-PublicUrl $RelativePath)
}

function Read-PublicBytes([string]$RelativePath, [int]$Limit) {
    return ,(Read-UpdateBytes (Get-PublicUrl $RelativePath) $Limit)
}

function Test-PublicObject([string]$RelativePath, [long]$ExpectedLength, [string]$ExpectedHash) {
    $response = Open-PublicFile $RelativePath
    $stream = $null
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        if ($response.ContentLength -ge 0 -and
            $response.ContentLength -ne $ExpectedLength) { throw 'Remote file length differs.' }
        $stream = $response.GetResponseStream()
        $buffer = New-Object byte[] 65536
        $prefix = New-Object byte[] 8192
        $prefixLength = 0
        $length = [long]0
        while (($n = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($prefixLength -lt $prefix.Length) {
                $prefixCount = [Math]::Min($n, $prefix.Length - $prefixLength)
                [Array]::Copy($buffer, 0, $prefix, $prefixLength, $prefixCount)
                $prefixLength += $prefixCount
            }
            $length += $n
            if ($length -gt $ExpectedLength) { throw 'Remote file exceeds expected length.' }
            [void]$sha.TransformBlock($buffer, 0, $n, $buffer, 0)
        }
        Assert-UpdateContentPrefix $prefix $prefixLength
        [void]$sha.TransformFinalBlock([byte[]]@(), 0, 0)
        $actual = [BitConverter]::ToString($sha.Hash).Replace('-', '').ToLowerInvariant()
        if ($length -ne $ExpectedLength -or $actual -cne $ExpectedHash) { throw 'Remote file hash differs.' }
    } finally {
        if ($stream) { $stream.Dispose() }
        $sha.Dispose()
        $response.Dispose()
    }
}

function Upload-OpenListFile([string]$LocalPath, [string]$RemotePath) {
    $segments = @($RemotePath.TrimStart('/').Split('/') | ForEach-Object { [uri]::EscapeDataString($_) })
    $encodedPath = '/' + ($segments -join '/')
    $req = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Put, $script:ServerOrigin + '/api/fs/put')
    try {
        [void]$req.Headers.TryAddWithoutValidation('Authorization', $script:ApiToken)
        [void]$req.Headers.TryAddWithoutValidation('File-Path', $encodedPath)
        [void]$req.Headers.TryAddWithoutValidation('As-Task', 'false')
        $stream = [IO.File]::Open($LocalPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $req.Content = [Net.Http.StreamContent]::new($stream)
        $req.Content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
        $req.Content.Headers.ContentLength = $stream.Length
        try { $response = $http.SendAsync($req).GetAwaiter().GetResult() }
        catch { throw 'OpenList file upload failed.' }
        try {
            if (-not $response.IsSuccessStatusCode) { throw "OpenList upload returned HTTP $([int]$response.StatusCode)." }
            try { $result = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json }
            catch { throw 'OpenList upload returned invalid JSON.' }
            if ($result.code -ne 200) { throw "OpenList upload failed (API code $($result.code))." }
        } finally { $response.Dispose() }
    } finally { $req.Dispose() }
}

function Read-SignedManifest([byte[]]$Bytes, [byte[]]$SignatureBytes) {
    try {
        $signature = [Convert]::FromBase64String([Text.Encoding]::ASCII.GetString($SignatureBytes).Trim())
        if (-not $rsa.VerifyData($Bytes, 'SHA256', $signature)) { throw 'Invalid signature.' }
        $manifest = [Text.Encoding]::UTF8.GetString($Bytes) | ConvertFrom-Json
        if ($manifest.schema -ne 1 -or $manifest.product -ne 'ArtemisOS-15' -or
            $null -eq $manifest.PSObject.Properties['files'] -or $manifest.files -isnot [array]) {
            throw 'Invalid manifest structure.'
        }
        return $manifest
    } catch { throw 'Manifest signature or structure is invalid.' }
}

function Read-LocalManifest([string]$Version) {
    $jsonPath = Join-Path $Repository "manifests\$Version.json"
    $sigPath = Join-Path $Repository "manifests\$Version.sig"
    if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $sigPath -PathType Leaf)) { throw 'A required local manifest pair is missing.' }
    if ((Get-Item -LiteralPath $jsonPath).Length -gt 1048576 -or (Get-Item -LiteralPath $sigPath).Length -gt 8192) {
        throw 'A local manifest or signature is too large.'
    }
    return Read-SignedManifest ([IO.File]::ReadAllBytes($jsonPath)) ([IO.File]::ReadAllBytes($sigPath))
}

function Publish-AndVerify([string]$RelativePath) {
    $local = Join-Path $Repository ($RelativePath.Replace('/', '\'))
    $size = (Get-Item -LiteralPath $local).Length
    $hash = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToLowerInvariant()
    Upload-OpenListFile $local ($RemoteRoot + '/' + $RelativePath)
    Test-PublicObject $RelativePath $size $hash
}

function Test-RemoteEqualsLocal([string]$RelativePath, [int]$Limit) {
    $local = Join-Path $Repository ($RelativePath.Replace('/', '\'))
    $expected = [IO.File]::ReadAllBytes($local)
    $actual = Read-PublicBytes $RelativePath $Limit
    return [Convert]::ToBase64String($actual) -ceq [Convert]::ToBase64String($expected)
}

function Assert-PublishedManifest([string]$Version) {
    $json = Read-PublicBytes "manifests/$Version.json" 1048576
    $signature = Read-PublicBytes "manifests/$Version.sig" 8192
    [void](Read-SignedManifest $json $signature)
    foreach ($pair in @(@('json', $json), @('sig', $signature))) {
        $expected = [IO.File]::ReadAllBytes((Join-Path $Repository "manifests\$Version.$($pair[0])"))
        if ([Convert]::ToBase64String($pair[1]) -cne [Convert]::ToBase64String($expected)) {
            throw 'The final signed manifest pair differs from the local repository.'
        }
    }
}

try {
    $target = Read-LocalManifest $TargetVersion
    if ($target.from -cne $TargetVersion -or $target.to -cne $TargetVersion -or $target.files.Count -ne 0) {
        throw 'The target manifest is not the expected signed no-update sentinel.'
    }
    $objects = @{}
    if (-not $SentinelOnly) {
        $source = Read-LocalManifest $FromVersion
        if ($source.from -cne $FromVersion -or $source.to -cne $TargetVersion -or $source.files.Count -eq 0) {
            throw 'The source manifest does not describe the requested update.'
        }
        foreach ($entry in $source.files) {
            if ($entry.sha256 -notmatch '^[0-9a-f]{64}$' -or $entry.size -isnot [ValueType] -or
                $entry.size -lt 0 -or $entry.size -gt 10737418240) { throw 'Invalid local object record.' }
            $relative = 'objects/' + $entry.sha256
            $path = Join-Path $Repository ($relative.Replace('/', '\'))
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -ne [long]$entry.size -or
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256) {
                throw 'A local object is missing or fails SHA-256/size validation.'
            }
            $objects[$entry.sha256] = [long]$entry.size
        }
    }
    $loginBody = @{username=$Credential.UserName;password=$Credential.GetNetworkCredential().Password}
    try { $login = Invoke-OpenListJson 'POST' '/api/auth/login' $loginBody $false }
    finally { $loginBody = $null }
    if ($login.code -ne 200 -or -not $login.data.token) { throw 'OpenList account login failed.' }
    $script:ApiToken = $login.data.token
    $login = $null
    $me = Invoke-OpenListJson 'GET' '/api/me' $null $true
    if ($me.code -ne 200 -or $me.data.disabled -or [int]$me.data.role -ne 0 -or
        [string]::IsNullOrWhiteSpace([string]$me.data.base_path) -or [string]$me.data.base_path -eq '/' -or
        ([int]$me.data.permission -band 8) -eq 0) {
        throw 'Use a non-admin, non-root scoped account with directory/upload permission.'
    }
    $accountBase = [string]$me.data.base_path
    if ($accountBase -notmatch '^/[^/]+(?:/[^/]+)*/*$' -or $accountBase.Contains('\') -or
        @($accountBase.TrimEnd('/').Split('/') | Where-Object { $_ -in @('.', '..') }).Count -or
        [Uri]::UnescapeDataString($PublicBase.AbsolutePath) -cne ('/d' + $accountBase.TrimEnd('/') + $RemoteRoot + '/')) {
        throw 'PublicBase must expose exactly the scoped account base path plus RemoteRoot.'
    }
    Ensure-RemoteDirectory $RemoteRoot
    if (-not $SentinelOnly) { Ensure-RemoteDirectory ($RemoteRoot + '/objects') }
    Ensure-RemoteDirectory ($RemoteRoot + '/manifests')
    # An interrupted publish can have either half of the target sentinel.
    # Reuse an exact match; never replace different bytes at the target version.
    foreach ($ext in @('json', 'sig')) {
        $relative = "manifests/$TargetVersion.$ext"
        if ($null -ne (Get-RemoteMeta ($RemoteRoot + '/' + $relative))) {
            $limit = if ($ext -eq 'json') { 1048576 } else { 8192 }
            if (-not (Test-RemoteEqualsLocal $relative $limit)) {
                throw 'The target version already has different manifest bytes; refusing to overwrite them.'
            }
        }
    }
    if (-not $SentinelOnly) {
        $sourceJson = Get-RemoteMeta "$RemoteRoot/manifests/$FromVersion.json"
        $sourceSig = Get-RemoteMeta "$RemoteRoot/manifests/$FromVersion.sig"
        if ($null -eq $sourceJson -and $null -ne $sourceSig) {
            if (-not (Test-RemoteEqualsLocal "manifests/$FromVersion.sig" 8192)) {
                throw 'Existing source signature has no matching JSON; refusing to replace it.'
            }
        } elseif ($null -ne $sourceJson -and $null -eq $sourceSig) {
            if (-not (Test-RemoteEqualsLocal "manifests/$FromVersion.json" 1048576)) {
                throw 'Existing source JSON has no matching signature; refusing to replace it.'
            }
        } elseif ($null -ne $sourceJson) {
            $oldJson = Read-PublicBytes "manifests/$FromVersion.json" 1048576
            $oldSig = Read-PublicBytes "manifests/$FromVersion.sig" 8192
            $old = Read-SignedManifest $oldJson $oldSig
            $same = (Test-RemoteEqualsLocal "manifests/$FromVersion.json" 1048576) -and
                (Test-RemoteEqualsLocal "manifests/$FromVersion.sig" 8192)
            if (-not $same -and ($old.from -cne $FromVersion -or $old.to -cne $FromVersion -or $old.files.Count -ne 0)) {
                throw 'An existing source update must not be overwritten.'
            }
        }
    }
    foreach ($hash in @($objects.Keys | Sort-Object)) {
        $relative = 'objects/' + $hash
        $remote = Get-RemoteMeta ($RemoteRoot + '/' + $relative)
        if ($null -ne $remote) {
            Test-PublicObject $relative $objects[$hash] $hash
        } else {
            Publish-AndVerify $relative
        }
    }
    foreach ($ext in @('json', 'sig')) {
        $relative = "manifests/$TargetVersion.$ext"
        $remote = Get-RemoteMeta ($RemoteRoot + '/' + $relative)
        if ($null -eq $remote) {
            Publish-AndVerify $relative
        } else {
            $limit = if ($ext -eq 'json') { 1048576 } else { 8192 }
            if (-not (Test-RemoteEqualsLocal $relative $limit)) {
                throw 'A conflicting target manifest appeared during publishing; refusing to overwrite it.'
            }
        }
    }
    if (-not $SentinelOnly) {
        # Confirm the complete target marker before making the source update visible.
        Assert-PublishedManifest $TargetVersion
        foreach ($ext in @('json', 'sig')) {
            $relative = "manifests/$FromVersion.$ext"
            $remote = Get-RemoteMeta ($RemoteRoot + '/' + $relative)
            $limit = if ($ext -eq 'json') { 1048576 } else { 8192 }
            if ($null -eq $remote -or -not (Test-RemoteEqualsLocal $relative $limit)) { Publish-AndVerify $relative }
        }
        Assert-PublishedManifest $FromVersion
    }
    Assert-PublishedManifest $TargetVersion
    if (-not $SentinelOnly) {
        Write-Host "Published $FromVersion -> $TargetVersion. Final source and target manifest pairs match the local signed repository."
    } else {
        Write-Host "Published the signed no-update marker for $TargetVersion. The final manifest pair matches the local signed repository."
    }
    Write-Host 'The manifest and signature are separate files; publication is not atomic.'
} finally {
    $script:ApiToken = $null
    $Credential = $null
    $http.Dispose()
    $rsa.Dispose()
}
