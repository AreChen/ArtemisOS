param(
    [string]$Repository = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\ota-1.0.1-swiftshader\repository'),
    [switch]$Online
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Management\Microsoft.PowerShell.Management.psd1') -ErrorAction Stop
$project = Split-Path -Parent $PSScriptRoot
$parent = Join-Path $project 'build\graphics-ota-release-tests'
[void][IO.Directory]::CreateDirectory($parent)
$parent = (Resolve-Path -LiteralPath $parent).ProviderPath.TrimEnd('\')
$fixture = Join-Path $parent ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$json = Join-Path $Repository 'manifests\1.0.0.json'
$signature = Join-Path $Repository 'manifests\1.0.0.sig'
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

try {
    foreach ($name in @('1.0.0', '1.0.0-sd-fixed', 'modified-base')) {
        if ($Online -and $name -eq 'modified-base') { continue }
        $baselineName = if ($name -eq 'modified-base') { '1.0.0' } else { $name }
        $baseline = Join-Path $project ('releases\' + $baselineName)
        $root = Join-Path $fixture $name
        [void][IO.Directory]::CreateDirectory($root)
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'sdk\emulator'))
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'data\avd'))
        foreach ($file in @('settings.ps1', 'configure.ps1', 'version.ini', 'launch.ps1', 'start-auto.vbs')) {
            Copy-Item -LiteralPath (Join-Path $baseline $file) -Destination (Join-Path $root $file)
        }
        Copy-Item -LiteralPath (Join-Path $baseline 'update') -Destination (Join-Path $root 'update') -Recurse
        $preferences = Join-Path $root 'data\preferences.ini'
        $userdata = Join-Path $root 'data\avd\userdata.img'
        $original = "profile=high`r`ncleanup=0`r`nvideo_compat=1`r`ncarrier=unicom`r`ngraphics=host`r`nresolution=1080p`r`ncustom=keep`r`n"
        [IO.File]::WriteAllText($preferences, $original, [Text.Encoding]::ASCII)
        [IO.File]::WriteAllText($userdata, 'existing Android user data', [Text.Encoding]::ASCII)
        $launcherHash = (Get-FileHash -LiteralPath (Join-Path $root 'launch.ps1') -Algorithm SHA256).Hash
        if ($name -eq 'modified-base') { Add-Content -LiteralPath (Join-Path $root 'configure.ps1') -Value '# unrecognized local modification' }
        . (Join-Path $root 'update\core.ps1')
        $manifest = Verify-UpdateManifest $root ([IO.File]::ReadAllBytes($json)) ([IO.File]::ReadAllBytes($signature))
        $paths = @($manifest.files | ForEach-Object { $_.path } | Sort-Object)
        Assert (($paths -join '|') -ceq 'configure.ps1|settings.ps1|version.ini') 'Unexpected release payload'
        if ($Online) {
            $offer = Get-UpdateOffer $root
            Assert ($null -ne $offer -and $offer.Manifest.from -ceq '1.0.0' -and $offer.Manifest.to -ceq '1.0.1') "${name}: live server did not offer 1.0.1"
            Assert ([Convert]::ToBase64String($offer.Bytes) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($json))) "${name}: live manifest differs from the tested release"
            $staging = Stage-UpdateOffer $root $offer
        } else {
            $staging = Join-Path $root ('data\update\staged-' + [Guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($staging)
            Copy-Item -LiteralPath $json -Destination (Join-Path $staging 'manifest.json')
            Copy-Item -LiteralPath $signature -Destination (Join-Path $staging 'manifest.sig')
            foreach ($item in $manifest.files) {
                Copy-Item -LiteralPath (Join-Path $Repository ('objects\' + $item.sha256)) -Destination (Join-Path $staging $item.sha256)
            }
        }
        & rtk proxy powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'update\apply.ps1') -Staging $staging -Serial 'emulator-5584' -NoRestart
        $status = $LASTEXITCODE
        if ($name -eq 'modified-base') {
            Assert ($status -ne 0) 'A modified base was incorrectly accepted'
            Assert ((Get-UpdateVersion $root) -ceq '1.0.0') 'Rejected update changed the version'
            Assert ([IO.File]::ReadAllText($preferences) -ceq $original) 'Rejected update changed preferences'
            Assert ([IO.File]::ReadAllText($userdata) -ceq 'existing Android user data') 'Rejected update changed Android data'
            Write-Host 'PASS: modified installation is rejected without changing user data.'
            continue
        }
        Assert ($status -eq 0) "${name}: update application failed"
        Assert ((Get-UpdateVersion $root) -ceq '1.0.1') "${name}: version was not updated"
        if ($Online) { Assert ($null -eq (Get-UpdateOffer $root)) "${name}: target no-update sentinel was not accepted" }
        Assert ([IO.File]::ReadAllText($preferences) -ceq $original) "${name}: preferences changed before first launch"
        Assert ([IO.File]::ReadAllText($userdata) -ceq 'existing Android user data') "${name}: Android data changed"
        Assert ((Get-FileHash -LiteralPath (Join-Path $root 'launch.ps1') -Algorithm SHA256).Hash -ceq $launcherHash) "${name}: launch script was unexpectedly replaced"
        . (Join-Path $root 'settings.ps1')
        $saved = Get-ArtemisPreferences
        Assert ($saved.Graphics -ceq 'swiftshader' -and (Get-ArtemisGraphics $saved.Graphics 'auto') -ceq 'swiftshader') "${name}: normal shortcut did not select SwiftShader"
        Assert ($saved.Profile -ceq 'high' -and $saved.Carrier -ceq 'unicom' -and $saved.Resolution -ceq '1080p') "${name}: another preference changed"
        Assert ([IO.File]::ReadAllText((Join-Path $root 'data\preferences.before-swiftshader-1.0.1.ini')) -ceq $original) "${name}: backup differs"
        & (Join-Path $root 'configure.ps1') -NoGui -SetGraphics host
        . (Join-Path $root 'settings.ps1')
        $saved = Get-ArtemisPreferences
        Assert ($saved.Graphics -ceq 'host' -and (Get-ArtemisGraphics $saved.Graphics 'auto') -ceq 'host') "${name}: manual hardware selection did not persist"
        Assert ([IO.File]::ReadAllText($userdata) -ceq 'existing Android user data') "${name}: Android data changed after migration"
        Write-Host "PASS: $name signed patch and preference migration preserve Android data and permit hardware selection."
    }
} finally {
    if (Test-Path -LiteralPath $fixture) {
        $resolved = (Resolve-Path -LiteralPath $fixture).ProviderPath.TrimEnd('\')
        if ($resolved -ine $fixture -or -not $resolved.StartsWith(($parent + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test directory.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
