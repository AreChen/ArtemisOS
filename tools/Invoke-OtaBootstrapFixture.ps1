param(
    [Parameter(Mandatory=$true)][string]$FixtureRoot,
    [string]$ExplicitPath = '',
    [ValidateSet('Plan','Apply')][string]$Action = 'Plan',
    [string]$FromVersion = '1.0.0',
    [string]$ToVersion = '1.0.1'
)
# Fixture-only prototype. Never points at a real installation or registry.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$root = [IO.Path]::GetFullPath($FixtureRoot).TrimEnd('\')
$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$item = Get-Item -LiteralPath $root -Force
if ($item.Parent.FullName.TrimEnd('\') -ine $parent -or
    $item.Name -cnotmatch '^artemisos-bootstrap-fixture-[0-9a-f]{32}$' -or
    ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
    -not (Test-Path -LiteralPath (Join-Path $root '.fixture-only') -PathType Leaf)) {
    throw 'Refusing to operate outside the isolated fixture.'
}
$ancestor = $item.Parent
while ($ancestor) {
    if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Fixture ancestor is a reparse point.' }
    $ancestor = $ancestor.Parent
}
Import-Module (Join-Path $PSScriptRoot 'ArtemisInstallDiscovery.psm1') -Force
$parsedRecords = Get-Content -LiteralPath (Join-Path $root 'registry.json') -Raw | ConvertFrom-Json
$records = @()
foreach ($record in $parsedRecords) { if ($null -ne $record) { $records += $record } }
$discovery = Get-ArtemisInstallCandidates -Registrations $records
$choice = Resolve-ArtemisInstallTarget -Discovery $discovery -ExplicitPath $ExplicitPath -TargetVersion $ToVersion
if ($choice.Status -eq 'not_found') { Write-Output 'fresh'; exit 0 }
if ($choice.Status -ne 'selected') { throw "Installation selection refused: $($choice.Status)." }
$target = $choice.Candidate.Path
if (-not $target.StartsWith(($root + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Selected path is outside the fixture.' }
if ($choice.Candidate.Version -cne $FromVersion) { throw 'The fixture source release is not supported.' }
if ($Action -eq 'Plan') { Write-Output ('selected=' + $target); exit 0 }
if (Test-Path -LiteralPath (Join-Path $root 'running.flag')) { throw 'The fixture emulator is running.' }

function Get-ManagedFiles([string]$InstallRoot) {
    $found = New-Object 'System.Collections.Generic.List[string]'
    function Walk([string]$Directory, [string]$Prefix) {
        foreach ($child in @(Get-ChildItem -LiteralPath $Directory -Force)) {
            $relative = if ($Prefix) { $Prefix + '/' + $child.Name } else { $child.Name }
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'A managed path is a reparse point.' }
            if (-not $Prefix -and $child.Name -ieq 'data' -and $child.PSIsContainer) { continue }
            if (-not $Prefix -and $child.Name -imatch '^\.data-fresh-before-migration-[0-9a-f]{32}$' -and $child.PSIsContainer) { continue }
            if (-not $Prefix -and $child.Name -imatch '^unins\d{3}\.(exe|dat)$' -and -not $child.PSIsContainer) { continue }
            if ($relative -ieq 'update/server.txt' -and -not $child.PSIsContainer) { continue }
            if ($child.PSIsContainer) { Walk $child.FullName $relative } else { $found.Add($relative) }
        }
    }
    Walk $InstallRoot ''
    return @($found.ToArray())
}
function Read-Inventory([string]$Name) {
    $rows = Get-Content -LiteralPath (Join-Path $root $Name) -Raw | ConvertFrom-Json
    $map = @{}
    foreach ($row in $rows) {
        if ($row.path -isnot [string] -or $row.path -notmatch '^[A-Za-z0-9._/-]+$' -or
            $row.path -match '(^|/)\.\.?(/|$)|//|(^|/)data(/|$)' -or $row.sha256 -notmatch '^[0-9a-f]{64}$') {
            throw 'Invalid fixture inventory.'
        }
        $key = $row.path.ToLowerInvariant()
        if ($map.ContainsKey($key)) { throw 'Duplicate fixture inventory path.' }
        $map[$key] = [string]$row.sha256
    }
    return $map
}
$base = Read-Inventory 'baseline.json'
$expected = Read-Inventory 'target.json'
$actual = @(Get-ManagedFiles $target)
if ($base.Count -ne $actual.Count -or $expected.Count -ne $base.Count) { throw 'Managed file set does not match the pinned baseline.' }
foreach ($relative in $actual) {
    $key = $relative.ToLowerInvariant()
    if (-not $base.ContainsKey($key) -or -not $expected.ContainsKey($key)) { throw 'Managed inventory differs.' }
    $path = Join-Path $target ($relative.Replace('/', '\'))
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $base[$key]) {
        throw "Managed baseline differs: $relative"
    }
}
# Installed updater code and its public key have now been compared to the fixture
# baseline. Production must embed authenticated release inventories instead.
. (Join-Path $target 'update\core.ps1')
$offer = Get-UpdateOffer $target
if ($null -eq $offer -or $offer.Manifest.to -cne $ToVersion -or $offer.Manifest.from -cne $FromVersion) {
    throw 'Signed update is unavailable or targets a different release.'
}
$changes = @{}
foreach ($file in @($offer.Manifest.files)) {
    $key = $file.path.ToLowerInvariant()
    if (-not $base.ContainsKey($key) -or -not $expected.ContainsKey($key) -or
        $file.base_sha256 -ceq '-' -or $file.base_sha256 -cne $base[$key] -or
        $file.sha256 -cne $expected[$key]) { throw 'Update changes an unsupported file or baseline.' }
    $changes[$key] = $true
}
foreach ($key in $base.Keys) {
    if (-not $changes.ContainsKey($key) -and $base[$key] -cne $expected[$key]) { throw 'Update does not reach the pinned target tree.' }
}
$staging = Stage-UpdateOffer $target $offer
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
& rtk proxy $ps -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $target 'update\apply.ps1') -Staging $staging -Serial 'emulator-5554' -NoRestart
if ($LASTEXITCODE -ne 0) { throw 'The fixture OTA transaction failed.' }
if ((Get-UpdateVersion $target) -cne $ToVersion) { throw 'The fixture OTA did not reach the target version.' }
foreach ($relative in @(Get-ManagedFiles $target)) {
    $key = $relative.ToLowerInvariant()
    if (-not $expected.ContainsKey($key) -or (Get-FileHash -LiteralPath (Join-Path $target ($relative.Replace('/', '\'))) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected[$key]) {
        throw 'The resulting fixture tree does not match the target.'
    }
}
Write-Output 'upgraded'
