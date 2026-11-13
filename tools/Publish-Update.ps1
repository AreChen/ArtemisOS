param(
    [Parameter(Mandatory = $true)][string]$BaseRoot,
    [Parameter(Mandatory = $true)][string]$TargetRoot,
    [string]$Repository,
    [string]$KeyDirectory = (Join-Path $env:LOCALAPPDATA 'ArtemisOS-Dev\signing'),
    [string]$Notes = '修复和体验改进。',
    [switch]$IncludeSdk,
    [switch]$PublishNoUpdateSentinel = $true
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$project = Split-Path -Parent $PSScriptRoot
if (-not $Repository) { $Repository = Join-Path $project 'server\repository' }
. (Join-Path $project 'stage\update\core.ps1')
$BaseRoot = [IO.Path]::GetFullPath($BaseRoot)
$TargetRoot = [IO.Path]::GetFullPath($TargetRoot)
$from = Get-UpdateVersion $BaseRoot
$to = Get-UpdateVersion $TargetRoot
if ([version]$to -le [version]$from) { throw '目标版本必须高于原版本。' }
if (-not $PublishNoUpdateSentinel) { throw '发布必须包含目标版本的已签名无更新标记。' }
if ($Notes.Length -gt 2000) { throw '更新说明过长。' }
$keyPath = Join-Path $KeyDirectory 'ota-private.dpapi'
if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) { throw '未找到 OTA 签名私钥。' }
$rootFiles = @('launch.ps1','settings.ps1','initialize.ps1','configure.ps1','configure.vbs',
    'start-auto.vbs','start-software.vbs','version.ini','ArtemisOS15.ico')
$paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($name in $rootFiles) { [void]$paths.Add($name) }
$carrierMapPath = 'sdk/system-images/android-35/google_apis/x86_64/data/misc/modem_simulator/etc/modem_simulator/files/numeric_operator.xml'
$carrierMapSource = Join-Path $TargetRoot 'carrier-operators.xml'
if (Test-Path -LiteralPath $carrierMapSource -PathType Leaf) { [void]$paths.Add($carrierMapPath) }
foreach ($subdir in @('update') + $(if ($IncludeSdk) { @('sdk') } else { @() })) {
    $directory = Join-Path $TargetRoot $subdir
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $directory -File -Recurse) {
        $relative = $file.FullName.Substring($TargetRoot.TrimEnd('\').Length + 1).Replace('\','/')
        if ($relative -in @('update/recovery.ps1','update/trusted-key.xml','update/server.txt','update/test-marker.txt')) { continue }
        [void](Get-UpdateTarget $TargetRoot $relative)
        [void]$paths.Add($relative)
    }
}
$objects = Join-Path $Repository 'objects'
$manifests = Join-Path $Repository 'manifests'
[void][IO.Directory]::CreateDirectory($objects)
[void][IO.Directory]::CreateDirectory($manifests)
if ($PublishNoUpdateSentinel -and
    ((Test-Path -LiteralPath (Join-Path $manifests "$to.json")) -or
     (Test-Path -LiteralPath (Join-Path $manifests "$to.sig")))) {
    throw '目标版本已存在清单或签名；为避免覆盖后续更新，未生成无更新标记。'
}
$files = @()
foreach ($relative in ($paths | Sort-Object)) {
    $target = if ($relative -eq $carrierMapPath -and (Test-Path -LiteralPath $carrierMapSource -PathType Leaf)) {
        $carrierMapSource
    } else { Get-UpdateTarget $TargetRoot $relative }
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { continue }
    $base = Get-UpdateTarget $BaseRoot $relative
    $oldHash = if (Test-Path -LiteralPath $base -PathType Leaf) {
        (Get-FileHash -LiteralPath $base -Algorithm SHA256).Hash.ToLowerInvariant()
    } else { '-' }
    $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -eq $oldHash) { continue }
    $object = Join-Path $objects $hash
    if (Test-Path -LiteralPath $object -PathType Leaf) {
        if ((Get-FileHash -LiteralPath $object -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) {
            throw '服务器仓库里已有同名但内容不符的文件。'
        }
    } else { Copy-Item -LiteralPath $target -Destination $object }
    $files += [ordered]@{ path=$relative; base_sha256=$oldHash; sha256=$hash; size=(Get-Item -LiteralPath $target).Length }
}
if (-not @($files | Where-Object { $_.path -eq 'version.ini' }).Count) { throw '必须更新版本文件。' }
$manifest = [ordered]@{ schema=1; product='ArtemisOS-15'; from=$from; to=$to; notes=$Notes; files=$files }
$bytes = [Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 8))
$protected = [IO.File]::ReadAllBytes($keyPath)
$private = [Security.Cryptography.ProtectedData]::Unprotect($protected, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
$rsa.PersistKeyInCsp = $false
try {
    $rsa.FromXmlString([Text.Encoding]::UTF8.GetString($private))
    $public = [IO.File]::ReadAllText((Join-Path $TargetRoot 'update\trusted-key.xml')).Trim()
    if ($rsa.ToXmlString($false) -ne $public) { throw '签名私钥与目标版本的公钥不匹配。' }
    $signature = $rsa.SignData($bytes, 'SHA256')
    if ($PublishNoUpdateSentinel) {
        $sentinel = [ordered]@{ schema=1; product='ArtemisOS-15'; from=$to; to=$to; notes=''; files=@() }
        $sentinelBytes = [Text.Encoding]::UTF8.GetBytes(($sentinel | ConvertTo-Json -Depth 8))
        $sentinelSignature = $rsa.SignData($sentinelBytes, 'SHA256')
    }
} finally {
    $rsa.Dispose()
    [Array]::Clear($private, 0, $private.Length)
}
if ($PublishNoUpdateSentinel) {
    [IO.File]::WriteAllText((Join-Path $manifests "$to.sig"), [Convert]::ToBase64String($sentinelSignature), [Text.Encoding]::ASCII)
    [IO.File]::WriteAllBytes((Join-Path $manifests "$to.json"), $sentinelBytes)
}
[IO.File]::WriteAllText((Join-Path $manifests "$from.sig"), [Convert]::ToBase64String($signature), [Text.Encoding]::ASCII)
[IO.File]::WriteAllBytes((Join-Path $manifests "$from.json"), $bytes)
Write-Host "已发布 $from -> $to，包含 $($files.Count) 个变化文件。"
