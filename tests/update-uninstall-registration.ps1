$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$project = Split-Path -Parent $PSScriptRoot
$applyPath = Join-Path $project 'stage\update\apply.ps1'
$source = [IO.File]::ReadAllText($applyPath)
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Updater script does not parse.' }
$definition = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Sync-WindowsAppRegistration'
}, $true)
if (-not $definition) { throw 'Registration synchronization function is missing.' }
. ([scriptblock]::Create($definition.Extent.Text))
$script:syncLogs = New-Object 'System.Collections.Generic.List[string]'
function Write-UpdateLog([string]$Message) { [void]$script:syncLogs.Add($Message) }
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

# No real uninstall registration is used; the function receives a unique,
# private HKCU fixture root and is otherwise the exact function from apply.ps1.
$suffix = [Guid]::NewGuid().ToString('N')
$fixtureSubkey = 'Software\ArtemisOS-Ota-Registration-Test-' + $suffix
$fixtureRoot = 'HKCU:\' + $fixtureSubkey
$hive = [Microsoft.Win32.Registry]::CurrentUser
$existing = $hive.OpenSubKey($fixtureSubkey)
if ($existing) { $existing.Dispose(); throw 'Refusing to reuse a registry fixture.' }
$created = $false
$legacyName = '{E49344F1-069E-4DA4-A5B7-232C0BE325A8}_is1'
$releaseName = 'ArtemisOS15-Release_is1'
$unrelatedName = 'UnrelatedSoftware_is1'
$root = Join-Path $env:TEMP ('ArtemisRegistrationInstall-' + $suffix)
$other = $root + '-other'
function Set-FixtureRegistration([string]$Name, [string]$Location, [string]$Version, [string]$DisplayName) {
    $key = $hive.CreateSubKey($fixtureSubkey + '\' + $Name)
    try {
        if ($null -eq $Location) { $key.DeleteValue('InstallLocation', $false) }
        else { $key.SetValue('InstallLocation', $Location, [Microsoft.Win32.RegistryValueKind]::String) }
        $key.SetValue('DisplayVersion', $Version, [Microsoft.Win32.RegistryValueKind]::String)
        $key.SetValue('DisplayName', $DisplayName, [Microsoft.Win32.RegistryValueKind]::String)
    } finally { $key.Dispose() }
}
function Read-FixtureRegistration([string]$Name) { return Get-ItemProperty -LiteralPath (Join-Path $fixtureRoot $Name) }

try {
    $key = $hive.CreateSubKey($fixtureSubkey)
    $key.Dispose(); $created = $true
    Set-FixtureRegistration $legacyName ($root.ToUpperInvariant() + '\') '0.3.5' 'Legacy name'
    Set-FixtureRegistration $releaseName $other '0.3.6' 'Release name'
    Set-FixtureRegistration $unrelatedName $root '1.0.0' 'Unrelated name'
    Sync-WindowsAppRegistration $root '0.3.7' $fixtureRoot
    $legacy = Read-FixtureRegistration $legacyName
    $release = Read-FixtureRegistration $releaseName
    $unrelated = Read-FixtureRegistration $unrelatedName
    $expectedLegacyName = 'ArtemisOS 15 ' + [char]0x7248 + [char]0x672c + ' 0.3.7'
    Assert ($legacy.DisplayVersion -ceq '0.3.7' -and $legacy.DisplayName -ceq $expectedLegacyName) 'Legacy matching registration did not update.'
    Assert ($release.DisplayVersion -ceq '0.3.6' -and $release.DisplayName -ceq 'Release name') 'Other install registration changed.'
    Assert ($unrelated.DisplayVersion -ceq '1.0.0' -and $unrelated.DisplayName -ceq 'Unrelated name') 'Unrelated application registration changed.'
    Assert ($script:syncLogs.Count -eq 0) 'A valid path mismatch was logged as failure.'

    Set-FixtureRegistration $legacyName $other '0.3.5' 'Legacy name'
    Set-FixtureRegistration $releaseName ($root + '\') '0.3.6' 'ArtemisOS 15 Release'
    Sync-WindowsAppRegistration $root '0.3.7' $fixtureRoot
    $legacy = Read-FixtureRegistration $legacyName
    $release = Read-FixtureRegistration $releaseName
    Assert ($legacy.DisplayVersion -ceq '0.3.5' -and $legacy.DisplayName -ceq 'Legacy name') 'Legacy registration for another install changed.'
    Assert ($release.DisplayVersion -ceq '0.3.7' -and $release.DisplayName -ceq 'ArtemisOS 15 Release') 'Release registration did not update while preserving its identity.'

    Set-FixtureRegistration $legacyName $root '0.3.5' 'Legacy name'
    Set-FixtureRegistration $releaseName $root '0.3.6' 'Release name'
    Sync-WindowsAppRegistration $root '0.3.8' $fixtureRoot
    Assert ((Read-FixtureRegistration $legacyName).DisplayVersion -ceq '0.3.8') 'Matching legacy key was skipped.'
    Assert ((Read-FixtureRegistration $releaseName).DisplayVersion -ceq '0.3.8') 'Matching release key was skipped.'

    $script:syncLogs.Clear()
    Set-FixtureRegistration $legacyName $null '0.3.5' 'Legacy name'
    Set-FixtureRegistration $releaseName $root '0.3.6' 'Release name'
    Sync-WindowsAppRegistration $root '0.3.7' $fixtureRoot
    Assert ($script:syncLogs.Count -eq 1 -and $script:syncLogs[0].Contains($legacyName)) 'Missing install location was not logged.'
    Assert ((Read-FixtureRegistration $legacyName).DisplayVersion -ceq '0.3.5') 'Invalid legacy registration was modified.'
    Assert ((Read-FixtureRegistration $releaseName).DisplayVersion -ceq '0.3.7') 'A failure in one registration prevented the other from updating.'

    $script:syncLogs.Clear()
    Set-FixtureRegistration $legacyName 'C:relative' '0.3.5' 'Legacy name'
    Set-FixtureRegistration $releaseName $other '0.3.6' 'Release name'
    Sync-WindowsAppRegistration $root '0.3.7' $fixtureRoot
    Assert ($script:syncLogs.Count -eq 1 -and $script:syncLogs[0].Contains($legacyName)) 'Drive-relative path was not rejected and logged.'
    Assert ((Read-FixtureRegistration $legacyName).DisplayVersion -ceq '0.3.5') 'Drive-relative registration was modified.'
    Assert ((Read-FixtureRegistration $releaseName).DisplayVersion -ceq '0.3.6') 'An exact path mismatch was modified.'
    $script:syncLogs.Clear()
    Set-FixtureRegistration $legacyName '\root-relative' '0.3.5' 'Legacy name'
    Sync-WindowsAppRegistration $root '0.3.7' $fixtureRoot
    Assert ($script:syncLogs.Count -eq 1 -and $script:syncLogs[0].Contains($legacyName)) 'Root-relative path was not rejected and logged.'
    Assert ((Read-FixtureRegistration $legacyName).DisplayVersion -ceq '0.3.5') 'Root-relative registration was modified.'
    Write-Host 'Passed: legacy and release identity, exact install location, case/trailing separator, unrelated keys, failure logging and independent continuation.'
} finally {
    if ($created) {
        if ($fixtureSubkey -notmatch '^Software\\ArtemisOS-Ota-Registration-Test-[0-9a-f]{32}$') {
            throw 'Refusing to delete an unrecognized registry fixture.'
        }
        $hive.DeleteSubKeyTree($fixtureSubkey)
    }
}
