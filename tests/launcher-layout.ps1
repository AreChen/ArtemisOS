$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$project = Split-Path -Parent $PSScriptRoot
$helper = Join-Path $project 'stage\update\launcher-layout.ps1'
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Reject([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert $rejected $Message
}
Assert (Test-Path -LiteralPath $helper -PathType Leaf) 'Missing one-time launcher XML migration.'
. $helper

$original = @'
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<map>
    <!-- Keep desktop state and user preferences. -->
    <boolean name="pref_allowRotation" value="false" />
    <string name="workspace">icons &amp; folders</string>
    <int name="screen" value="7" />
    <set name="hidden"><string>one</string><string>two</string></set>
</map>
'@
$converted = ConvertTo-ArtemisLauncherRotationXml $original
Assert ($converted.Changed -and $converted.Xml -match 'pref_allowRotation" value="true"') 'False rotation preference was not enabled.'
$before = New-Object Xml.XmlDocument; $before.LoadXml($original)
$after = New-Object Xml.XmlDocument; $after.LoadXml($converted.Xml)
foreach ($name in @('workspace','screen','hidden')) {
    Assert ($before.SelectSingleNode("/map/*[@name='$name']").OuterXml -ceq $after.SelectSingleNode("/map/*[@name='$name']").OuterXml) ('An unrelated preference changed: ' + $name)
}
Assert ($converted.Xml.Contains('<!-- Keep desktop state and user preferences. -->')) 'The XML comment was discarded.'
$idempotent = ConvertTo-ArtemisLauncherRotationXml $converted.Xml
Assert (-not $idempotent.Changed -and $idempotent.Xml -ceq $converted.Xml) 'An enabled preference was rewritten.'
$added = ConvertTo-ArtemisLauncherRotationXml '<map><string name="keep">yes</string></map>'
Assert ($added.Changed) 'An absent preference was not added.'
$after.LoadXml($added.Xml)
Assert ($after.SelectNodes('/map/boolean[@name="pref_allowRotation" and @value="true"]').Count -eq 1 -and $after.SelectSingleNode('/map/string').InnerText -ceq 'yes') 'Adding the key damaged other preferences.'
foreach ($invalid in @('', '<map>', '<prefs />', '<map><string name="pref_allowRotation">false</string></map>',
    '<map><boolean name="pref_allowRotation" value="TRUE" /></map>',
    '<map><boolean name="pref_allowRotation" value="false"/><boolean name="pref_allowRotation" value="true"/></map>',
    '<!DOCTYPE map [<!ENTITY x "false">]><map><boolean name="pref_allowRotation" value="&x;"/></map>',
    '<!DOCTYPE map SYSTEM "file:///not-to-read"><map/>')) {
    Reject { ConvertTo-ArtemisLauncherRotationXml $invalid } 'Invalid, duplicate or DTD-containing preferences were accepted.'
}

$script:ArtemisStatePath = 'fixture-state-only'
$pref = '/data/user/0/com.google.android.apps.nexuslauncher/shared_prefs/com.android.launcher3.prefs.xml'
function Reset-Fixture {
    $script:fixture = @{Xml=$original;State=@{};Commands=(New-Object Collections.Generic.List[object]);Logs=(New-Object Collections.Generic.List[string]);Backups=(New-Object Collections.Generic.List[string]);Missing=0;Qemu='1';BuildType='userdebug';Root='0';Home='com.google.android.apps.nexuslauncher/.NexusLauncherActivity';FailCopy=$false;FailHome=$false;Pushed='';Local=''}
}
function Read-ArtemisKeyValues([string]$Path) { return $script:fixture.State }
function Set-ArtemisState([string]$Key, [string]$Value) { $script:fixture.State[$Key] = $Value }
function Write-InitializeLog([string]$Message) { $script:fixture.Logs.Add($Message) }
function Invoke-Device([string[]]$DeviceArguments) {
    $script:fixture.Commands.Add([string[]]$DeviceArguments)
    $command = $DeviceArguments -join ' '
    switch ($command) {
        'shell getprop ro.boot.qemu' { return $script:fixture.Qemu }
        'shell getprop ro.debuggable' { return '1' }
        'shell getprop ro.build.type' { return $script:fixture.BuildType }
        'shell am get-current-user' { return '0' }
        'shell cmd package resolve-activity --brief --user 0 -a android.intent.action.MAIN -c android.intent.category.HOME' { return $script:fixture.Home }
        'shell su 0 id -u' { return $script:fixture.Root }
        ('shell su 0 cat ' + $pref) {
            if ($script:fixture.Missing -gt 0) { $script:fixture.Missing--; throw 'Preferences not created yet.' }
            return $script:fixture.Xml
        }
        'shell am force-stop com.google.android.apps.nexuslauncher' { return '' }
        'shell am start -a android.intent.action.MAIN -c android.intent.category.HOME' {
            if ($script:fixture.FailHome) { throw 'HOME did not start.' }
            return 'Starting: Intent { act=android.intent.action.MAIN cat=[android.intent.category.HOME] }'
        }
        default {
            if ($DeviceArguments[0] -ceq 'push') {
                $script:fixture.Local = $DeviceArguments[1]
                $script:fixture.Pushed = [IO.File]::ReadAllText($DeviceArguments[1])
                Assert ($DeviceArguments[2] -cmatch '^/data/local/tmp/artemisos-launcher-rotation-[a-f0-9]{32}\.xml$') 'The remote temporary XML path was not fixed and unique.'
                return '1 file pushed'
            }
            if ($command.StartsWith('shell su 0 cp -p ' + $pref + ' ', [StringComparison]::Ordinal)) {
                Assert ($DeviceArguments[6] -cmatch ('^' + [regex]::Escape($pref) + '\.artemisos-rotation-[a-f0-9]{32}\.bak$')) 'The backup can overwrite an unrelated path.'
                $script:fixture.Backups.Add($script:fixture.Xml)
                return ''
            }
            if ($command.StartsWith('shell su 0 cp /data/local/tmp/', [StringComparison]::Ordinal)) {
                if ($script:fixture.FailCopy) { throw 'Copy failed.' }
                Assert ($script:fixture.Backups.Count -eq 1 -and $DeviceArguments[5] -ceq $pref) 'The original was not backed up before its in-place copy.'
                $script:fixture.Xml = $script:fixture.Pushed
                return ''
            }
            if ($command -cmatch '^shell su 0 rm -f /data/local/tmp/artemisos-launcher-rotation-[a-f0-9]{32}\.xml$') { return '' }
            throw ('Unexpected fixture command: ' + $command)
        }
    }
}
function Mutating-Commands { return @($script:fixture.Commands | Where-Object { $_[0] -ceq 'push' -or ($_ -join ' ') -match '^shell (?:su 0 cp|am force-stop|am start)' }) }

Reset-Fixture
Initialize-ArtemisLauncherRotation -Attempts 3 -RetryDelayMilliseconds 0
Assert ($script:fixture.State['launcher_rotation'] -ceq '1' -and $script:fixture.Backups.Count -eq 1 -and $script:fixture.Backups[0] -ceq $original) ('Successful migration did not preserve an original backup and mark completion. ' + ($script:fixture.Logs -join '; '))
Assert (-not (ConvertTo-ArtemisLauncherRotationXml $script:fixture.Xml).Changed -and -not (Test-Path -LiteralPath $script:fixture.Local)) 'Migration did not verify the new value or clean its owned temporary file.'
Assert (@($script:fixture.Commands | Where-Object { ($_ -join ' ') -ceq 'shell am force-stop com.google.android.apps.nexuslauncher' }).Count -eq 1) 'The changed launcher was not restarted exactly once.'
$commandCount = $script:fixture.Commands.Count
$script:fixture.Xml = $original
Initialize-ArtemisLauncherRotation -Attempts 3 -RetryDelayMilliseconds 0
Assert ($script:fixture.Commands.Count -eq $commandCount -and $script:fixture.Xml -ceq $original) 'A subsequent launch overwrote the user setting after the completed migration.'

Reset-Fixture
$script:fixture.Xml = $converted.Xml
Initialize-ArtemisLauncherRotation -Attempts 3 -RetryDelayMilliseconds 0
Assert ($script:fixture.State['launcher_rotation'] -ceq '1' -and @(Mutating-Commands).Count -eq 0) 'An already enabled launcher was restarted or rewritten.'

foreach ($mode in @('other-home','no-root','not-qemu','not-userdebug','missing','bad-xml','copy-failure','home-failure')) {
    Reset-Fixture
    switch ($mode) {
        'other-home' { $script:fixture.Home = 'org.example.launcher/.Home' }
        'no-root' { $script:fixture.Root = '2000' }
        'not-qemu' { $script:fixture.Qemu = '0' }
        'not-userdebug' { $script:fixture.BuildType = 'user' }
        'missing' { $script:fixture.Missing = 20 }
        'bad-xml' { $script:fixture.Xml = '<map><bad' }
        'copy-failure' { $script:fixture.FailCopy = $true }
        'home-failure' { $script:fixture.FailHome = $true }
    }
    Initialize-ArtemisLauncherRotation -Attempts 3 -RetryDelayMilliseconds 0
    Assert (-not $script:fixture.State.ContainsKey('launcher_rotation') -and $script:fixture.Logs.Count -gt 0) ('An unavailable/failed migration was marked complete or not logged: ' + $mode)
    if ($mode -notin @('copy-failure','home-failure')) { Assert (@(Mutating-Commands).Count -eq 0) ('An inapplicable migration modified device data: ' + $mode) }
    if ($script:fixture.Local) { Assert (-not (Test-Path -LiteralPath $script:fixture.Local)) 'A failed migration leaked its local temporary XML.' }
    if ($mode -ceq 'missing') { Assert (@($script:fixture.Commands | Where-Object { ($_ -join ' ') -ceq ('shell su 0 cat ' + $pref) }).Count -eq 3) 'Missing preferences were not retried a bounded number of times.' }
}
Reset-Fixture
$script:fixture.Missing = 1
Initialize-ArtemisLauncherRotation -Attempts 3 -RetryDelayMilliseconds 0
Assert ($script:fixture.State['launcher_rotation'] -ceq '1') 'Preferences created during the bounded retry were not migrated.'
Write-Host 'PASS: XML preservation/idempotence/DTD guards and one-time, backed-up, verified launcher migration with bounded retry and safe skip/failure.'
