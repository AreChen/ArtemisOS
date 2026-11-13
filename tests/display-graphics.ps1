$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$workspace = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath.TrimEnd('\')
$testRoot = Join-Path $workspace 'build\display-graphics-tests'
[void][IO.Directory]::CreateDirectory($testRoot)
$testRoot = (Resolve-Path -LiteralPath $testRoot).ProviderPath.TrimEnd('\')
$temporary = Join-Path $testRoot ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporary)
try {
    Copy-Item -LiteralPath (Join-Path $workspace 'stage\settings.ps1') -Destination $temporary
    Copy-Item -LiteralPath (Join-Path $workspace 'stage\configure.ps1') -Destination $temporary
    . (Join-Path $temporary 'settings.ps1')

    $defaults = Get-ArtemisPreferences
    if ($defaults.Graphics -ne 'host' -or $defaults.Resolution -ne '720p') { throw 'Incorrect fresh-install defaults.' }
    [void][IO.Directory]::CreateDirectory((Join-Path $temporary 'data'))
    if ((Get-ArtemisPreferences).Graphics -ne 'host') { throw 'An absent preferences file did not use hardware rendering.' }
    Write-ArtemisPreferences 'low' '1' '1'
    if ((Get-ArtemisPreferences).Graphics -ne 'host') { throw 'The preference writer did not use hardware rendering.' }
    [IO.File]::WriteAllText($script:ArtemisPreferencesPath, "profile=medium`ncleanup=0`nvideo_compat=0`ncarrier=unicom`n", [Text.Encoding]::ASCII)
    $legacy = Get-ArtemisPreferences
    if ($legacy.Graphics -ne 'host' -or $legacy.Resolution -ne '720p' -or $legacy.Carrier -ne 'unicom') { throw 'Legacy preferences were not upgraded safely.' }

    foreach ($legacyRenderer in @('auto', 'host')) {
        [IO.File]::WriteAllText($script:ArtemisPreferencesPath, "profile=medium`ncleanup=0`nvideo_compat=0`ncarrier=unicom`ngraphics=$legacyRenderer`n", [Text.Encoding]::ASCII)
        & (Join-Path $temporary 'configure.ps1') -NoGui -SetProfile high
        if ((Get-ArtemisPreferences).Graphics -ne $legacyRenderer) { throw "An explicit existing preference changed: $legacyRenderer" }
    }

    foreach ($renderer in @('auto', 'host', 'software', 'swiftshader', 'swangle', 'lavapipe')) {
        & (Join-Path $temporary 'configure.ps1') -NoGui -SetGraphics $renderer
        if ((Get-ArtemisPreferences).Graphics -ne $renderer) { throw "Renderer did not persist: $renderer" }
        $expected = if ($renderer -in @('software', 'swiftshader', 'swangle')) { 'swangle' } else { $renderer }
        if ((Get-ArtemisGraphics $renderer 'auto') -ne $expected -or (Get-ArtemisGraphics $renderer 'swiftshader') -ne 'swangle') {
            throw "Unexpected normal or software shortcut behavior: $renderer"
        }
    }
    foreach ($resolution in @('720p', '900p', '1080p')) {
        & (Join-Path $temporary 'configure.ps1') -NoGui -SetResolution $resolution
        if ((Get-ArtemisPreferences).Resolution -ne $resolution) { throw "Resolution did not persist: $resolution" }
        $display = Get-ArtemisDisplay $resolution
        if (($display.Width * 160 / $display.Density) -ne 360 -or ($display.Height * 160 / $display.Density) -ne 800) {
            throw "Logical display size changed: $resolution"
        }
    }
    & (Join-Path $temporary 'configure.ps1') -NoGui -SetProfile high -SetCarrier telecom
    $saved = Get-ArtemisPreferences
    if ($saved.Profile -ne 'high' -or $saved.Carrier -ne 'telecom' -or $saved.Cleanup -ne '0' -or
        $saved.VideoCompat -ne '0' -or $saved.Graphics -ne 'lavapipe' -or $saved.Resolution -ne '1080p') {
        throw 'Changing settings lost an unrelated preference.'
    }

    $presets = @(
        @{ Key = '720x1280'; Width = 720; Height = 1280; Density = 320 },
        @{ Key = '1080x1920'; Width = 1080; Height = 1920; Density = 480 },
        @{ Key = '1280x720'; Width = 1280; Height = 720; Density = 320 },
        @{ Key = '1920x1080'; Width = 1920; Height = 1080; Density = 480 }
    )
    foreach ($preset in $presets) {
        & (Join-Path $temporary 'configure.ps1') -NoGui -SetResolution $preset.Key
        $saved = Get-ArtemisPreferences
        $display = Get-ArtemisDisplay $saved.Resolution
        if ($saved.Resolution -ne $preset.Key -or $display.Width -ne $preset.Width -or
            $display.Height -ne $preset.Height -or $display.Density -ne $preset.Density) {
            throw "Incorrect display preset: $($preset.Key)"
        }
        if ($saved.Profile -ne 'high' -or $saved.Carrier -ne 'telecom' -or $saved.Cleanup -ne '0' -or
            $saved.VideoCompat -ne '0' -or $saved.Graphics -ne 'lavapipe') {
            throw "Changing resolution lost an unrelated preference: $($preset.Key)"
        }
    }

    $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:ArtemisPreferencesPath))
    foreach ($invalid in @(@('bad', '720p'), @('auto', 'bad'))) {
        $rejected = $false
        try { Write-ArtemisPreferences 'high' '0' '0' 'telecom' $invalid[0] $invalid[1] } catch { $rejected = $true }
        if (-not $rejected -or $before -ne [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:ArtemisPreferencesPath))) {
            throw 'An invalid setting was accepted or changed existing preferences.'
        }
    }
    Write-Host 'Display and graphics preference tests passed.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $temporary).ProviderPath.TrimEnd('\')
    if (-not [string]::Equals($resolved, $temporary, [StringComparison]::OrdinalIgnoreCase) -or
        -not $resolved.StartsWith(($testRoot + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe temporary directory.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
