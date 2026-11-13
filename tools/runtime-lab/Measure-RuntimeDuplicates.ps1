param(
    [string]$SourceRoot = (Join-Path $PSScriptRoot '..\..\build\slim-sdk-0.3.5-pilot\emulator'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\..\build\runtime-slim-exp')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$allowed = [IO.Path]::GetFullPath((Join-Path $project 'build\runtime-slim-exp')).TrimEnd('\')
$source = (Resolve-Path -LiteralPath $SourceRoot).ProviderPath.TrimEnd('\')
$output = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
if ($output -ne $allowed -and -not $output.StartsWith($allowed + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Output must be inside build\runtime-slim-exp.'
}
if ($source -eq $output -or $source.StartsWith($output + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $output.StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Source and output must be separate directory trees.'
}
[void][IO.Directory]::CreateDirectory($output)
$files = @(Get-ChildItem -LiteralPath $source -File -Recurse -Force | Sort-Object FullName)
if ($files.Count -eq 0) { throw 'Source runtime is empty.' }
if (@($files | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
    throw 'Runtime files must not be reparse points.'
}

$inventory = @($files | ForEach-Object {
    [pscustomobject]@{ path = $_.FullName.Substring($source.Length + 1); bytes = [Int64]$_.Length }
})
$inventory | Export-Csv -LiteralPath (Join-Path $output 'runtime-file-sizes.csv') -NoTypeInformation -Encoding UTF8
$candidates = @($files | Group-Object Length | Where-Object { $_.Count -gt 1 -and [Int64]$_.Name -ge 1024 })
$hashed = @(foreach ($candidate in $candidates) {
    foreach ($file in $candidate.Group) {
        [pscustomobject]@{
            path = $file.FullName.Substring($source.Length + 1)
            bytes = [Int64]$file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
})
$groups = @(foreach ($match in ($hashed | Group-Object sha256 | Where-Object Count -gt 1 | Sort-Object Name)) {
    $members = @($match.Group | Sort-Object path)
    [pscustomobject]@{
        sha256 = $match.Name
        bytes_per_file = [Int64]$members[0].bytes
        canonical_path = $members[0].path
        paths = @($members | ForEach-Object { $_.path })
        duplicated_bytes = [Int64]$members[0].bytes * ($members.Count - 1)
    }
})
$total = ($inventory | Measure-Object -Property bytes -Sum).Sum
$duplicateTotal = ($groups | Measure-Object -Property duplicated_bytes -Sum).Sum
$result = [pscustomobject]@{
    source = $source
    note = 'Identical SHA-256 files; duplicated bytes are logical, not verified download or disk savings.'
    file_count = $files.Count
    total_logical_bytes = [Int64]$total
    duplicate_groups = $groups.Count
    duplicate_logical_bytes = [Int64]$duplicateTotal
    groups = $groups
}
$json = $result | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText((Join-Path $output 'runtime-duplicates.json'), $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding $false))
Write-Host "Recorded $($files.Count) runtime files; $($groups.Count) identical-content groups contain $duplicateTotal duplicated logical bytes."
Write-Host "Manifest: $(Join-Path $output 'runtime-duplicates.json')"
