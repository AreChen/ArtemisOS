<#
Create and verify an independent, complete copy of an offline instance's data.
The caller must stop the emulator first; this script never deletes or moves the
source. An incomplete destination is deliberately retained for inspection.
#>
param(
    [Parameter(Mandatory=$true)][string]$InstallRoot,
    [Parameter(Mandatory=$true)][string]$Source,
    [Parameter(Mandatory=$true)][string]$DestinationParent,
    [Parameter(Mandatory=$true)][string]$DestinationName
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop

function Assert-PlainDirectory([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) { throw 'Expected a directory.' }
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Directory path contains a link.' }
        $item = $item.Parent
    }
}

$installRoot = (Resolve-Path -LiteralPath $InstallRoot).ProviderPath.TrimEnd('\')
$sourceRoot = (Resolve-Path -LiteralPath $Source).ProviderPath.TrimEnd('\')
$destinationParent = (Resolve-Path -LiteralPath $DestinationParent).ProviderPath.TrimEnd('\')
Assert-PlainDirectory $installRoot
Assert-PlainDirectory $sourceRoot
Assert-PlainDirectory $destinationParent
if (-not $sourceRoot.StartsWith(($installRoot + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Source is not inside the selected installation.' }
if ($DestinationName -notmatch '^user-data-before-1\.0\.0-[0-9a-f]{32}$') { throw 'Unexpected backup name.' }
$destination = [IO.Path]::GetFullPath((Join-Path $destinationParent $DestinationName))
if (-not $destination.StartsWith(($destinationParent + '\'), [StringComparison]::OrdinalIgnoreCase) -or
    $destination.Equals($installRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $destination.StartsWith(($installRoot + '\'), [StringComparison]::OrdinalIgnoreCase) -or
    $sourceRoot.StartsWith(($destination + '\'), [StringComparison]::OrdinalIgnoreCase) -or
    $destination.StartsWith(($sourceRoot + '\'), [StringComparison]::OrdinalIgnoreCase) -or
    (Test-Path -LiteralPath $destination)) { throw 'Source and new backup directory must be separate.' }

$dirs = New-Object 'Collections.Generic.List[string]'
$files = New-Object 'Collections.Generic.List[object]'
$verified = New-Object 'Collections.Generic.List[object]'
$handles = New-Object 'Collections.Generic.List[IO.FileStream]'
$pending = New-Object 'Collections.Generic.Stack[string]'
$pending.Push($sourceRoot)
try {
    while ($pending.Count -gt 0) {
        $dir = $pending.Pop()
        foreach ($entry in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)) {
            $full = [IO.Path]::GetFullPath($entry.FullName)
            if (-not $full.StartsWith(($sourceRoot + '\'), [StringComparison]::OrdinalIgnoreCase) -or
                ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unexpected item in data directory.' }
            $relative = $full.Substring($sourceRoot.Length + 1)
            if ($entry.PSIsContainer) { $dirs.Add($relative); $pending.Push($full) }
            elseif ($entry -is [IO.FileInfo]) {
                $handles.Add([IO.File]::Open($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
                $files.Add([pscustomobject]@{ Relative=$relative; Length=$entry.Length; Ticks=$entry.LastWriteTimeUtc.Ticks })
            } else { throw 'Unexpected non-file item in data directory.' }
        }
    }
    [void](New-Item -Path $destination -ItemType Directory -ErrorAction Stop)
    foreach ($relative in @($dirs | Sort-Object Length)) { [void](New-Item -Path (Join-Path $destination $relative) -ItemType Directory -ErrorAction Stop) }
    foreach ($entry in $files) {
        $original = Join-Path $sourceRoot $entry.Relative
        $copy = Join-Path $destination $entry.Relative
        [IO.File]::Copy($original, $copy, $false)
        $originalHash = (Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash
        if ($originalHash -cne (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash) {
            throw 'A backup file failed SHA-256 verification.'
        }
        $after = Get-Item -LiteralPath $original -Force -ErrorAction Stop
        if ($after.Length -ne $entry.Length -or $after.LastWriteTimeUtc.Ticks -ne $entry.Ticks) { throw 'Source changed during backup.' }
        $verified.Add([ordered]@{path=$entry.Relative;length=$entry.Length;sha256=$originalHash})
    }
    $originalNames = @(Get-ChildItem -LiteralPath $sourceRoot -Force -Recurse -ErrorAction Stop | ForEach-Object { $_.FullName.Substring($sourceRoot.Length + 1) })
    $copiedNames = @(Get-ChildItem -LiteralPath $destination -Force -Recurse -ErrorAction Stop | ForEach-Object { $_.FullName.Substring($destination.Length + 1) })
    if ($originalNames.Count -ne $copiedNames.Count -or
        ($originalNames.Count -gt 0 -and @(Compare-Object -ReferenceObject $originalNames -DifferenceObject $copiedNames).Count -ne 0)) {
        throw 'Backup entries differ from the source.'
    }
    $receipt = $destination + '.verified.json'
    if (Test-Path -LiteralPath $receipt) { throw 'Backup receipt already exists.' }
    $document = [ordered]@{schema=1;installRoot=$installRoot;source=$sourceRoot;backup=$destination;files=@($verified.ToArray())} | ConvertTo-Json -Depth 5
    $temporaryReceipt = $receipt + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temporaryReceipt, $document, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporaryReceipt, $receipt)
    Write-Output ("Verified backup: {0} files, {1} directories, {2}" -f $files.Count, $dirs.Count, $destination)
} finally {
    foreach ($handle in $handles) { $handle.Dispose() }
}
