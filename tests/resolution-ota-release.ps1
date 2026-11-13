param(
    [string]$Release = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\ota-1.0.3-resolution-v2')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Management\Microsoft.PowerShell.Management.psd1') -ErrorAction Stop
$project = Split-Path -Parent $PSScriptRoot
$parent = Join-Path $project 'build\resolution-ota-tests'
[void][IO.Directory]::CreateDirectory($parent)
$parent = (Resolve-Path -LiteralPath $parent).ProviderPath.TrimEnd('\')
$fixture = Join-Path $parent ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
try {
    $repo = Join-Path $Release 'repository'
    $manifestPath = Join-Path $repo 'manifests\1.0.2.json'
    $signaturePath = Join-Path $repo 'manifests\1.0.2.sig'
    $manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($oldRelease in @('1.0.0', '1.0.0-sd-fixed')) {
        $root = Join-Path $fixture $oldRelease
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'update'))
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'data\avd\ArtemisOS_15.avd'))
        foreach ($file in @('settings.ps1', 'configure.ps1', 'version.ini')) {
            Copy-Item -LiteralPath (Join-Path $Release ('base\' + $file)) -Destination (Join-Path $root $file)
        }
        $launch = Join-Path $root 'launch.ps1'
        Copy-Item -LiteralPath (Join-Path $project ('releases\' + $oldRelease + '\launch.ps1')) -Destination $launch
        foreach ($file in @('apply.ps1', 'core.ps1', 'recovery.ps1', 'trusted-key.xml')) {
            Copy-Item -LiteralPath (Join-Path $project ('stage\update\' + $file)) -Destination (Join-Path $root ('update\' + $file))
        }
        $preferences = Join-Path $root 'data\preferences.ini'
        $userdata = Join-Path $root 'data\avd\ArtemisOS_15.avd\userdata-test.img'
        [IO.File]::WriteAllText($preferences, "profile=medium`nresolution=900p`ngraphics=host`n", [Text.Encoding]::ASCII)
        [IO.File]::WriteAllText($userdata, 'Existing test data.', [Text.Encoding]::ASCII)
        $launchHash = (Get-FileHash -LiteralPath $launch -Algorithm SHA256).Hash
        $preferencesHash = (Get-FileHash -LiteralPath $preferences -Algorithm SHA256).Hash
        $userdataHash = (Get-FileHash -LiteralPath $userdata -Algorithm SHA256).Hash
        $staging = Join-Path $root ('data\update\staged-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($staging)
        Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $staging 'manifest.json')
        Copy-Item -LiteralPath $signaturePath -Destination (Join-Path $staging 'manifest.sig')
        foreach ($item in $manifest.files) {
            Copy-Item -LiteralPath (Join-Path $repo ('objects\' + $item.sha256)) -Destination (Join-Path $staging $item.sha256)
        }
        & rtk proxy powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'update\apply.ps1') -Staging $staging -Serial 'emulator-5584' -NoRestart
        if ($LASTEXITCODE -ne 0) { throw "Update failed for $oldRelease." }
        if ((Get-Content -Raw -LiteralPath (Join-Path $root 'version.ini')) -notmatch '(?m)^Version=1\.0\.3\s*$' -or
            (Get-FileHash -LiteralPath $launch -Algorithm SHA256).Hash -ne $launchHash -or
            (Get-FileHash -LiteralPath $preferences -Algorithm SHA256).Hash -ne $preferencesHash -or
            (Get-FileHash -LiteralPath $userdata -Algorithm SHA256).Hash -ne $userdataHash) {
            throw "Update did not preserve the launcher, preferences, and Android data for $oldRelease."
        }
        foreach ($item in $manifest.files) {
            if ((Get-FileHash -LiteralPath (Join-Path $root $item.path) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $item.sha256) {
                throw "Incorrect updated file $($item.path) for $oldRelease."
            }
        }
        Write-Host "PASS: $oldRelease lineage upgrades to 1.0.3 and preserves its launcher and data."
    }
} finally {
    $resolved = (Resolve-Path -LiteralPath $fixture).ProviderPath.TrimEnd('\')
    if (-not [string]::Equals($resolved, $fixture, [StringComparison]::OrdinalIgnoreCase) -or
        -not $resolved.StartsWith(($parent + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe temporary directory.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
