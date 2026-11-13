$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop

# Check every existing component, including dangling links and ancestors of the
# installation root. Do not enumerate any contents of data/avd.
function Assert-UpdatePathSafe([string]$Path) {
    $parts = New-Object 'System.Collections.Generic.List[string]'
    $part = [IO.Path]::GetFullPath($Path)
    while ($part) {
        $parts.Add($part)
        $parent = [IO.Path]::GetDirectoryName($part.TrimEnd('\'))
        if (-not $parent -or [string]::Equals($part, $parent, [StringComparison]::OrdinalIgnoreCase)) { break }
        $part = $parent
    }
    for ($i = $parts.Count - 1; $i -ge 0; $i--) {
        try { $attributes = [IO.File]::GetAttributes($parts[$i]) }
        catch {
            $reason = $_.Exception
            while ($reason -is [Management.Automation.MethodInvocationException] -and $reason.InnerException) { $reason = $reason.InnerException }
            if ($reason -is [IO.FileNotFoundException] -or $reason -is [IO.DirectoryNotFoundException]) { continue }
            throw '无法确认更新路径是否安全。'
        }
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '更新路径不能包含链接或重解析点。' }
    }
}

function Get-UpdateMutexName([string]$Root) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $identity = [Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Root).TrimEnd('\').ToLowerInvariant())
        return 'Local\ArtemisOS-Update-' + ([BitConverter]::ToString($sha.ComputeHash($identity))).Replace('-', '').Substring(0, 24)
    } finally { $sha.Dispose() }
}

# Process metadata must be sufficient to distinguish this installation and
# its port before ADB is allowed to stop anything. Query failures stay fatal.
function Get-VerifiedUpdateEmulator([object[]]$Processes, [string]$Sdk, [string]$Serial, [int]$LauncherPid = 0) {
    if ($Serial -notmatch '^emulator-(\d+)$') { throw '模拟器编号无效。' }
    $port = $matches[1]
    $sdkPrefix = [IO.Path]::GetFullPath($Sdk).TrimEnd('\') + '\'
    $qemu = @(); $launchers = @()
    foreach ($process in @($Processes)) {
        if ($null -eq $process) { continue }
        if (-not $process.ExecutablePath) { throw '无法确认模拟器进程的安装路径。' }
        try { $path = [IO.Path]::GetFullPath([string]$process.ExecutablePath) }
        catch { throw '无法确认模拟器进程的安装路径。' }
        if (-not $path.StartsWith($sdkPrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($process.Name -ieq 'emulator.exe') { $launchers += $process }
        elseif ($process.Name -imatch '^qemu-system-x86_64(?:-headless)?\.exe$') { $qemu += $process }
        else { throw '无法确认模拟器进程类型。' }
    }
    if ($qemu.Count -gt 1 -or $launchers.Count -gt 1) { throw '无法唯一确认当前模拟器，未关闭或更新。' }
    if ($qemu.Count -eq 0) {
        if ($launchers.Count -gt 0) { throw '模拟器启动状态尚未确定，未关闭或更新。' }
        return $null
    }
    $instance = $qemu[0]
    $portPattern = '(?i)(?:^|\s)-port\s+"?' + [regex]::Escape($port) + '"?(?:\s|$)'
    if (-not $instance.CommandLine -or $instance.CommandLine -notmatch $portPattern) { throw '无法确认模拟器端口，未关闭或更新。' }
    if ($launchers.Count -eq 1) {
        if (-not $launchers[0].CommandLine -or $launchers[0].CommandLine -notmatch $portPattern -or
            [int]$instance.ParentProcessId -ne [int]$launchers[0].ProcessId) { throw '无法确认模拟器父子进程，未关闭或更新。' }
    }
    if ($LauncherPid -gt 0 -and ($launchers.Count -ne 1 -or [int]$launchers[0].ProcessId -ne $LauncherPid)) {
        throw '无法确认发起更新的模拟器进程。'
    }
    return $instance
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
    Assert-UpdatePathSafe $local
    Assert-UpdatePathSafe $default
    $path = if (Test-Path -LiteralPath $local -PathType Leaf) { $local } else { $default }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw '尚未配置更新服务器。' }
    $value = [IO.File]::ReadAllText($path).Trim()
    $uri = $null
    if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri)) {
        throw '更新服务器必须使用 HTTPS。'
    }
    # An explicit ?d on an OpenList share root selects its direct-read mode.
    # All other repositories retain the original query-free URL rules.
    $openListShare = $uri.Query -ceq '?d' -and $value.EndsWith('?d', [StringComparison]::Ordinal) -and
        $uri.AbsolutePath -cmatch '(?:^|/)sd/[A-Za-z0-9_-]+/?$'
    if (($uri.Query -and -not $openListShare) -or $uri.Fragment -or $uri.UserInfo -or
        $uri.Scheme -ne 'https') {
        throw '更新服务器必须使用 HTTPS。'
    }
    if ($openListShare) {
        $builder = [UriBuilder]$uri
        if (-not $builder.Path.EndsWith('/')) { $builder.Path += '/' }
        $uri = $builder.Uri
    } elseif (-not $uri.AbsoluteUri.EndsWith('/')) { $uri = [Uri]($uri.AbsoluteUri + '/') }
    return $uri
}

