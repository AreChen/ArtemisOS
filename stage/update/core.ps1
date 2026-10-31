$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop

function Get-UpdateMutexName([string]$Root) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $identity = [Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Root).TrimEnd('\').ToLowerInvariant())
        return 'Local\ArtemisOS-Update-' + ([BitConverter]::ToString($sha.ComputeHash($identity))).Replace('-', '').Substring(0, 24)
    } finally { $sha.Dispose() }
}

function Get-UpdateVersion([string]$Root) {
    $versionPath = Join-Path $Root 'version.ini'
    foreach ($line in [IO.File]::ReadAllLines($versionPath)) {
        if ($line -match '^Version=(\d+\.\d+\.\d+)$') { return $matches[1] }
    }
    throw '无法读取当前版本。'
}

function Get-UpdateBaseUri([string]$Root) {
    $local = Join-Path $Root 'data\update\server.txt'
    $default = Join-Path $Root 'update\server.txt'
    $path = if (Test-Path -LiteralPath $local -PathType Leaf) { $local } else { $default }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw '尚未配置更新服务器。' }
    $value = [IO.File]::ReadAllText($path).Trim()
    $uri = $null
    if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Query -or $uri.Fragment -or $uri.UserInfo -or
        ($uri.Scheme -ne 'https' -and -not ($uri.Scheme -eq 'http' -and $uri.IsLoopback))) {
        throw '更新服务器必须使用 HTTPS（本机测试可使用 loopback HTTP）。'
    }
    if (-not $uri.AbsoluteUri.EndsWith('/')) { $uri = [Uri]($uri.AbsoluteUri + '/') }
    return $uri
}

function Open-UpdateResponse([Uri]$Uri) {
    $request = [Net.HttpWebRequest]::Create($Uri)
    $request.Method = 'GET'
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 30000
    $request.AllowAutoRedirect = $false
    $request.UserAgent = 'ArtemisOS-Updater/1'
    return $request.GetResponse()
}

function Read-UpdateBytes([Uri]$Uri, [int]$Maximum) {
    $response = Open-UpdateResponse $Uri
    $stream = $null
    $memory = New-Object IO.MemoryStream
    try {
        if ($response.ContentLength -gt $Maximum) { throw '更新元数据过大。' }
        $stream = $response.GetResponseStream()
        $buffer = New-Object byte[] 8192
        while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($memory.Length + $count -gt $Maximum) { throw '更新元数据过大。' }
            $memory.Write($buffer, 0, $count)
        }
        return ,$memory.ToArray()
    } finally {
        if ($stream) { $stream.Dispose() }
        $memory.Dispose()
        $response.Dispose()
    }
}

