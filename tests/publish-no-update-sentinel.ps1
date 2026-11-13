$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$project = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path $project ('build\sentinel-publisher-test-' + [Guid]::NewGuid().ToString('N'))
$base = Join-Path $fixture 'base'
$target = Join-Path $fixture 'target'
$repository = Join-Path $fixture 'repository'
$keys = Join-Path $fixture 'keys'
foreach ($directory in @((Join-Path $base 'update'), (Join-Path $target 'update'), $keys)) {
    [void][IO.Directory]::CreateDirectory($directory)
}
[IO.File]::WriteAllText((Join-Path $base 'version.ini'), "[ArtemisOS]`nVersion=0.3.4`n")
[IO.File]::WriteAllText((Join-Path $target 'version.ini'), "[ArtemisOS]`nVersion=0.3.5`n")
[IO.File]::WriteAllText((Join-Path $base 'launch.ps1'), 'old launcher')
[IO.File]::WriteAllText((Join-Path $target 'launch.ps1'), 'new launcher')
# The installer excludes this development-only marker, so an update must not
# accidentally introduce it when a stage directory is used as the target.
[IO.File]::WriteAllText((Join-Path $target 'update\test-marker.txt'), 'development only')
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(2048)
$rsa.PersistKeyInCsp = $false
try {
    $public = $rsa.ToXmlString($false)
    [IO.File]::WriteAllText((Join-Path $target 'update\trusted-key.xml'), $public)
    $private = [Text.Encoding]::UTF8.GetBytes($rsa.ToXmlString($true))
    try {
        $protected = [Security.Cryptography.ProtectedData]::Protect($private, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        [IO.File]::WriteAllBytes((Join-Path $keys 'ota-private.dpapi'), $protected)
    } finally { [Array]::Clear($private, 0, $private.Length) }

    $publisher = Join-Path $project 'tools\Publish-Update.ps1'
    & $publisher -BaseRoot $base -TargetRoot $target -Repository $repository -KeyDirectory $keys -PublishNoUpdateSentinel
    $sentinelPath = Join-Path $repository 'manifests\0.3.5.json'
    $signaturePath = Join-Path $repository 'manifests\0.3.5.sig'
    $bytes = [IO.File]::ReadAllBytes($sentinelPath)
    $signature = [Convert]::FromBase64String([IO.File]::ReadAllText($signaturePath).Trim())
    if (-not $rsa.VerifyData($bytes, 'SHA256', $signature)) { throw 'Sentinel signature is invalid.' }
    $sentinel = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    if ($sentinel.schema -ne 1 -or $sentinel.product -ne 'ArtemisOS-15' -or
        $sentinel.from -ne '0.3.5' -or $sentinel.to -ne '0.3.5' -or @($sentinel.files).Count -ne 0) {
        throw 'Sentinel does not describe the exact installed version.'
    }
    $update = [IO.File]::ReadAllText((Join-Path $repository 'manifests\0.3.4.json')) | ConvertFrom-Json
    if ($update.from -ne '0.3.4' -or $update.to -ne '0.3.5' -or @($update.files).Count -ne 2) {
        throw 'Update manifest is missing or has an unexpected baseline.'
    }
    $before = (Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash
    $rejected = $false
    try {
        & $publisher -BaseRoot $base -TargetRoot $target -Repository $repository -KeyDirectory $keys -PublishNoUpdateSentinel
    } catch { $rejected = $true }
    if (-not $rejected -or (Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash -ne $before) {
        throw 'Publishing must not overwrite an existing target manifest.'
    }
    $ordinaryRepository = Join-Path $fixture 'ordinary-repository'
    & $publisher -BaseRoot $base -TargetRoot $target -Repository $ordinaryRepository -KeyDirectory $keys
    $ordinarySentinel = Join-Path $ordinaryRepository 'manifests\0.3.5.json'
    $ordinarySignature = Join-Path $ordinaryRepository 'manifests\0.3.5.sig'
    if (-not (Test-Path -LiteralPath $ordinarySentinel) -or -not (Test-Path -LiteralPath $ordinarySignature) -or
        -not $rsa.VerifyData([IO.File]::ReadAllBytes($ordinarySentinel), 'SHA256',
            [Convert]::FromBase64String([IO.File]::ReadAllText($ordinarySignature).Trim()))) {
        throw 'Default publishing must create a valid signed target-version sentinel.'
    }
    $disabledRejected = $false
    try {
        & $publisher -BaseRoot $base -TargetRoot $target -Repository (Join-Path $fixture 'without-sentinel') -KeyDirectory $keys -PublishNoUpdateSentinel:$false
    } catch { $disabledRejected = $true }
    if (-not $disabledRejected) { throw 'Publishing without a target-version sentinel must be rejected.' }
    Write-Host 'Passed: signed no-update sentinel, update baseline, collision protection and signed sentinel by default.'
} finally { $rsa.Dispose() }
