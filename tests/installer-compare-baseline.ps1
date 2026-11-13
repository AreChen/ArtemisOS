param([Parameter(Mandatory=$true)][string]$Target, [Parameter(Mandatory=$true)][string]$Inventory)
# Read-only audit: no emulator interaction and no writes to the installation.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$root = (Resolve-Path -LiteralPath $Target).ProviderPath.TrimEnd('\')
$rows = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Inventory).ProviderPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$expected = @{}
foreach ($row in $rows) { $expected[$row.path.ToLowerInvariant()] = $row.sha256 }
$actual = @{}
$excluded = New-Object 'System.Collections.Generic.List[string]'
function Walk([string]$Directory, [string]$Prefix) {
    foreach ($child in @(Get-ChildItem -LiteralPath $Directory -Force)) {
        $rel = if ($Prefix) { $Prefix + '/' + $child.Name } else { $child.Name }
        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point: $rel" }
        if ((-not $Prefix -and $child.PSIsContainer -and
            ($child.Name -ieq 'data' -or $child.Name -imatch '^\.data-fresh-before-migration-[0-9a-f]{32}$')) -or
            (-not $Prefix -and -not $child.PSIsContainer -and $child.Name -imatch '^unins\d{3}\.(exe|dat)$') -or
            ($rel -ieq 'update/server.txt' -and -not $child.PSIsContainer)) { $excluded.Add($rel); continue }
        if ($child.PSIsContainer) { Walk $child.FullName $rel }
        else { $actual[$rel.ToLowerInvariant()] = $child.FullName }
    }
}
Walk $root ''
$missing = @($expected.Keys | Where-Object { -not $actual.ContainsKey($_) })
$added = @($actual.Keys | Where-Object { -not $expected.ContainsKey($_) })
$changed = New-Object 'System.Collections.Generic.List[string]'
foreach ($key in @($expected.Keys)) {
    if ($actual.ContainsKey($key) -and (Get-FileHash -LiteralPath $actual[$key] -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected[$key]) {
        $changed.Add($key)
    }
}
$report = [ordered]@{expected_count=$expected.Count;actual_count=$actual.Count;excluded=@($excluded.ToArray());
    missing=$missing;added=$added;changed=@($changed.ToArray())}
ConvertTo-Json -InputObject $report -Depth 5
if ($missing.Count -or $added.Count -or $changed.Count) { exit 1 }
