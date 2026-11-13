Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# The transport is injected so the deletion policy can be tested without a
# network, credentials, or a live OpenList repository. The production entry
# point supplies a fixed path/hash allowlist and its own authenticated adapter.
function Get-CleanupHash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Test-CleanupBytes([byte[]]$Left, [byte[]]$Right) {
    if ($null -eq $Left -or $null -eq $Right -or $Left.Length -ne $Right.Length) { return $false }
    for ($i = 0; $i -lt $Left.Length; $i++) { if ($Left[$i] -ne $Right[$i]) { return $false } }
    return $true
}

function Assert-CleanupMarker([byte[]]$Bytes, [byte[]]$SignatureBytes, [string]$PublicKey) {
    if ($null -eq $Bytes -or $null -eq $SignatureBytes -or $Bytes.Length -gt 1048576 -or
        $SignatureBytes.Length -gt 1048576) { throw 'The signed 1.0.0 marker is missing or too large.' }
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    $rsa.PersistKeyInCsp = $false
    try {
        $rsa.FromXmlString($PublicKey)
        $signature = [Convert]::FromBase64String([Text.Encoding]::ASCII.GetString($SignatureBytes).Trim())
        if (-not $rsa.VerifyData($Bytes, 'SHA256', $signature)) { throw 'Invalid marker signature.' }
    } finally { $rsa.Dispose() }
    $manifest = [Text.Encoding]::UTF8.GetString($Bytes) | ConvertFrom-Json
    if ($manifest.schema -ne 1 -or $manifest.product -cne 'ArtemisOS-15' -or
        $manifest.from -cne '1.0.0' -or $manifest.to -cne '1.0.0' -or
        $manifest.files -isnot [array] -or $manifest.files.Count -ne 0) {
        throw 'The signed 1.0.0 manifest is not a no-update marker.'
    }
}

function Get-CleanupSnapshot($Adapter, [string]$Directory, [string[]]$AllowedManifests) {
    $pageSize = 2
    $page = 1
    $total = $null
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $entries = New-Object 'System.Collections.Generic.List[string]'
    while ($true) {
        $response = & $Adapter.List $Directory $page $pageSize
        if ($null -eq $response) { throw 'Cannot list the repository.' }
        $count = 0
        if (-not [int]::TryParse([string]$response.total, [ref]$count) -or $count -lt 0 -or $count -gt 4096) {
            throw 'Invalid repository inventory total.'
        }
        if ($null -eq $total) { $total = $count }
        elseif ($total -ne $count) { throw 'Repository inventory changed between pages.' }
        $items = @($response.items | Where-Object { $null -ne $_ })
        $remaining = [Math]::Max(0, $total - (($page - 1) * $pageSize))
        $expectedCount = [Math]::Min($pageSize, $remaining)
        if ($items.Count -ne $expectedCount) { throw 'Repository pagination is incomplete or unsupported.' }
        foreach ($item in $items) {
            $name = [string]$item.name
            if ($item.is_dir -or $name -notmatch '^[^/\\:\x00-\x1f]+$' -or $name -in @('.', '..') -or
                -not $seen.Add($name)) { throw 'Invalid or duplicate inventory entry.' }
            # Unknown manifests might refer to the old object; refuse cleanup.
            # Other object files are kept untouched.
            if ($Directory -ceq 'manifests' -and $name -cnotin $AllowedManifests) {
                throw 'An unrecognized manifest prevents safe object cleanup.'
            }
            $size = [long]0
            if (-not [long]::TryParse([string]$item.size, [ref]$size) -or $size -lt 0) { throw 'Invalid inventory file size.' }
            $entries.Add(($name + "`n" + $size + "`n" + [string]$item.modified))
        }
        # Probe one complete page past the reported end, including empty lists.
        if ($expectedCount -eq 0) { break }
        $page++
    }
    if ($seen.Count -ne $total) { throw 'Repository inventory count does not match its total.' }
    return [pscustomobject]@{ Entries = [string[]]@($entries | Sort-Object); Names = $seen }
}

function Get-VerifiedCleanupInventory($Adapter, [string[]]$AllowedManifests) {
    $result = @{}
    foreach ($directory in @('manifests', 'objects')) {
        $first = Get-CleanupSnapshot $Adapter $directory $AllowedManifests
        $second = Get-CleanupSnapshot $Adapter $directory $AllowedManifests
        if ($first.Entries.Count -ne $second.Entries.Count) { throw 'Repository inventory changed between snapshots.' }
        for ($i = 0; $i -lt $first.Entries.Count; $i++) {
            if ($first.Entries[$i] -cne $second.Entries[$i]) { throw 'Repository inventory changed between snapshots.' }
        }
        $result[$directory] = $second.Names
    }
    return $result
}