function Get-UpdateResourceUri([Uri]$Base, [string]$Relative) {
    if ($Base.Query -ceq '?d') {
        $builder = [UriBuilder]$Base
        $builder.Query = ''
        $target = [Uri]::new($builder.Uri, $Relative)
        $builder = [UriBuilder]$target
        $builder.Query = 'd'
        return $builder.Uri
    }
    return [Uri]::new($Base, $Relative)
}

function Assert-UpdateContentPrefix([byte[]]$Bytes, [int]$Count) {
    # Content-Type alone is insufficient: login/error pages are sometimes
    # returned as application/octet-stream by storage gateways.
    $prefix = [Text.Encoding]::UTF8.GetString($Bytes, 0, [Math]::Min($Count, 8192)).TrimStart([char]0xFEFF)
    if ($prefix -match '(?is)^\s*(?:<!doctype\s+html\b|<html\b|<head\b|<body\b|<\?xml[^>]*>\s*<html\b)') {
        throw '更新服务器返回了 HTML 页面，未使用此下载内容。'
    }
}

function Open-UpdateResponse([Uri]$Uri, [long]$RangeEnd = -1) {
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $redirects = 0
    while ($true) {
        if ($Uri.UserInfo -or $Uri.Fragment -or
            $Uri.Scheme -cne 'https') {
            throw '更新下载必须使用 HTTPS，且不能包含用户凭据或片段。'
        }
        if (-not $visited.Add($Uri.AbsoluteUri)) { throw '更新下载出现重定向循环。' }
        # Never reuse an authenticated request, cookie container or session.
        # Every hop, even on the original host, is an anonymous GET.
        $request = [Net.HttpWebRequest]::Create($Uri)
        $request.Method = 'GET'
        $request.Timeout = 30000
        $request.ReadWriteTimeout = 30000
        $request.AllowAutoRedirect = $false
        $request.UseDefaultCredentials = $false
        $request.Credentials = $null
        $request.PreAuthenticate = $false
        $request.CookieContainer = $null
        $request.CachePolicy = [Net.Cache.RequestCachePolicy]::new([Net.Cache.RequestCacheLevel]::NoCacheNoStore)
        $request.UserAgent = 'ArtemisOS-Updater/2'
        if ($RangeEnd -ge 0) { $request.AddRange([long]0, $RangeEnd) }
        try { $response = $request.GetResponse() }
        catch [Net.WebException] {
            $cause = $_.Exception
            while ($cause -isnot [Net.WebException] -and $cause.InnerException) { $cause = $cause.InnerException }
            $httpStatus = 0
            if ($cause.Response) {
                $httpStatus = [int]$cause.Response.StatusCode
                $cause.Response.Dispose()
            }
            # Avoid exposing a provider's temporary signed URL in exception
            # output, while retaining the status needed for a missing manifest.
            $failure = [Net.WebException]::new("更新下载连接失败（HTTP $httpStatus）。")
            $failure.Data['ArtemisHttpStatus'] = $httpStatus
            throw $failure
        }
        $status = [int]$response.StatusCode
        if ($status -in @(301,302,303,307,308)) {
            try {
                if ($redirects -ge 5) { throw '更新下载重定向次数超限。' }
                $location = $response.Headers['Location']
                if ([string]::IsNullOrWhiteSpace($location)) { throw '更新下载缺少重定向地址。' }
                $next = $null
                if (-not [Uri]::TryCreate($Uri, $location, [ref]$next) -or $next.Scheme -cne 'https' -or
                    $next.UserInfo -or $next.Fragment) { throw '更新下载重定向必须使用无凭据的 HTTPS 地址。' }
                $Uri = $next
                $redirects++
            } finally { $response.Dispose() }
            continue
        }
        if ($status -ne 200 -and -not ($RangeEnd -ge 0 -and $status -eq 206)) {
            $response.Dispose()
            throw "更新下载未返回完整文件（HTTP $status）。"
        }
        if ($response.ContentType -match '^(?i:text/html|application/xhtml\+xml)(?:\s*;|\s*$)') {
            $response.Dispose()
            throw '更新服务器返回了 HTML 页面，未使用此下载内容。'
        }
        return $response
    }
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
        $bytes = $memory.ToArray()
        if ($bytes.Length -eq 0) { throw '更新服务器返回了空文件。' }
        Assert-UpdateContentPrefix $bytes $bytes.Length
        return ,$bytes
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
    Assert-UpdatePathSafe $full
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

function Verify-UpdateManifest([string]$Root, [byte[]]$Bytes, [byte[]]$SignatureBytes, [switch]$AllowNoUpdate) {
    $publicPath = Join-Path $Root 'update\trusted-key.xml'
    Assert-UpdatePathSafe $publicPath
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
        [version]$manifest.to -lt [version]$manifest.from -or $manifest.from -ne (Get-UpdateVersion $Root)) {
        throw '更新包与当前版本不匹配。'
    }
    if ($manifest.notes -isnot [string] -or $manifest.notes.Length -gt 2000) { throw '更新说明无效。' }
    # A signed, explicitly empty same-version manifest is a no-update marker.
    # Only the check operation opts in: staging and installation stay strict.
    if ($manifest.to -ceq $manifest.from) {
        if (-not $AllowNoUpdate -or $manifest.files -isnot [array] -or $manifest.files.Count -ne 0) {
            throw '更新包与当前版本不匹配。'
        }
        return $manifest
    }
    if ([version]$manifest.to -le [version]$manifest.from) { throw '更新包与当前版本不匹配。' }
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
    return $manifest
}

