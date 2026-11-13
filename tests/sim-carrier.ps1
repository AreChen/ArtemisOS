$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$workspace = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath.TrimEnd('\')
$testRoot = Join-Path $workspace 'build\sim-carrier-tests'
[void][IO.Directory]::CreateDirectory($testRoot)
$testRoot = (Resolve-Path -LiteralPath $testRoot).ProviderPath.TrimEnd('\')
$temporary = Join-Path $testRoot ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporary)
try {
    Copy-Item -LiteralPath (Join-Path $workspace 'stage\settings.ps1') -Destination $temporary
    Copy-Item -LiteralPath (Join-Path $workspace 'stage\configure.ps1') -Destination $temporary
    . (Join-Path $temporary 'settings.ps1')

    $defaults = Get-ArtemisPreferences
    if ($defaults.Carrier -ne 'mobile') { throw 'A fresh installation did not default to China Mobile.' }
    [void][IO.Directory]::CreateDirectory((Join-Path $temporary 'data'))
    [IO.File]::WriteAllText((Join-Path $temporary 'data\preferences.ini'), "profile=medium`ncleanup=0`nvideo_compat=0`n", [Text.Encoding]::ASCII)
    if ((Get-ArtemisPreferences).Carrier -ne 'mobile') { throw 'Existing preferences did not get the new default.' }
    & (Join-Path $temporary 'configure.ps1') -NoGui -SetCarrier telecom
    & (Join-Path $temporary 'configure.ps1') -NoGui -SetProfile high
    $saved = Get-ArtemisPreferences
    if ($saved.Carrier -ne 'telecom' -or $saved.Profile -ne 'high' -or $saved.Cleanup -ne '0' -or $saved.VideoCompat -ne '0') {
        throw 'Changing carrier or profile lost an existing preference.'
    }
    $before = [IO.File]::ReadAllBytes($script:ArtemisPreferencesPath)
    $rejected = $false
    try { Write-ArtemisPreferences 'high' '0' '0' 'unknown' } catch { $rejected = $true }
    if (-not $rejected -or [Convert]::ToBase64String($before) -ne [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:ArtemisPreferencesPath))) {
        throw 'Invalid carrier was accepted or modified existing settings.'
    }

    $modem = Join-Path $temporary 'sdk\system-images\android-35\google_apis\x86_64\data\misc\modem_simulator'
    $operatorDir = Join-Path $modem 'etc\modem_simulator\files'
    [void][IO.Directory]::CreateDirectory($operatorDir)
    $templatePath = Join-Path $modem 'iccprofile_for_sim0.xml'
    $template = '<IccProfile><MF><EF name="EF_IMSI"><CIMI>310260123456789</CIMI></EF><EF name="EF_AD"><SIMIO cmd="B0">144,0,00000003</SIMIO></EF></MF></IccProfile>'
    [IO.File]::WriteAllText($templatePath, $template, [Text.Encoding]::UTF8)
    Copy-Item -LiteralPath (Join-Path $workspace 'stage\carrier-operators.xml') -Destination (Join-Path $operatorDir 'numeric_operator.xml')
    $expected = @{ mobile='46000'; telecom='46003'; unicom='46001' }
    foreach ($carrier in $expected.Keys) {
        $path = New-ArtemisSimProfile $carrier
        [xml]$profile = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
        $identity = $profile.SelectSingleNode("//EF[@name='EF_IMSI']/CIMI").InnerText
        if ($identity -ne ($expected[$carrier] + '0123456789') -or
            $profile.SelectSingleNode("//EF[@name='EF_AD']/SIMIO[@cmd='B0']").InnerText -ne '144,0,00000002') {
            throw "Incorrect simulated SIM profile: $carrier"
        }
    }
    if ([IO.File]::ReadAllText($templatePath) -ne $template) { throw 'The SDK SIM template was modified.' }
    [IO.File]::WriteAllText((Join-Path $operatorDir 'numeric_operator.xml'), '<resources><string-array/></resources>')
    $rejected = $false
    try { [void](New-ArtemisSimProfile 'mobile') } catch { $rejected = $true }
    if (-not $rejected) { throw 'An incomplete operator table was accepted.' }
    Write-Host 'Simulated carrier configuration tests passed.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $temporary).ProviderPath.TrimEnd('\')
    if (-not [string]::Equals($resolved, $temporary, [StringComparison]::OrdinalIgnoreCase) -or
        -not $resolved.StartsWith(($testRoot + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe temporary directory' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