function Read-CleanupFile($Adapter, $Inventory, [string]$Relative) {
    $parts = $Relative.Split('/')
    if ($parts.Count -ne 2 -or $parts[0] -cnotin @('manifests', 'objects')) { throw 'Invalid cleanup path.' }
    $present = $Inventory[$parts[0]].Contains($parts[1])
    $bytes = & $Adapter.Read $Relative
    if ($present -ne ($null -ne $bytes)) { throw 'The file and complete inventory disagree.' }
    if ($null -eq $bytes) { return $null }
    if ($bytes -isnot [byte[]] -or $bytes.Length -gt 1048576) { throw 'Invalid remote file bytes.' }
    return ,$bytes
}

function Invoke-VerifiedLegacyCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Adapter,
        [Parameter(Mandatory=$true)][hashtable]$ExpectedHashes,
        [Parameter(Mandatory=$true)][hashtable]$BackupBytes,
        [Parameter(Mandatory=$true)][string]$PublicKey,
        [switch]$Execute
    )
    foreach ($name in @('List', 'Read', 'Remove')) {
        if ($Adapter.$name -isnot [scriptblock]) { throw 'Invalid repository adapter.' }
    }
    $manifestPaths = @('manifests/0.3.4.json', 'manifests/0.3.4.sig',
        'manifests/0.3.5.json', 'manifests/0.3.5.sig', 'manifests/0.3.6.json', 'manifests/0.3.6.sig')
    $objectPaths = @($ExpectedHashes.Keys | Where-Object { $_ -cmatch '^objects/[0-9a-f]{64}$' })
    if ($ExpectedHashes.Count -ne 7 -or $objectPaths.Count -ne 1 -or
        @($manifestPaths | Where-Object { -not $ExpectedHashes.ContainsKey($_) }).Count -ne 0) {
        throw 'The cleanup allowlist is invalid.'
    }
    $paths = @($manifestPaths) + @($objectPaths[0])
    foreach ($path in $paths) {
        if (-not $BackupBytes.ContainsKey($path) -or $BackupBytes[$path] -isnot [byte[]] -or
            $ExpectedHashes[$path] -cnotmatch '^[0-9a-f]{64}$' -or
            (Get-CleanupHash $BackupBytes[$path]) -cne $ExpectedHashes[$path]) { throw 'A local backup does not match its pinned hash.' }
    }
    if ($ExpectedHashes[$objectPaths[0]] -cne $objectPaths[0].Substring(8)) { throw 'The object name does not match its pinned hash.' }
    $allowedManifests = @($manifestPaths | ForEach-Object { $_.Substring(10) }) + @('1.0.0.json', '1.0.0.sig')

    # Complete preflight includes all remaining old files before the first
    # deletion. Repeat the checks for every single removal.
    $initialJson = $null
    $initialSig = $null
    $removed = New-Object 'System.Collections.Generic.List[string]'
    $planned = New-Object 'System.Collections.Generic.List[string]'
    $rounds = if ($Execute) { $paths.Count + 1 } else { 1 }
    for ($round = 0; $round -lt $rounds; $round++) {
        $inventory = Get-VerifiedCleanupInventory $Adapter $allowedManifests
        $markerJson = Read-CleanupFile $Adapter $inventory 'manifests/1.0.0.json'
        $markerSig = Read-CleanupFile $Adapter $inventory 'manifests/1.0.0.sig'
        Assert-CleanupMarker $markerJson $markerSig $PublicKey
        if ($round -eq 0) { $initialJson = $markerJson; $initialSig = $markerSig }
        elseif (-not (Test-CleanupBytes $markerJson $initialJson) -or -not (Test-CleanupBytes $markerSig $initialSig)) {
            throw 'The 1.0.0 marker changed during cleanup.'
        }
        foreach ($path in $paths) {
            $remote = Read-CleanupFile $Adapter $inventory $path
            if ($null -ne $remote -and -not (Test-CleanupBytes $remote $BackupBytes[$path])) {
                throw 'A remote legacy file differs from the verified backup.'
            }
            if ($removed.Contains($path) -and $null -ne $remote) { throw 'A deleted legacy file reappeared.' }
            if ($round -eq 0 -and $null -ne $remote) { $planned.Add($path) }
        }
        if (-not $Execute -or $round -eq $paths.Count) { break }
        $path = $paths[$round]
        $remote = Read-CleanupFile $Adapter $inventory $path
        if ($null -eq $remote) { continue }
        if (-not (Test-CleanupBytes $remote $BackupBytes[$path])) { throw 'The legacy file changed before deletion.' }
        & $Adapter.Remove $path
        $after = & $Adapter.Read $path
        if ($null -ne $after) { throw 'A removed file remains visible.' }
        $removed.Add($path)
    }
    return [pscustomobject]@{ DryRun = -not [bool]$Execute; Planned = [string[]]$planned.ToArray(); Removed = [string[]]$removed.ToArray() }
}

Export-ModuleMember -Function Invoke-VerifiedLegacyCleanup
