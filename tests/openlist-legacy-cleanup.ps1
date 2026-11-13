<# Offline-only test: all OpenList operations and backup contents are in memory. #>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$project = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $project 'tools\OpenListLegacyCleanup.psm1') -Force

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('FAIL: ' + $Message) }
    Write-Host ('PASS: ' + $Message)
}
function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert $failed $Message
}
function Hash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Bytes([string]$Value) { return ,[Text.Encoding]::UTF8.GetBytes($Value) }

$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(2048)
$rsa.PersistKeyInCsp = $false
try {
    $key = $rsa.ToXmlString($false)
    $marker = Bytes '{"schema":1,"product":"ArtemisOS-15","from":"1.0.0","to":"1.0.0","notes":"","files":[]}'
    $markerSig = [Text.Encoding]::ASCII.GetBytes([Convert]::ToBase64String($rsa.SignData($marker, 'SHA256')))
    $future = Bytes '{"schema":1,"product":"ArtemisOS-15","from":"1.0.0","to":"1.0.1","notes":"","files":[]}'
    $futureSig = [Text.Encoding]::ASCII.GetBytes([Convert]::ToBase64String($rsa.SignData($future, 'SHA256')))
} finally { $rsa.Dispose() }
$backup = @{}
foreach ($version in @('0.3.4','0.3.5','0.3.6')) {
    foreach ($ext in @('json','sig')) {
        $path = 'manifests/' + $version + '.' + $ext
        $backup[$path] = Bytes ('fixture legacy ' + $path)
    }
}
$object = Bytes 'fixture legacy object'
$objectPath = 'objects/' + (Hash $object)
$backup[$objectPath] = $object
$expected = @{}
foreach ($path in $backup.Keys) { $expected[$path] = Hash $backup[$path] }
$otherObject = 'objects/' + ('a' * 64)

function New-Fixture {
    $files = @{}
    foreach ($path in $backup.Keys) { $files[$path] = [byte[]]$backup[$path].Clone() }
    $files['manifests/1.0.0.json'] = [byte[]]$marker.Clone()
    $files['manifests/1.0.0.sig'] = [byte[]]$markerSig.Clone()
    $files[$otherObject] = Bytes 'unrelated object'
    return [pscustomobject]@{
        Files=$files; Writes=(New-Object 'System.Collections.Generic.List[string]');
        Rounds=@{}; ListFault=''; FailRemove=''; KeepAfterRemove=$false;
        MutateMarkerAfter=''; MutateLegacyAfter=''; HiddenRead=''
    }
}

$adapter = [pscustomobject]@{
    List = {
        param($directory, $page, $pageSize)
        $s = $global:ArtemisLegacyCleanupFixture
        if ($directory -cnotin @('manifests','objects')) { throw 'Unexpected test list.' }
        if (-not $s.Rounds.ContainsKey($directory)) { $s.Rounds[$directory] = 0 }
        if ($page -eq 1) { $s.Rounds[$directory]++ }
        $prefix = $directory + '/'
        $items = @($s.Files.Keys | Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) } | Sort-Object | ForEach-Object {
            $modified = if ($s.ListFault -ceq 'changed-snapshot' -and $s.Rounds[$directory] -gt 1) { 'changed' } else { 'fixed' }
            [pscustomobject]@{name=$_.Substring($prefix.Length);is_dir=$false;size=$s.Files[$_].Length;modified=$modified}
        })
        $total = $items.Count
        $start = ($page - 1) * $pageSize
        $pageItems = @($items | Select-Object -Skip $start -First $pageSize)
        if ($s.ListFault -ceq 'ignored-pagination') { $pageItems = @($items | Select-Object -First $pageSize) }
        if ($s.ListFault -ceq 'incomplete-page' -and $pageItems.Count -gt 0) { $pageItems = @($pageItems | Select-Object -Skip 1) }
        if ($s.ListFault -ceq 'duplicate-entry' -and $page -eq 2 -and $pageItems.Count -gt 0) { $pageItems[0] = $items[0] }
        if ($s.ListFault -ceq 'changing-total' -and $page -eq 2) { $total++ }
        return [pscustomobject]@{total=$total;items=$pageItems}
    }
    Read = {
        param($relative)
        $s = $global:ArtemisLegacyCleanupFixture
        if ($s.HiddenRead -ceq $relative -or -not $s.Files.ContainsKey($relative)) { return $null }
        return ,[byte[]]$s.Files[$relative]
    }
    Remove = {
        param($relative)
        $s = $global:ArtemisLegacyCleanupFixture
        if ($relative -ceq $s.FailRemove) { throw 'Simulated interrupted deletion.' }
        [void]$s.Writes.Add($relative)
        if (-not $s.KeepAfterRemove) { [void]$s.Files.Remove($relative) }
        if ($relative -ceq $s.MutateMarkerAfter) {
            $s.Files['manifests/1.0.0.json'] = $future
            $s.Files['manifests/1.0.0.sig'] = $futureSig
        }
        if ($relative -ceq $s.MutateLegacyAfter) { $s.Files['manifests/0.3.5.json'] = Bytes 'changed by another writer' }
    }
}
function Invoke-Fixture($Fixture, [switch]$Execute, [hashtable]$LocalBackup = $backup, $Transport = $adapter) {
    $global:ArtemisLegacyCleanupFixture = $Fixture
    try {
        return Invoke-VerifiedLegacyCleanup -Adapter $Transport -ExpectedHashes $expected -BackupBytes $LocalBackup -PublicKey $key -Execute:$Execute
    } finally { Remove-Variable -Name ArtemisLegacyCleanupFixture -Scope Global -ErrorAction SilentlyContinue }
}