function Get-UpdateOffer([string]$Root) {
    $base = Get-UpdateBaseUri $Root
    $version = Get-UpdateVersion $Root
    try { $bytes = Read-UpdateBytes (Get-UpdateResourceUri $base "manifests/$version.json") 1048576 }
    catch [Net.WebException] {
        if ($_.Exception.Data['ArtemisHttpStatus'] -eq 404 -or
            ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404)) {
            throw '更新清单不存在，无法确认是否有新版本。'
        }
        throw '无法连接更新服务器。'
    }
    $signature = Read-UpdateBytes (Get-UpdateResourceUri $base "manifests/$version.sig") 8192
    $manifest = Verify-UpdateManifest $Root $bytes $signature -AllowNoUpdate
    if ($manifest.to -ceq $manifest.from) { return $null }
    return [pscustomobject]@{ Base = $base; Bytes = $bytes; Signature = $signature; Manifest = $manifest }
}

function Save-UpdateObject([Uri]$Uri, [string]$Path, [long]$ExpectedSize, [string]$ExpectedHash) {
    Assert-UpdatePathSafe $Path
    $response = Open-UpdateResponse $Uri
    $inputStream = $null
    $outputStream = $null
    $prefix = New-Object IO.MemoryStream
    try {
        if ($response.ContentLength -ge 0 -and $response.ContentLength -ne $ExpectedSize) { throw '更新文件大小不匹配。' }
        $inputStream = $response.GetResponseStream()
        $outputStream = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = New-Object byte[] 65536
        $total = [long]0
        $prefixChecked = $false
        while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if (-not $prefixChecked) {
                $prefix.Write($buffer, 0, [Math]::Min($count, 8192 - [int]$prefix.Length))
                if ($prefix.Length -eq 8192) {
                    Assert-UpdateContentPrefix ($prefix.ToArray()) ([int]$prefix.Length)
                    $prefixChecked = $true
                }
            }
            $total += $count
            if ($total -gt $ExpectedSize) { throw '更新文件超出预期大小。' }
            $outputStream.Write($buffer, 0, $count)
        }
        if (-not $prefixChecked) { Assert-UpdateContentPrefix ($prefix.ToArray()) ([int]$prefix.Length) }
        $outputStream.Flush()
        $outputStream.Dispose(); $outputStream = $null
        if ($total -ne $ExpectedSize -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ExpectedHash) {
            throw '更新文件校验失败。'
        }
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        $prefix.Dispose()
        $response.Dispose()
    }
}

function Stage-UpdateOffer([string]$Root, $Offer) {
    $staging = Join-Path $Root ('data\update\staged-' + [Guid]::NewGuid().ToString('N'))
    Assert-UpdatePathSafe $staging
    [void][IO.Directory]::CreateDirectory($staging)
    Assert-UpdatePathSafe $staging
    Assert-UpdatePathSafe (Join-Path $staging 'manifest.json')
    Assert-UpdatePathSafe (Join-Path $staging 'manifest.sig')
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
        Assert-UpdatePathSafe $destination
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
            Save-UpdateObject (Get-UpdateResourceUri $Offer.Base "objects/$($file.sha256)") $destination ([long]$file.size) $file.sha256
        }
    }
    $versionItem = @($Offer.Manifest.files | Where-Object { $_.path -eq 'version.ini' })[0]
    $newVersion = [IO.File]::ReadAllText((Join-Path $staging $versionItem.sha256))
    if ($newVersion -notmatch ('(?m)^Version=' + [regex]::Escape($Offer.Manifest.to) + '\r?$')) {
        throw '更新包的版本信息不一致。'
    }
    return $staging
}
