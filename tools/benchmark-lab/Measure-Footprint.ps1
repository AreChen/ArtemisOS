param(
    [Parameter(Mandatory=$true)][string]$SdkRoot,
    [Parameter(Mandatory=$true)][string]$Output,
    [string]$Installer,
    [switch]$HashInstaller,
    [switch]$HashSystemImage
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $SdkRoot).ProviderPath.TrimEnd('\')
$rootItem = Get-Item -LiteralPath $root -Force
if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'SdkRoot must be a regular directory.'
}
$out = [IO.Path]::GetFullPath($Output)
if ($out.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Output must be outside SdkRoot.' }
if (Test-Path -LiteralPath $out) { throw 'Refusing to overwrite an existing measurement.' }
if (-not (Test-Path -LiteralPath (Split-Path -Parent $out) -PathType Container)) { throw 'Output parent directory must already exist.' }
if ($HashInstaller -and -not $Installer) { throw 'HashInstaller requires an installer path.' }

if (-not ('ArtemisBenchmarkFileSize' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class ArtemisBenchmarkFileSize {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern uint GetCompressedFileSizeW(string name, out uint high);
    [DllImport("kernel32.dll")]
    private static extern void SetLastError(uint error);
    public static ulong Get(string name) {
        uint high;
        SetLastError(0);
        uint low = GetCompressedFileSizeW(name, out high);
        int error = Marshal.GetLastWin32Error();
        if (low == uint.MaxValue && error != 0) throw new Win32Exception(error);
        return ((ulong)high << 32) | low;
    }
}
'@
}

$pending = [Collections.Generic.Stack[string]]::new()
$pending.Push($root)
$groups = @{}
$skipped = [Collections.Generic.List[string]]::new()
$fileCount = 0
while ($pending.Count -gt 0) {
    $dir = $pending.Pop()
    foreach ($item in Get-ChildItem -LiteralPath $dir -Force) {
        $relative = $item.FullName.Substring($root.Length + 1)
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $skipped.Add($relative); continue }
        if ($item.PSIsContainer) { $pending.Push($item.FullName); continue }
        $top = $relative.Split([char]'\')[0]
        if (-not $groups.ContainsKey($top)) { $groups[$top] = @{ files = 0; logical_bytes = [uint64]0; windows_file_size_bytes = [uint64]0 } }
        $groups[$top].files++
        $groups[$top].logical_bytes += [uint64]$item.Length
        $groups[$top].windows_file_size_bytes += [ArtemisBenchmarkFileSize]::Get($item.FullName)
        $fileCount++
    }
}
$groupResults = @()
foreach ($name in ($groups.Keys | Sort-Object)) {
    $groupResults += [ordered]@{ name=$name; files=$groups[$name].files;
        logical_bytes=$groups[$name].logical_bytes; windows_file_size_bytes=$groups[$name].windows_file_size_bytes }
}
$installerResult = $null
if ($Installer) {
    $item = Get-Item -LiteralPath $Installer -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Installer must be a regular file.' }
    $installerResult = [ordered]@{ path=$item.FullName; bytes=[uint64]$item.Length; sha256=$null }
    if ($HashInstaller) { $installerResult.sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
}
$imageResult = $null
$image = Join-Path $root 'system-images\android-35\google_apis\x86_64\system.img'
if (Test-Path -LiteralPath $image -PathType Leaf) {
    $item = Get-Item -LiteralPath $image -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'System image cannot be a reparse point.' }
    $imageResult = [ordered]@{ path=$item.FullName; logical_bytes=[uint64]$item.Length;
        windows_file_size_bytes=[ArtemisBenchmarkFileSize]::Get($item.FullName); sha256=$null }
    if ($HashSystemImage) { $imageResult.sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
} elseif ($HashSystemImage) { throw 'System image not found at the expected Android 35 SDK path.' }
$result = [ordered]@{
    schema=1; collected_utc=[DateTime]::UtcNow.ToString('o'); sdk_root=$root; file_count=$fileCount
    groups=$groupResults; installer=$installerResult; system_image=$imageResult; skipped_reparse_points=@($skipped.ToArray())
    scope='Read-only file-path totals. Windows GetCompressedFileSizeW handles sparse/compressed files, but does not include all filesystem overhead or deduplicate hard links. Userdata and other paths outside SdkRoot are excluded.'
    compression_note='The installer is measured as a whole. Component file sizes and separately compressed streams cannot be summed into an Inno solid-compressed installer size.'
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $out -Encoding UTF8
Write-Output "Footprint measurement saved to $out"
