<#
.SYNOPSIS
Creates only a signed no-update marker for the version in TargetRoot.
It does not inspect an old release, create an update manifest, or copy objects.

.EXAMPLE
./New-UpdateSentinel.ps1 -TargetRoot C:\release -Repository C:\sentinel-repo
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetRoot,
    [Parameter(Mandatory = $true)][string]$Repository,
    [string]$KeyDirectory = (Join-Path $env:LOCALAPPDATA 'ArtemisOS-Dev\signing')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$project = Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'stage\update\core.ps1')
$TargetRoot = [IO.Path]::GetFullPath($TargetRoot)
$Repository = [IO.Path]::GetFullPath($Repository)
$KeyDirectory = [IO.Path]::GetFullPath($KeyDirectory)
$version = Get-UpdateVersion $TargetRoot
$keyPath = Join-Path $KeyDirectory 'ota-private.dpapi'
$publicPath = Join-Path $TargetRoot 'update\trusted-key.xml'
if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $publicPath -PathType Leaf)) {
    throw 'The signing key or target trusted public key is missing.'
}

$sentinel = [ordered]@{ schema=1; product='ArtemisOS-15'; from=$version; to=$version; notes=''; files=@() }
$bytes = [Text.Encoding]::UTF8.GetBytes(($sentinel | ConvertTo-Json -Depth 8))
$protected = [IO.File]::ReadAllBytes($keyPath)
$private = [Security.Cryptography.ProtectedData]::Unprotect($protected, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
$rsa.PersistKeyInCsp = $false
try {
    $rsa.FromXmlString([Text.Encoding]::UTF8.GetString($private))
    if ($rsa.ToXmlString($false) -cne [IO.File]::ReadAllText($publicPath).Trim()) {
        throw 'The signing key does not match the target trusted public key.'
    }
    $signature = [Text.Encoding]::ASCII.GetBytes([Convert]::ToBase64String($rsa.SignData($bytes, 'SHA256')))
} finally {
    $rsa.Dispose()
    [Array]::Clear($private, 0, $private.Length)
}

$manifests = Join-Path $Repository 'manifests'
[void][IO.Directory]::CreateDirectory($manifests)
$files = @(
    @{ Path = (Join-Path $manifests "$version.sig"); Bytes = $signature },
    @{ Path = (Join-Path $manifests "$version.json"); Bytes = $bytes }
)

# Validate both target paths before creating either. Existing identical files
# are reusable after an interrupted operation; conflicting content is never
# overwritten, even if it happens to be a signed update to a later release.
foreach ($file in $files) {
    if (Test-Path -LiteralPath $file.Path) {
        $item = Get-Item -LiteralPath $file.Path -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($file.Path)) -cne [Convert]::ToBase64String($file.Bytes)) {
            throw 'The target version already has different manifest bytes; refusing to overwrite them.'
        }
    }
}
foreach ($file in $files) {
    if (-not (Test-Path -LiteralPath $file.Path)) {
        $stream = [IO.File]::Open($file.Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($file.Bytes, 0, $file.Bytes.Length) }
        finally { $stream.Dispose() }
    }
}
Write-Host "Prepared only the signed no-update marker for $version."
