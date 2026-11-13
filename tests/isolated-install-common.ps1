# Shared, side-effect-free guards for the Windows installer acceptance harness.
Set-StrictMode -Version 2.0

function Get-IsolatedAccountIdentity([string]$RunId) {
    if ($RunId -cnotmatch '^[0-9a-f]{32}$') { throw 'Invalid run identifier.' }
    return [pscustomobject]@{ Name=('ArtTest' + $RunId.Substring(0,12)); Marker=('ArtTest-' + $RunId) }
}

function Test-IsolatedChildPath([string]$Parent, [string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Parent) -or [string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        if (-not [IO.Path]::IsPathRooted($Parent) -or -not [IO.Path]::IsPathRooted($Path)) { return $false }
        $root = [IO.Path]::GetFullPath($Parent).TrimEnd('\', '/') + '\'
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
        return $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Test-IsolatedProfileCandidate {
    param(
        [string]$ExpectedSid, [string]$ExpectedName, [string]$ProfilesRoot,
        [object]$Profile, [string[]]$OtherProfilePaths
    )
    if ($ExpectedSid -notmatch '^S-1-5-21-(?:\d+-){3}\d+$' -or
        $ExpectedName -notmatch '^ArtTest[0-9a-f]{12}$' -or $null -eq $Profile -or
        $Profile.SID -cne $ExpectedSid -or $Profile.Loaded -ne $false -or $Profile.Special -ne $false) { return $false }
    $path = [string]$Profile.LocalPath
    if (-not (Test-IsolatedChildPath $ProfilesRoot $path)) { return $false }
    try {
        $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path).TrimEnd('\'))
        if (-not [string]::Equals($parent, [IO.Path]::GetFullPath($ProfilesRoot).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $name = [IO.Path]::GetFileName($path)
        if ($name -notmatch ('^' + [regex]::Escape($ExpectedName) + '(?:\.[A-Za-z0-9_-]+)?$')) { return $false }
        foreach ($other in @($OtherProfilePaths)) {
            if ([string]::IsNullOrWhiteSpace($other)) { continue }
            $otherFull = [IO.Path]::GetFullPath($other).TrimEnd('\')
            if ([string]::Equals($path.TrimEnd('\'), $otherFull, [StringComparison]::OrdinalIgnoreCase) -or
                (Test-IsolatedChildPath $path $otherFull) -or (Test-IsolatedChildPath $otherFull $path)) { return $false }
        }
        return $true
    } catch { return $false }
}

function Assert-NoReparsePoints([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Path contains a reparse point.' }
        $parent = [IO.Path]::GetDirectoryName($item.FullName.TrimEnd('\'))
        if (-not $parent -or [string]::Equals($parent, $item.FullName, [StringComparison]::OrdinalIgnoreCase)) { break }
        $item = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
    }
}
