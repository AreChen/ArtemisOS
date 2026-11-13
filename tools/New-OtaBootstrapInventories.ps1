param(
    [Parameter(Mandatory=$true)][string]$BaselineRoot,
    [Parameter(Mandatory=$true)][string]$TargetRoot,
    [Parameter(Mandatory=$true)][string]$FromVersion,
    [Parameter(Mandatory=$true)][string]$ToVersion,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)
# Compare complete, immutable installed-file snapshots, not a live installation.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
if ($FromVersion -notmatch '^\d+\.\d+\.\d+$' -or $ToVersion -notmatch '^\d+\.\d+\.\d+$' -or
    [version]$ToVersion -le [version]$FromVersion) { throw 'Invalid source or target version.' }
$BaselineRoot = (Resolve-Path -LiteralPath $BaselineRoot).ProviderPath.TrimEnd('\')
$TargetRoot = (Resolve-Path -LiteralPath $TargetRoot).ProviderPath.TrimEnd('\')
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Output directory already exists.' }
[void][IO.Directory]::CreateDirectory($OutputDirectory)
function Add-Tree([hashtable]$Map, [string]$Root, [string]$Prefix) {
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force)) {
        $rel = if ($Prefix) { $Prefix + '/' + $item.Name } else { $item.Name }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point: $rel" }
        if (-not $Prefix -and $item.PSIsContainer -and $item.Name -ieq 'data') { continue }
        if (-not $Prefix -and $item.PSIsContainer -and $item.Name -imatch '^\.data-fresh-before-migration-[0-9a-f]{32}$') { continue }
        if (-not $Prefix -and -not $item.PSIsContainer -and $item.Name -imatch '^unins\d{3}\.(exe|dat)$') { continue }
        if ($rel -ieq 'update/server.txt' -and -not $item.PSIsContainer) { continue }
        if ($item.PSIsContainer) { Add-Tree $Map $item.FullName $rel }
        else {
            $key = $rel.ToLowerInvariant()
            if ($Map.ContainsKey($key)) { throw "Duplicate path: $rel" }
            $Map[$key] = [pscustomobject]@{path=$rel;sha256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
        }
    }
}
foreach ($pair in @(@($BaselineRoot,$FromVersion),@($TargetRoot,$ToVersion))) {
    $text = [IO.File]::ReadAllText((Join-Path $pair[0] 'version.ini'))
    if ($text -notmatch ('(?m)^Version=' + [regex]::Escape($pair[1]) + '\r?$')) { throw 'Snapshot version does not match the requested version.' }
}
$baseline = @{}
$target = @{}
Add-Tree $baseline $BaselineRoot ''
Add-Tree $target $TargetRoot ''
$missing = @($baseline.Keys | Where-Object { -not $target.ContainsKey($_) })
$added = @($target.Keys | Where-Object { -not $baseline.ContainsKey($_) })
$changed = @($baseline.Keys | Where-Object { $target.ContainsKey($_) -and $baseline[$_].sha256 -cne $target[$_].sha256 })
$summary = [ordered]@{from=$FromVersion;to=$ToVersion;baseline_count=$baseline.Count;target_count=$target.Count;missing=$missing;added=$added;changed=$changed}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'comparison.json'), (ConvertTo-Json -InputObject $summary -Depth 5), [Text.UTF8Encoding]::new($true))
$blocked = @($changed | Where-Object { $_ -in @('update/recovery.ps1','update/trusted-key.xml','update/server.txt') })
if ($missing.Count -or $added.Count -or $blocked.Count -or $changed.Count -lt 1 -or $changed.Count -gt 1000 -or 'version.ini' -cnotin $changed) {
    throw 'Snapshot changes are unsupported: additions, deletions, protected files, or invalid version change.'
}
# The old signed OTA verifier enforces its own path allowlist. Cross-check the
# prospective changes now to avoid producing a superficially usable inventory.
. (Join-Path $BaselineRoot 'update\core.ps1')
foreach ($key in $changed) { [void](Get-UpdateTarget $BaselineRoot $baseline[$key].path) }
foreach ($pair in @(@('baseline.json',$baseline),@('target.json',$target))) {
    $rows = @($pair[1].Values | Sort-Object path | ForEach-Object { [ordered]@{path=$_.path;sha256=$_.sha256} })
    [IO.File]::WriteAllText((Join-Path $OutputDirectory $pair[0]), (ConvertTo-Json -InputObject $rows -Depth 4), [Text.UTF8Encoding]::new($true))
}
Write-Host "Verified $($baseline.Count) files in each snapshot; $($changed.Count) supported changes."
