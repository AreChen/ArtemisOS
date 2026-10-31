$script:ArtemisDataRoot = Join-Path $PSScriptRoot 'data'
$script:ArtemisPreferencesPath = Join-Path $script:ArtemisDataRoot 'preferences.ini'
$script:ArtemisStatePath = Join-Path $script:ArtemisDataRoot 'setup-state.ini'
$script:ArtemisManagedAppsPath = Join-Path $script:ArtemisDataRoot 'managed-google-apps.txt'

function Get-ArtemisVersion {
    $path = Join-Path $PSScriptRoot 'version.ini'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($path)) {
            if ($line -match '^Version=(\d+\.\d+\.\d+)$') { return $matches[1] }
        }
    }
    return 'unknown'
}

function Read-ArtemisKeyValues([string]$Path) {
    $values = @{}
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($Path)) {
            if ($line -match '^([a-z_]+)=(.*)$') { $values[$matches[1]] = $matches[2] }
        }
    }
    return $values
}

function Get-ArtemisPreferences {
    $values = Read-ArtemisKeyValues $script:ArtemisPreferencesPath
    $profile = if ($values['profile'] -in @('low', 'medium', 'high')) { $values['profile'] } else { 'low' }
    $cleanup = if ($values['cleanup'] -in @('0', '1')) { $values['cleanup'] } else { '1' }
    return [pscustomobject]@{ Profile = $profile; Cleanup = $cleanup }
}

function Write-ArtemisPreferences([string]$Profile, [string]$Cleanup) {
    if ($Profile -notin @('low', 'medium', 'high') -or $Cleanup -notin @('0', '1')) {
        throw '无效的模拟器配置。'
    }
    [void][IO.Directory]::CreateDirectory($script:ArtemisDataRoot)
    [IO.File]::WriteAllText($script:ArtemisPreferencesPath, "profile=$Profile`ncleanup=$Cleanup`n", [Text.Encoding]::ASCII)
}

function Get-ArtemisResources([string]$Profile) {
    switch ($Profile) {
        'low'    { return [pscustomobject]@{ Cpu = 2; MemoryMB = 2560 } }
        'medium' { return [pscustomobject]@{ Cpu = 4; MemoryMB = 4096 } }
        'high'   { return [pscustomobject]@{ Cpu = 6; MemoryMB = 8192 } }
        default  { throw '无效的模拟器配置。' }
    }
}

function Set-ArtemisState([string]$Key, [string]$Value) {
    $values = Read-ArtemisKeyValues $script:ArtemisStatePath
    $values[$Key] = $Value
    [void][IO.Directory]::CreateDirectory($script:ArtemisDataRoot)
    $lines = foreach ($name in ($values.Keys | Sort-Object)) { "$name=$($values[$name])" }
    [IO.File]::WriteAllLines($script:ArtemisStatePath, [string[]]$lines, [Text.Encoding]::ASCII)
}
