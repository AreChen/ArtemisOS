$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$workspace = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath.TrimEnd('\')
$testRoot = Join-Path $workspace 'build\video-compat-tests'
[void][IO.Directory]::CreateDirectory($testRoot)
$testRoot = (Resolve-Path -LiteralPath $testRoot).ProviderPath.TrimEnd('\')
$temporary = Join-Path $testRoot ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporary)
try {
    Copy-Item -LiteralPath (Join-Path $workspace 'stage\settings.ps1') -Destination $temporary
    Copy-Item -LiteralPath (Join-Path $workspace 'stage\configure.ps1') -Destination $temporary
    . (Join-Path $temporary 'settings.ps1')

    $defaults = Get-ArtemisPreferences
    if ($defaults.Profile -ne 'low' -or $defaults.Cleanup -ne '1' -or $defaults.VideoCompat -ne '1') { throw 'Invalid fresh installation defaults' }

    [void][IO.Directory]::CreateDirectory((Join-Path $temporary 'data'))
    [IO.File]::WriteAllText((Join-Path $temporary 'data\preferences.ini'), "profile=medium`ncleanup=0`n", [Text.Encoding]::ASCII)
    $old = Get-ArtemisPreferences
    if ($old.Profile -ne 'medium' -or $old.Cleanup -ne '0' -or $old.VideoCompat -ne '1') { throw 'Existing settings are not preserved' }

    & (Join-Path $temporary 'configure.ps1') -NoGui -SetVideoCompat '0'
    $disabled = Get-ArtemisPreferences
    if ($disabled.Profile -ne 'medium' -or $disabled.Cleanup -ne '0' -or $disabled.VideoCompat -ne '0') { throw 'Disabling video compatibility did not persist' }

    & (Join-Path $temporary 'configure.ps1') -NoGui -SetProfile 'high'
    $changedProfile = Get-ArtemisPreferences
    if ($changedProfile.Profile -ne 'high' -or $changedProfile.Cleanup -ne '0' -or $changedProfile.VideoCompat -ne '0') { throw 'Changing the profile reset video compatibility' }

    & (Join-Path $temporary 'configure.ps1') -NoGui -SetVideoCompat '1'
    $enabled = Get-ArtemisPreferences
    if ($enabled.Profile -ne 'high' -or $enabled.Cleanup -ne '0' -or $enabled.VideoCompat -ne '1') { throw 'Enabling video compatibility did not persist' }

    $before = [IO.File]::ReadAllBytes((Join-Path $temporary 'data\preferences.ini'))
    $rejected = $false
    try { Write-ArtemisPreferences 'high' '0' 'invalid' } catch { $rejected = $true }
    if (-not $rejected) { throw 'Invalid video compatibility value was accepted' }
    $after = [IO.File]::ReadAllBytes((Join-Path $temporary 'data\preferences.ini'))
    if ([Convert]::ToBase64String($before) -ne [Convert]::ToBase64String($after)) { throw 'Invalid setting changed the preferences' }
    Write-Host 'Video compatibility configuration tests passed.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $temporary).ProviderPath.TrimEnd('\')
    if (-not [string]::Equals($resolved, $temporary, [StringComparison]::OrdinalIgnoreCase) -or
        -not $resolved.StartsWith(($testRoot + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe temporary directory' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
