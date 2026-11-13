$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security
$project = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath.TrimEnd('\')
$testRoot = Join-Path $project 'build\carrier-update-tests'
[void][IO.Directory]::CreateDirectory($testRoot)
$testRoot = (Resolve-Path -LiteralPath $testRoot).ProviderPath.TrimEnd('\')
$temporary = Join-Path $testRoot ([Guid]::NewGuid().ToString('N'))
$base = Join-Path $temporary 'base'
$target = Join-Path $temporary 'target'
$keys = Join-Path $temporary 'keys'
$repository = Join-Path $temporary 'repository'
$carrierPath = 'sdk/system-images/android-35/google_apis/x86_64/data/misc/modem_simulator/etc/modem_simulator/files/numeric_operator.xml'
try {
    foreach ($path in @($base, $target, $keys, (Join-Path $base 'update'), (Join-Path $target 'update'), (Join-Path $base (Split-Path $carrierPath -Parent)))) {
        [void][IO.Directory]::CreateDirectory($path)
    }
    [IO.File]::WriteAllText((Join-Path $base 'version.ini'), "[ArtemisOS]`nVersion=0.3.3`n", [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $target 'version.ini'), "[ArtemisOS]`nVersion=0.3.4`n", [Text.Encoding]::ASCII)
    $oldMap = Join-Path $base $carrierPath
    [IO.File]::WriteAllText($oldMap, '<resources><string-array/></resources>', [Text.Encoding]::UTF8)
    Copy-Item -LiteralPath (Join-Path $project 'stage\carrier-operators.xml') -Destination (Join-Path $target 'carrier-operators.xml')
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(2048)
    $rsa.PersistKeyInCsp = $false
    try {
        $public = $rsa.ToXmlString($false)
        $private = [Text.Encoding]::UTF8.GetBytes($rsa.ToXmlString($true))
        $protected = [Security.Cryptography.ProtectedData]::Protect($private, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        [IO.File]::WriteAllBytes((Join-Path $keys 'ota-private.dpapi'), $protected)
        [IO.File]::WriteAllText((Join-Path $target 'update\trusted-key.xml'), $public)
        [IO.File]::WriteAllText((Join-Path $base 'update\trusted-key.xml'), $public)
    } finally { $rsa.Dispose() }

    & (Join-Path $project 'tools\Publish-Update.ps1') -BaseRoot $base -TargetRoot $target -Repository $repository -KeyDirectory $keys
    $manifestPath = Join-Path $repository 'manifests\0.3.3.json'
    $sigPath = Join-Path $repository 'manifests\0.3.3.sig'
    . (Join-Path $project 'stage\update\core.ps1')
    $manifest = Verify-UpdateManifest $base ([IO.File]::ReadAllBytes($manifestPath)) ([IO.File]::ReadAllBytes($sigPath))
    $entry = @($manifest.files | Where-Object { $_.path -eq $carrierPath })
    if ($entry.Count -ne 1) { throw 'The carrier map is missing from the normal update.' }
    if ($entry[0].base_sha256 -ne (Get-FileHash -LiteralPath $oldMap -Algorithm SHA256).Hash.ToLowerInvariant() -or
        $entry[0].sha256 -ne (Get-FileHash -LiteralPath (Join-Path $target 'carrier-operators.xml') -Algorithm SHA256).Hash.ToLowerInvariant()) {
        throw 'The carrier map update hashes do not match their sources.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $repository ('objects\' + $entry[0].sha256)) -PathType Leaf)) {
        throw 'The carrier map update object was not created.'
    }
    Write-Host 'Carrier map update integration tests passed.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $temporary).ProviderPath.TrimEnd('\')
    if (-not [string]::Equals($resolved, $temporary, [StringComparison]::OrdinalIgnoreCase) -or
        -not $resolved.StartsWith(($testRoot + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe temporary directory' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
