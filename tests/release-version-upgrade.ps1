param(
    [Parameter(Mandatory=$true)][string]$Repository,
    [Parameter(Mandatory=$true)][string]$BaseRoot
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$project = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $project 'build\release-upgrade-tests'
[void][IO.Directory]::CreateDirectory($testRoot)
$testRoot = (Resolve-Path -LiteralPath $testRoot).ProviderPath.TrimEnd('\')
$fixture = Join-Path $testRoot ([Guid]::NewGuid().ToString('N'))
$stage = Join-Path $fixture ('data\update\staged-' + [Guid]::NewGuid().ToString('N'))
try {
    [void][IO.Directory]::CreateDirectory($stage)
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'data\avd\fixture.avd'))
    Copy-Item -LiteralPath (Join-Path $BaseRoot 'update') -Destination (Join-Path $fixture 'update') -Recurse
    Copy-Item -LiteralPath (Join-Path $BaseRoot 'version.ini') -Destination (Join-Path $fixture 'version.ini')
    $prefs = Join-Path $fixture 'data\preferences.ini'
    $disk = Join-Path $fixture 'data\avd\fixture.avd\userdata-qemu.img'
    [IO.File]::WriteAllText($prefs, "profile=high`ngraphics=auto`ncustom=value`n", [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText($disk, 'simulated-user-data', [Text.Encoding]::ASCII)
    $beforePrefs = (Get-FileHash -LiteralPath $prefs -Algorithm SHA256).Hash
    $beforeDisk = (Get-FileHash -LiteralPath $disk -Algorithm SHA256).Hash
    . (Join-Path $fixture 'update\core.ps1')
    $manifestPath = Join-Path $Repository 'manifests\0.3.6.json'
    $signaturePath = Join-Path $Repository 'manifests\0.3.6.sig'
    $manifest = Verify-UpdateManifest $fixture ([IO.File]::ReadAllBytes($manifestPath)) ([IO.File]::ReadAllBytes($signaturePath))
    if ($manifest.from -ne '0.3.6' -or $manifest.to -ne '1.0.0' -or @($manifest.files).Count -ne 1 -or $manifest.files[0].path -ne 'version.ini') {
        throw 'The 0.3.6 release bridge differs from the expected version-only patch.'
    }
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $stage 'manifest.json')
    Copy-Item -LiteralPath $signaturePath -Destination (Join-Path $stage 'manifest.sig')
    foreach ($entry in @($manifest.files)) {
        Copy-Item -LiteralPath (Join-Path $Repository ('objects\' + $entry.sha256)) -Destination (Join-Path $stage $entry.sha256)
    }
    & (Join-Path $fixture 'update\apply.ps1') -Staging $stage -Serial 'emulator-5554' -NoRestart
    if ((Get-UpdateVersion $fixture) -ne '1.0.0') { throw 'The installed version was not updated.' }
    if ((Get-FileHash -LiteralPath $prefs -Algorithm SHA256).Hash -ne $beforePrefs -or
        (Get-FileHash -LiteralPath $disk -Algorithm SHA256).Hash -ne $beforeDisk) {
        throw 'User data or preferences changed during the version upgrade.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $fixture 'data\update\pending\completed.flag'))) { throw 'The completed transaction was not recorded.' }
    $sentinel = Verify-UpdateManifest $fixture ([IO.File]::ReadAllBytes((Join-Path $Repository 'manifests\1.0.0.json'))) ([IO.File]::ReadAllBytes((Join-Path $Repository 'manifests\1.0.0.sig'))) -AllowNoUpdate
    if ($sentinel.to -ne '1.0.0' -or @($sentinel.files).Count -ne 0) { throw 'The destination no-update marker is invalid.' }
    Write-Host 'PASS: signed 0.3.6 to 1.0.0 update preserves test user data and preferences.'
} finally {
    if (Test-Path -LiteralPath $fixture) {
        $resolved = (Resolve-Path -LiteralPath $fixture).ProviderPath.TrimEnd('\')
        if (-not [string]::Equals($resolved, $fixture, [StringComparison]::OrdinalIgnoreCase) -or
            -not $resolved.StartsWith(($testRoot + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test directory.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