$fixture = New-Fixture
$result = Invoke-Fixture $fixture
Assert ($result.DryRun -and $result.Planned.Count -eq 7 -and $fixture.Writes.Count -eq 0) 'default dry-run reports exactly seven verified files without writes'
Assert ($fixture.Files.ContainsKey('manifests/1.0.0.json') -and $fixture.Files.ContainsKey($otherObject)) 'dry-run retains marker and unrelated object'

$fixture = New-Fixture
$result = Invoke-Fixture $fixture -Execute
Assert (-not $result.DryRun -and $result.Removed.Count -eq 7 -and $fixture.Writes.Count -eq 7) 'only the seven allowlisted old files are removed'
Assert ($fixture.Files.ContainsKey('manifests/1.0.0.json') -and $fixture.Files.ContainsKey('manifests/1.0.0.sig') -and $fixture.Files.ContainsKey($otherObject)) 'the signed marker and unrelated object survive cleanup'
Assert ($fixture.Writes[$fixture.Writes.Count - 1] -ceq $objectPath) 'the legacy object is removed after the old manifests'
$fixture.Writes.Clear()
$result = Invoke-Fixture $fixture -Execute
Assert ($result.Removed.Count -eq 0 -and $fixture.Writes.Count -eq 0) 'repeated cleanup is idempotent'

foreach ($fault in @('ignored-pagination','incomplete-page','duplicate-entry','changing-total','changed-snapshot')) {
    $fixture = New-Fixture
    $fixture.ListFault = $fault
    Assert-Rejected { Invoke-Fixture $fixture -Execute } ("$fault is rejected")
    Assert ($fixture.Writes.Count -eq 0) ("$fault caused no deletion")
}

$fixture = New-Fixture
$fixture.Files['manifests/1.0.0.sig'] = Bytes 'bad signature'
Assert-Rejected { Invoke-Fixture $fixture -Execute } 'invalid marker signature is rejected'
Assert ($fixture.Writes.Count -eq 0) 'invalid signature causes no deletion'
$fixture = New-Fixture
$fixture.Files['manifests/1.0.0.json'] = $future
$fixture.Files['manifests/1.0.0.sig'] = $futureSig
Assert-Rejected { Invoke-Fixture $fixture -Execute } 'a valid signed newer update is not a no-update marker'
Assert ($fixture.Writes.Count -eq 0) 'signed newer update causes no deletion'

$fixture = New-Fixture
$badBackup = @{}; foreach ($path in $backup.Keys) { $badBackup[$path] = $backup[$path] }
$badBackup['manifests/0.3.6.sig'] = Bytes 'invalid backup'
Assert-Rejected { Invoke-Fixture $fixture -Execute -LocalBackup $badBackup } 'a local backup with the wrong hash is rejected'
Assert ($fixture.Writes.Count -eq 0) 'bad backup causes no deletion'
$fixture = New-Fixture
$fixture.Files['manifests/0.3.6.json'] = Bytes 'different remote file'
Assert-Rejected { Invoke-Fixture $fixture -Execute } 'a mismatched remote file is rejected before deleting anything'
Assert ($fixture.Writes.Count -eq 0) 'remote mismatch causes no deletion'
$fixture = New-Fixture
$fixture.Files['manifests/1.0.1.json'] = Bytes 'unrecognized manifest'
Assert-Rejected { Invoke-Fixture $fixture -Execute } 'an unknown manifest prevents deleting a potentially shared object'
Assert ($fixture.Writes.Count -eq 0) 'unknown manifest causes no deletion'
$fixture = New-Fixture
$fixture.HiddenRead = 'manifests/0.3.4.json'
Assert-Rejected { Invoke-Fixture $fixture -Execute } 'listing and read disagreement is rejected'
Assert ($fixture.Writes.Count -eq 0) 'listing disagreement causes no deletion'

$fixture = New-Fixture
$fixture.FailRemove = 'manifests/0.3.5.sig'
Assert-Rejected { Invoke-Fixture $fixture -Execute } 'a deletion failure aborts the transaction'
Assert ($fixture.Writes.Count -eq 3 -and $fixture.Files.ContainsKey($objectPath)) 'interruption stops before later targets and keeps the object'
$fixture.FailRemove = ''
$result = Invoke-Fixture $fixture -Execute
Assert ($result.Removed.Count -eq 4 -and $fixture.Files.ContainsKey('manifests/1.0.0.json')) 'retry after partial cleanup completes and preserves the marker'

