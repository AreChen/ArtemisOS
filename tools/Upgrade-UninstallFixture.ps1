[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Apply','Recover')][string]$Action,
    [Parameter(Mandatory = $true)][string]$FixtureRoot,
    [ValidateSet('', 'AfterBackup', 'BeforeHelper', 'DuringHelper', 'AfterHelper', 'BeforeRegistry', 'AfterRegistry', 'RecoveryTempCreated', 'DuringRecovery')][string]$CrashAt = ''
)

# TEST-ONLY. This script deliberately has no Windows registry-writing backend.
# It must never be used as the production metadata updater.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$knownIds = @('{E49344F1-069E-4DA4-A5B7-232C0BE325A8}', 'ArtemisOS15-Release')
$utf8 = New-Object System.Text.UTF8Encoding $true

function Fail([string]$Message) { throw $Message }
function Get-Hash([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','') }
    finally { $stream.Dispose(); $sha.Dispose() }
}
function Write-Atomic([string]$Path, [string]$Contents) {
    $temp = $Path + '.tmp'
    if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    [IO.File]::WriteAllText($temp, $Contents, $utf8)
    if ([IO.File]::Exists($Path)) {
        $replaced = $Path + '.fixture-replaced-' + [Guid]::NewGuid().ToString('N')
        [IO.File]::Replace($temp, $Path, $replaced)
        [IO.File]::Delete($replaced)
    }
    else { [IO.File]::Move($temp, $Path) }
}
function Set-Phase([string]$Phase) {
    $script:journal.Phase = $Phase
    Write-Atomic $script:journalPath ($script:journal | ConvertTo-Json -Depth 8)
}
function Require-Regular([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -eq 0) { Fail 'Expected a nonempty ordinary fixture file.' }
    $streams = @(Get-Item -LiteralPath $Path -Stream * -ErrorAction Stop | Where-Object { $_.Stream -ne ':$DATA' })
    if ($streams.Count) { Fail 'The fixture prototype cannot safely preserve alternate streams.' }
}
function Fixture-Paths {
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $root = [IO.Path]::GetFullPath($FixtureRoot).TrimEnd('\')
    $info = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if (-not $info.PSIsContainer -or $info.Parent.FullName.TrimEnd('\') -ine $temp -or
        $info.Name -notmatch '^artemisos-uninstall-fixture-[0-9a-f]{32}$') { Fail 'Only a dedicated TEMP fixture is allowed.' }
    $part = $info
    while ($part) {
        if ($part.Attributes -band [IO.FileAttributes]::ReparsePoint) { Fail 'Fixture paths cannot contain reparse points.' }
        $part = $part.Parent
    }
    if (-not [IO.File]::Exists((Join-Path $root '.fixture-only'))) { Fail 'Fixture marker missing.' }
    $script:root = $root
    $script:target = Join-Path $root 'target'
    $script:registry = Join-Path $root 'registry.json'
    $script:helper = Join-Path $root 'helper.exe'
    $script:helperHashFile = Join-Path $root 'helper.sha256'
    $script:manifest = Join-Path $root 'managed.txt'
    $script:transaction = Join-Path $root 'metadata-transaction'
    $script:journalPath = Join-Path $script:transaction 'journal.json'
    foreach ($directory in @($script:target, $script:transaction)) {
        if ([IO.Directory]::Exists($directory)) {
            $entry = Get-Item -LiteralPath $directory -Force
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { Fail 'Unsafe fixture directory.' }
        }
    }
}
function Validate-Registration {
    Require-Regular $script:registry
    $reg = [IO.File]::ReadAllText($script:registry) | ConvertFrom-Json
    if ($reg.AppId -notin $knownIds -or $reg.Hive -notin @('CurrentUser','LocalMachine') -or
        $reg.View -notin @('Registry32','Registry64')) { Fail 'Unknown fixture registration identity.' }
    if ([IO.Path]::GetFullPath([string]$reg.InstallPath).TrimEnd('\') -ine $script:target) { Fail 'Registration directory mismatch.' }
    if ($reg.UninstallString -notmatch '^"([^"]+)"$') { Fail 'Invalid uninstaller reference.' }
    $exe = [IO.Path]::GetFullPath($matches[1])
    if ([IO.Path]::GetDirectoryName($exe) -ine $script:target -or [IO.Path]::GetFileName($exe) -notmatch '^unins\d{3}\.exe$') { Fail 'Uninstaller must belong to the selected directory.' }
    if ($reg.DisplayVersion -notmatch '^\d+\.\d+\.\d+$' -or [version]$reg.DisplayVersion -ge [version]'1.0.0') { Fail 'Unexpected registered version.' }
    $dat = [IO.Path]::ChangeExtension($exe, '.dat')
    Require-Regular $exe; Require-Regular $dat
    return $reg
}
function Validate-Manifest {
    Require-Regular $script:manifest
    $paths = @([IO.File]::ReadAllLines($script:manifest) | Where-Object { $_ -ne '' })
    if ($paths.Count -eq 0) { Fail 'Empty managed-file manifest.' }
    $seen = @{}
    foreach ($path in $paths) {
        if ($path -notmatch '^sdk\\[A-Za-z0-9_.\\-]+$' -or $path -match '(^|\\)\.\.?($|\\)' -or $path -match '[*?:]') { Fail 'Unsafe managed-file manifest entry.' }
        $full = [IO.Path]::GetFullPath((Join-Path $script:target $path))
        if (-not $full.StartsWith($script:target + '\sdk\', [StringComparison]::OrdinalIgnoreCase) -or $seen.ContainsKey($full.ToLowerInvariant())) { Fail 'Managed file escaped or was duplicated.' }
        $seen[$full.ToLowerInvariant()] = $true
        $parent = [IO.Directory]::GetParent($full)
        while ($parent -and $parent.FullName -ine $script:target) {
            if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { Fail 'Managed path contains a reparse point.' }
            $parent = $parent.Parent
        }
        if (-not $parent) { Fail 'Managed path escaped the fixture installation.' }
        Require-Regular $full
    }
}
function Test-Crash([string]$Point) {
    if ($CrashAt -ceq $Point) { Write-Output "Fixture interruption: $Point"; exit 86 }
}
function Restore-File([string]$Name, [string]$ExpectedHash, [string]$Destination) {
    $backup = Join-Path $script:transaction $Name
    Require-Regular $backup
    if ((Get-Hash $backup) -cne $ExpectedHash) { Fail 'Fixture backup hash mismatch.' }
    $temp = $Destination + '.fixture-restore'
    if ([IO.File]::Exists($temp)) { Require-Regular $temp }
    else { [IO.File]::Copy($backup, $temp, $false) }
    if ((Get-Hash $temp) -cne $ExpectedHash) { Fail 'Fixture restore verification failed.' }
    Test-Crash 'RecoveryTempCreated'
    if ([IO.File]::Exists($Destination)) {
        $replaced = $Destination + '.fixture-replaced-' + [Guid]::NewGuid().ToString('N')
        [IO.File]::Replace($temp, $Destination, $replaced)
        [IO.File]::Delete($replaced)
    }
    else { [IO.File]::Move($temp, $Destination) }
}

try {
    Fixture-Paths
    if ($Action -eq 'Recover') {
        Require-Regular $script:journalPath
        $script:journal = [IO.File]::ReadAllText($script:journalPath) | ConvertFrom-Json
        if ($script:journal.Schema -ne 1 -or $script:journal.Target -ine $script:target -or
            $script:journal.AppId -notin $knownIds -or $script:journal.ExeName -notmatch '^unins\d{3}\.exe$' -or
            $script:journal.DatName -cne [IO.Path]::ChangeExtension($script:journal.ExeName, '.dat')) { Fail 'Unsafe fixture journal.' }
        if ($script:journal.Phase -eq 'committed') { Write-Output 'Fixture transaction is already committed.'; exit 0 }
        $expectedNames = @($script:journal.ExeName, $script:journal.DatName,
            ($script:journal.ExeName + '.fixture-restore'), ($script:journal.DatName + '.fixture-restore'))
        $unexpected = @(Get-ChildItem -LiteralPath $script:target -File -Filter 'unins*' | Where-Object { $_.Name -notin $expectedNames })
        if ($unexpected.Count) { Fail 'Unexpected uninstall files retained for inspection.' }
        Restore-File 'before-exe' $script:journal.ExeHash (Join-Path $script:target $script:journal.ExeName)
        Test-Crash 'DuringRecovery'
        Restore-File 'before-dat' $script:journal.DatHash (Join-Path $script:target $script:journal.DatName)
        Restore-File 'before-registry' $script:journal.RegistryHash $script:registry
        Set-Phase 'restored'
        Write-Output 'Fixture uninstall metadata restored.'
        exit 0
    }

    $registration = Validate-Registration
    Validate-Manifest
    Require-Regular $script:helper; Require-Regular $script:helperHashFile
    $helperHash = [IO.File]::ReadAllText($script:helperHashFile).Trim()
    if ($helperHash -notmatch '^[A-F0-9]{64}$' -or (Get-Hash $script:helper) -cne $helperHash) { Fail 'Fixture helper hash mismatch.' }
    $exeName = [IO.Path]::GetFileName(([string]$registration.UninstallString).Trim('"'))
    $datName = [IO.Path]::ChangeExtension($exeName, '.dat')
    $extra = @(Get-ChildItem -LiteralPath $script:target -File -Filter 'unins*' | Where-Object { $_.Name -notin @($exeName,$datName) })
    if ($extra.Count) { Fail 'Conflicting uninstall files.' }
    if ([IO.Directory]::Exists($script:transaction)) {
        if (-not [IO.File]::Exists($script:journalPath)) { Fail 'Incomplete fixture journal requires inspection.' }
        $previous = [IO.File]::ReadAllText($script:journalPath) | ConvertFrom-Json
        if ($previous.Phase -ne 'restored') { Fail 'Recover or inspect the existing fixture transaction first.' }
    } else { [void][IO.Directory]::CreateDirectory($script:transaction) }
    foreach ($pair in @(@($exeName,'before-exe'),@($datName,'before-dat'))) {
        [IO.File]::Copy((Join-Path $script:target $pair[0]), (Join-Path $script:transaction $pair[1]), $true)
    }
    [IO.File]::Copy($script:registry, (Join-Path $script:transaction 'before-registry'), $true)
    $script:journal = [pscustomobject]@{
        Schema = 1; Target = $script:target; AppId = $registration.AppId; ExeName = $exeName; DatName = $datName
        ExeHash = Get-Hash (Join-Path $script:transaction 'before-exe'); DatHash = Get-Hash (Join-Path $script:transaction 'before-dat')
        RegistryHash = Get-Hash (Join-Path $script:transaction 'before-registry'); HelperHash = $helperHash; Phase = 'prepared'
    }
    if ((Get-Hash (Join-Path $script:target $exeName)) -cne $script:journal.ExeHash -or
        (Get-Hash (Join-Path $script:target $datName)) -cne $script:journal.DatHash -or
        (Get-Hash $script:registry) -cne $script:journal.RegistryHash) { Fail 'Fixture backup did not match its source.' }
    Set-Phase 'prepared'; Test-Crash 'AfterBackup'
    Set-Phase 'helper-intent'; Test-Crash 'BeforeHelper'
    if ($CrashAt -ceq 'DuringHelper') {
        [IO.File]::WriteAllText((Join-Path $script:target $datName), 'simulated partial fixture log write')
        Test-Crash 'DuringHelper'
    }
    & rtk proxy $script:helper /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- ("/DIR=$($script:target)")
    if ($LASTEXITCODE -ne 0) { Fail 'Fixture cleanup helper failed.' }
    $extra = @(Get-ChildItem -LiteralPath $script:target -File -Filter 'unins*' | Where-Object { $_.Name -notin @($exeName,$datName) })
    if ($extra.Count) { Fail 'Helper did not append to the expected uninstall log; all files retained.' }
    Require-Regular (Join-Path $script:target $exeName); Require-Regular (Join-Path $script:target $datName)
    if ((Get-Hash (Join-Path $script:target $datName)) -ceq $script:journal.DatHash) { Fail 'Helper did not change the expected uninstall log.' }
    Set-Phase 'helper-complete'; Test-Crash 'AfterHelper'
    if ((Get-Hash $script:registry) -cne $script:journal.RegistryHash) { Fail 'Fixture registration changed concurrently.' }
    Set-Phase 'registry-intent'; Test-Crash 'BeforeRegistry'
    $registration.DisplayVersion = '1.0.0'
    Write-Atomic $script:registry ($registration | ConvertTo-Json)
    Test-Crash 'AfterRegistry'
    Set-Phase 'committed'
    Write-Output 'Fixture uninstall metadata and version updated.'
    exit 0
} catch {
    Write-Error -ErrorAction Continue ('Fixture operation stopped: ' + $_.Exception.Message)
    exit 1
}
