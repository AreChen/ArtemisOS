<#
DEPRECATED HISTORICAL TOOL — DO NOT RUN for the current /d/ OTA repository.
This fixed-version repair publisher targets the retired /sd/ share deployment.
Retained only to explain historical releases; it is not part of current publishing.
Use Publish-OpenList.ps1 with -PublicBase for signed OTA repository publication.
#>
param(
    [Parameter(Mandatory=$true)][string]$File,
    [Parameter(Mandatory=$true)][string]$InstallRoot,
    [Parameter(Mandatory=$true)][System.Management.Automation.PSCredential]$Credential
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'stage\update\core.ps1')
$filePath = [IO.Path]::GetFullPath($File)
$name = [IO.Path]::GetFileName($filePath)
if ($name -cne 'ArtemisOS15-OTA-Repair-1.0.2.exe' -or -not (Test-Path -LiteralPath $filePath -PathType Leaf)) { throw 'Unexpected repair executable.' }
$hash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
$length = (Get-Item -LiteralPath $filePath).Length
if ($length -le 0 -or $length -gt 10485760) { throw 'Unexpected repair executable size.' }
$base = Get-UpdateBaseUri $InstallRoot
if ($base.Scheme -cne 'https' -or $base.Host -cne 'cloudx.playones.com' -or $base.Query -cne '?d' -or
    $base.AbsolutePath -cnotmatch '^/sd/([A-Za-z0-9_-]+)/$') { throw 'Unexpected update share.' }
$shareId = $Matches[1]
$origin = $base.GetLeftPart([UriPartial]::Authority)
$remoteRoot = '/ota'
$remoteFile = $remoteRoot + '/repair/' + $name
$publicUri = $origin + '/sd/' + [uri]::EscapeDataString($shareId) + '/repair/' + [uri]::EscapeDataString($name) + '?d'
$handler = New-Object Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $false
$http = New-Object Net.Http.HttpClient($handler)
$http.Timeout = [TimeSpan]::FromMinutes(2)
$script:token = $null
function Invoke-Api([string]$Method,[string]$Path,$Body,[bool]$Auth) {
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $origin + $Path)
    try {
        if ($Auth) { [void]$request.Headers.TryAddWithoutValidation('Authorization',$script:token) }
        if ($null -ne $Body) { $request.Content = [Net.Http.StringContent]::new(($Body | ConvertTo-Json -Compress -Depth 8),[Text.Encoding]::UTF8,'application/json') }
        $response=$http.SendAsync($request).GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) { throw 'OpenList API returned an HTTP error.' }
            return ($response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json)
        } finally { $response.Dispose() }
    } finally { $request.Dispose() }
}
function Get-Meta([string]$Path) {
    $result=Invoke-Api 'POST' '/api/fs/get' @{path=$Path;password=''} $true
    if ($result.code -eq 200) { return $result.data }
    if ($result.code -eq 500 -and $result.message -ceq 'object not found') { return $null }
    throw 'Could not determine the remote file state.'
}
function Verify-PublicFile {
    $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,$publicUri)
    try {
        $response=$http.SendAsync($request).GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) { throw 'Anonymous download failed.' }
            $bytes=$response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            if ($bytes.Length -ne $length) { throw 'Downloaded repair file has an unexpected size.' }
            $sha=[Security.Cryptography.SHA256]::Create()
            try { $actual=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
            if ($actual -cne $hash) { throw 'Downloaded repair file does not match.' }
        } finally { $response.Dispose() }
    } finally { $request.Dispose() }
}
try {
    $loginBody=@{username=$Credential.UserName;password=$Credential.GetNetworkCredential().Password}
    try { $login=Invoke-Api 'POST' '/api/auth/login' $loginBody $false } finally { $loginBody=$null }
    if ($login.code -ne 200 -or -not $login.data.token) { throw 'OpenList login failed.' }
    $script:token=$login.data.token; $login=$null
    $me=Invoke-Api 'GET' '/api/me' $null $true
    if ($me.code -ne 200 -or $me.data.disabled -or [int]$me.data.role -ne 0 -or
        [string]::IsNullOrWhiteSpace([string]$me.data.base_path) -or $me.data.base_path -eq '/' -or
        ([int]$me.data.permission -band 8) -eq 0) { throw 'Unexpected publishing account.' }
    $share=Invoke-Api 'GET' ('/api/share/get?id=' + [uri]::EscapeDataString($shareId)) $null $true
    if ($share.code -ne 200 -or $share.data.disabled -or $share.data.pwd -or @($share.data.files).Count -ne 1 -or
        $share.data.files[0] -cne ($me.data.base_path.TrimEnd('/') + $remoteRoot) -or
        ($share.data.expires -and [DateTimeOffset]$share.data.expires -le [DateTimeOffset]::UtcNow)) { throw 'Unexpected update share configuration.' }
    $directory=Get-Meta ($remoteRoot + '/repair')
    if ($null -eq $directory) {
        $result=Invoke-Api 'POST' '/api/fs/mkdir' @{path=($remoteRoot + '/repair')} $true
        if ($result.code -ne 200) { throw 'Could not create repair directory.' }
    } elseif (-not $directory.is_dir) { throw 'Repair path is not a directory.' }
    $existing=Get-Meta $remoteFile
    if ($null -ne $existing) {
        if ($existing.is_dir) { throw 'Repair file path is a directory.' }
        Verify-PublicFile
    } else {
        $segments=@($remoteFile.TrimStart('/').Split('/') | ForEach-Object { [uri]::EscapeDataString($_) })
        $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Put,$origin + '/api/fs/put')
        try {
            [void]$request.Headers.TryAddWithoutValidation('Authorization',$script:token)
            [void]$request.Headers.TryAddWithoutValidation('File-Path',('/' + ($segments -join '/')))
            [void]$request.Headers.TryAddWithoutValidation('As-Task','false')
            $stream=[IO.File]::Open($filePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            $request.Content=[Net.Http.StreamContent]::new($stream)
            $request.Content.Headers.ContentType=[Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
            $request.Content.Headers.ContentLength=$length
            $response=$http.SendAsync($request).GetAwaiter().GetResult()
            try {
                if (-not $response.IsSuccessStatusCode) { throw 'Repair upload returned an HTTP error.' }
                $result=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
                if ($result.code -ne 200) { throw 'Repair upload failed.' }
            } finally { $response.Dispose() }
        } finally { $request.Dispose() }
        Verify-PublicFile
    }
    Write-Output ([pscustomobject]@{Url=$publicUri;Size=$length;Sha256=$hash})
} finally {
    $script:token=$null; $Credential=$null; $http.Dispose(); $handler.Dispose()
}