$fixture = New-Fixture
$fixture.MutateMarkerAfter = 'manifests/0.3.4.json'
Assert-Rejected { Invoke-Fixture $fixture -Execute } 'a marker changed during deletion is rejected'
Assert ($fixture.Writes.Count -eq 1 -and $fixture.Files.ContainsKey($objectPath)) 'marker change stops all later deletions'
$fixture = New-Fixture
$fixture.MutateLegacyAfter = 'manifests/0.3.4.json'
Assert-Rejected { Invoke-Fixture $fixture -Execute } 'a legacy file changed during deletion is rejected'
Assert ($fixture.Writes.Count -eq 1 -and $fixture.Files.ContainsKey($objectPath)) 'legacy mutation stops all later deletions'
$fixture = New-Fixture
$fixture.KeepAfterRemove = $true
Assert-Rejected { Invoke-Fixture $fixture -Execute } 'a server success that leaves the file visible is rejected'
Assert ($fixture.Writes.Count -eq 1 -and $fixture.Files.ContainsKey($objectPath)) 'unconfirmed deletion stops all later deletions'

# Exercise the actual production adapter as well, substituting in-memory API
# functions before it is instantiated. There is no listener, DNS, or network.
$entry = [IO.File]::ReadAllText((Join-Path $project 'tools\Invoke-OpenList-LegacyCleanup.ps1'))
$tokens = $null; $parseErrors = $null
$tree = [Management.Automation.Language.Parser]::ParseInput($entry, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'The production entry script does not parse.' }
$nodes = @($tree.FindAll({
    param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -ceq 'adapter'
}, $true))
if ($nodes.Count -ne 1) { throw 'Cannot isolate the production adapter.' }
$remoteRoot = '/ota'
$serverBase = 'in-memory-only'
function Get-UpdateResourceUri($Base, [string]$Relative) {
    if ($Base -cne 'in-memory-only') { throw 'Unexpected test URI.' }
    return $Relative
}
function Read-UpdateBytes([string]$Relative, [int]$Maximum) {
    $result = & $adapter.Read $Relative
    if ($null -eq $result -or $result.Length -gt $Maximum) { throw 'Invalid in-memory read.' }
    return ,[byte[]]$result
}
function Invoke-CleanupOpenListJson([string]$Method, [string]$Path, $Body, [bool]$Authenticated) {
    if ($Method -cne 'POST' -or -not $Authenticated) { throw 'Unexpected test API operation.' }
    if ($Path -ceq '/api/fs/list') {
        if ($Body.path -cnotin @('/ota/manifests','/ota/objects') -or $Body.password -cne '' -or -not $Body.refresh) {
            throw 'Unexpected production list parameters.'
        }
        $listing = & $adapter.List $Body.path.Substring(5) $Body.page $Body.per_page
        return [pscustomobject]@{code=200;data=[pscustomobject]@{total=$listing.total;content=$listing.items}}
    }
    if ($Path -ceq '/api/fs/get') {
        if (-not $Body.path.StartsWith('/ota/', [StringComparison]::Ordinal) -or $Body.password -cne '') {
            throw 'Unexpected production read parameters.'
        }
        $name = $Body.path.Substring(5)
        if ($global:ArtemisLegacyCleanupFixture.Files.ContainsKey($name)) { return [pscustomobject]@{code=200;data=[pscustomobject]@{is_dir=$false}} }
        return [pscustomobject]@{code=500;message='object not found'}
    }
    if ($Path -ceq '/api/fs/remove') {
        if ($Body.dir -cnotin @('/ota/manifests','/ota/objects') -or @($Body.names).Count -ne 1 -or $Body.follow_seed) {
            throw 'Unexpected production remove parameters.'
        }
        & $adapter.Remove ($Body.dir.Substring(5) + '/' + $Body.names[0])
        return [pscustomobject]@{code=200}
    }
    throw 'Unexpected API path; no network transport is available in this test.'
}
$makeAdapter = [scriptblock]::Create($nodes[0].Extent.Text + "`n`$adapter")
$productionAdapter = & $makeAdapter
$fixture = New-Fixture
$result = Invoke-Fixture $fixture -Transport $productionAdapter
Assert ($result.DryRun -and $result.Planned.Count -eq 7 -and $fixture.Writes.Count -eq 0) 'production API adapter honors read-only preview using only the in-memory API'
$fixture = New-Fixture
$result = Invoke-Fixture $fixture -Transport $productionAdapter -Execute
Assert ($result.Removed.Count -eq 7 -and $fixture.Writes.Count -eq 7 -and
    $fixture.Files.ContainsKey('manifests/1.0.0.json') -and $fixture.Files.ContainsKey($otherObject)) 'production API adapter sends only allowlisted one-file removes to the in-memory API'
$fixture = New-Fixture
$fixture.FailRemove = 'manifests/0.3.6.json'
Assert-Rejected { Invoke-Fixture $fixture -Transport $productionAdapter -Execute } 'production API adapter stops when a remove request fails'
Assert ($fixture.Writes.Count -eq 4 -and $fixture.Files.ContainsKey($objectPath)) 'production API failure does not continue to the legacy object'