function Get-UpdateTarget([string]$Root, [string]$Relative) {
    $rootFiles = @('launch.ps1','settings.ps1','initialize.ps1','configure.ps1','configure.vbs',
        'start-auto.vbs','start-software.vbs','version.ini','ArtemisOS15.ico')
    $segments = $Relative -split '/'
    if ($Relative -notmatch '^[A-Za-z0-9._/-]+$' -or $Relative.Contains('//') -or
        @($segments | Where-Object { $_ -in @('', '.', '..') -or $_.EndsWith('.') -or $_ -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)' }).Count -gt 0) {
        throw '更新包包含无效的文件路径。'
    }
    $allowed = $Relative -in $rootFiles -or
        ($Relative -match '^update/[A-Za-z0-9._/-]+$' -and $Relative -notin @('update/recovery.ps1','update/trusted-key.xml','update/server.txt')) -or
        ($Relative -match '^sdk/[A-Za-z0-9._/-]+$')
    if (-not $allowed) { throw "更新包不能修改此路径：$Relative" }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath((Join-Path $Root ($Relative.Replace('/', '\'))))
    if (-not $full.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)) { throw '更新文件路径超出安装目录。' }
    $part = $Root
    foreach ($segment in $segments) {
        $part = Join-Path $part $segment
        if (Test-Path -LiteralPath $part) {
            if ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw '更新路径不能经过链接或重解析点。'
            }
        }
    }
    return $full
}

function Verify-UpdateManifest([string]$Root, [byte[]]$Bytes, [byte[]]$SignatureBytes) {
    $publicPath = Join-Path $Root 'update\trusted-key.xml'
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    $rsa.PersistKeyInCsp = $false
    try {
        $rsa.FromXmlString([IO.File]::ReadAllText($publicPath))
        $signature = [Convert]::FromBase64String([Text.Encoding]::ASCII.GetString($SignatureBytes).Trim())
        if (-not $rsa.VerifyData($Bytes, 'SHA256', $signature)) { throw '更新签名验证失败。' }
    } finally { $rsa.Dispose() }
    $manifest = [Text.Encoding]::UTF8.GetString($Bytes) | ConvertFrom-Json
    if ($manifest.schema -ne 1 -or $manifest.product -ne 'ArtemisOS-15' -or
        $manifest.from -notmatch '^\d+\.\d+\.\d+$' -or $manifest.to -notmatch '^\d+\.\d+\.\d+$' -or
        [version]$manifest.to -le [version]$manifest.from -or $manifest.from -ne (Get-UpdateVersion $Root)) {
        throw '更新包与当前版本不匹配。'
    }
    $files = @($manifest.files)
    if ($files.Count -lt 1 -or $files.Count -gt 1000) { throw '更新包文件列表无效。' }
    $seen = @{}
    $hasVersion = $false
    foreach ($file in $files) {
        if ($null -eq $file -or $file.path -isnot [string] -or $file.sha256 -notmatch '^[0-9a-f]{64}$' -or
            $file.base_sha256 -notmatch '^(?:-|[0-9a-f]{64})$' -or $file.size -isnot [ValueType] -or
            $file.size -lt 0 -or $file.size -gt 10737418240) { throw '更新包文件信息无效。' }
        [void](Get-UpdateTarget $Root $file.path)
        $key = $file.path.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { throw '更新包包含重复文件。' }
        $seen[$key] = $true
        if ($file.path -eq 'version.ini') { $hasVersion = $true }
    }
    if (-not $hasVersion) { throw '更新包未包含版本信息。' }
    if ($manifest.notes -isnot [string] -or $manifest.notes.Length -gt 2000) { throw '更新说明无效。' }
    return $manifest
}

function Get-UpdateOffer([string]$Root) {
    $base = Get-UpdateBaseUri $Root
    $version = Get-UpdateVersion $Root
    try { $bytes = Read-UpdateBytes ([Uri]::new($base, "manifests/$version.json")) 1048576 }
    catch [Net.WebException] {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $null }
        throw '无法连接更新服务器。'
    }
    $signature = Read-UpdateBytes ([Uri]::new($base, "manifests/$version.sig")) 8192
    $manifest = Verify-UpdateManifest $Root $bytes $signature
    return [pscustomobject]@{ Base = $base; Bytes = $bytes; Signature = $signature; Manifest = $manifest }
}

function Save-UpdateObject([Uri]$Uri, [string]$Path, [long]$ExpectedSize, [string]$ExpectedHash) {
    $response = Open-UpdateResponse $Uri
    $inputStream = $null
    $outputStream = $null
    try {
        if ($response.ContentLength -ge 0 -and $response.ContentLength -ne $ExpectedSize) { throw '更新文件大小不匹配。' }
        $inputStream = $response.GetResponseStream()
        $outputStream = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = New-Object byte[] 65536
        $total = [long]0
        while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $count
            if ($total -gt $ExpectedSize) { throw '更新文件超出预期大小。' }
            $outputStream.Write($buffer, 0, $count)
        }
        $outputStream.Flush()
        $outputStream.Dispose(); $outputStream = $null
        if ($total -ne $ExpectedSize -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ExpectedHash) {
            throw '更新文件校验失败。'
        }
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        $response.Dispose()
    }
}

function Stage-UpdateOffer([string]$Root, $Offer) {
    $staging = Join-Path $Root ('data\update\staged-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($staging)
    [IO.File]::WriteAllBytes((Join-Path $staging 'manifest.json'), $Offer.Bytes)
    [IO.File]::WriteAllBytes((Join-Path $staging 'manifest.sig'), $Offer.Signature)
    foreach ($file in @($Offer.Manifest.files)) {
        $target = Get-UpdateTarget $Root $file.path
        if ($file.base_sha256 -eq '-') {
            if (Test-Path -LiteralPath $target) { throw "更新前文件已存在：$($file.path)" }
        } elseif (-not (Test-Path -LiteralPath $target -PathType Leaf) -or
            (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $file.base_sha256) {
            throw "更新前文件与预期版本不符：$($file.path)"
        }
        $destination = Join-Path $staging $file.sha256
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
            Save-UpdateObject ([Uri]::new($Offer.Base, "objects/$($file.sha256)")) $destination ([long]$file.size) $file.sha256
        }
    }
    $versionItem = @($Offer.Manifest.files | Where-Object { $_.path -eq 'version.ini' })[0]
    $newVersion = [IO.File]::ReadAllText((Join-Path $staging $versionItem.sha256))
    if ($newVersion -notmatch ('(?m)^Version=' + [regex]::Escape($Offer.Manifest.to) + '\r?$')) {
        throw '更新包的版本信息不一致。'
    }
    return $staging
}
