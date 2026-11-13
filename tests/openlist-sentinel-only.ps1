$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop
$project = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path $project ('build\openlist-sentinel-only-test-' + [Guid]::NewGuid().ToString('N'))
$target = Join-Path $fixture 'target'
$repository = Join-Path $fixture 'repository'
$keys = Join-Path $fixture 'keys'
foreach ($path in @((Join-Path $target 'update'), (Join-Path $repository 'manifests'), $keys)) {
    [void][IO.Directory]::CreateDirectory($path)
}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw $Message }
}
function Equal-Bytes([byte[]]$A, [byte[]]$B) {
    return [Convert]::ToBase64String($A) -ceq [Convert]::ToBase64String($B)
}

$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(2048)
$rsa.PersistKeyInCsp = $false
try {
    [IO.File]::WriteAllText((Join-Path $target 'version.ini'), "[ArtemisOS]`nVersion=0.3.6`n")
    $publicPath = Join-Path $target 'update\trusted-key.xml'
    [IO.File]::WriteAllText($publicPath, $rsa.ToXmlString($false))
    $private = [Text.Encoding]::UTF8.GetBytes($rsa.ToXmlString($true))
    try {
        $protected = [Security.Cryptography.ProtectedData]::Protect($private, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        [IO.File]::WriteAllBytes((Join-Path $keys 'ota-private.dpapi'), $protected)
    } finally { [Array]::Clear($private, 0, $private.Length) }

    # Unrelated older files must remain untouched locally and on the mock server.
    $oldJson = [Text.Encoding]::UTF8.GetBytes('old local manifest')
    $oldSig = [Text.Encoding]::ASCII.GetBytes('old local signature')
    [IO.File]::WriteAllBytes((Join-Path $repository 'manifests\0.3.5.json'), $oldJson)
    [IO.File]::WriteAllBytes((Join-Path $repository 'manifests\0.3.5.sig'), $oldSig)
    $generator = Join-Path $project 'tools\New-UpdateSentinel.ps1'
    & $generator -TargetRoot $target -Repository $repository -KeyDirectory $keys
    $targetJsonPath = Join-Path $repository 'manifests\0.3.6.json'
    $targetSigPath = Join-Path $repository 'manifests\0.3.6.sig'
    $targetJson = [IO.File]::ReadAllBytes($targetJsonPath)
    $targetSig = [IO.File]::ReadAllBytes($targetSigPath)
    $targetSignature = [Convert]::FromBase64String([Text.Encoding]::ASCII.GetString($targetSig))
    $manifest = [Text.Encoding]::UTF8.GetString($targetJson) | ConvertFrom-Json
    Assert ($rsa.VerifyData($targetJson, 'SHA256', $targetSignature)) 'Generated marker signature is invalid.'
    Assert ($manifest.schema -eq 1 -and $manifest.product -ceq 'ArtemisOS-15' -and
        $manifest.from -ceq '0.3.6' -and $manifest.to -ceq '0.3.6' -and
        $manifest.files -is [array] -and $manifest.files.Count -eq 0) 'Generated marker has the wrong content.'
    Assert (Equal-Bytes ([IO.File]::ReadAllBytes((Join-Path $repository 'manifests\0.3.5.json'))) $oldJson) 'The local old manifest changed.'
    Assert (Equal-Bytes ([IO.File]::ReadAllBytes((Join-Path $repository 'manifests\0.3.5.sig'))) $oldSig) 'The local old signature changed.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $repository 'objects'))) 'Generating a sentinel must not create update objects.'
    & $generator -TargetRoot $target -Repository $repository -KeyDirectory $keys
    Assert (Equal-Bytes ([IO.File]::ReadAllBytes($targetJsonPath)) $targetJson) 'Idempotent generation changed the marker.'
    Assert (Equal-Bytes ([IO.File]::ReadAllBytes($targetSigPath)) $targetSig) 'Idempotent generation changed the signature.'
    [IO.File]::WriteAllText($targetSigPath, 'conflict')
    Assert-Rejected { & $generator -TargetRoot $target -Repository $repository -KeyDirectory $keys } 'Conflicting local target was accepted.'
    Assert ([IO.File]::ReadAllText($targetSigPath) -ceq 'conflict') 'Conflicting local signature was overwritten.'
    Assert (Equal-Bytes ([IO.File]::ReadAllBytes($targetJsonPath)) $targetJson) 'Preflight failure changed the local target JSON.'
    [IO.File]::WriteAllBytes($targetSigPath, $targetSig)

    # Replace only the publisher's HTTP transport functions in an in-memory copy.
    # All parameter validation, signature checks, account/path checks, path
    # selection, conflict checks, and publishing flow remain production code.
    $publisherPath = Join-Path $project 'tools\Publish-OpenList.ps1'
    $source = [IO.File]::ReadAllText($publisherPath)
    $source = $source.Replace(". (Join-Path (Split-Path -Parent `$PSScriptRoot) 'stage\update\core.ps1')", ". '" + (Join-Path $project 'stage\update\core.ps1').Replace("'", "''") + "'")
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
    Assert ($parseErrors.Count -eq 0) 'Publisher does not parse.'
    $names = @('Invoke-OpenListJson', 'Read-PublicBytes', 'Test-PublicObject', 'Upload-OpenListFile')
    $functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names }, $true))
    Assert ($functions.Count -eq $names.Count) 'Could not isolate publisher HTTP transport.'
    $mocks = @'
function Invoke-OpenListJson([string]$Method, [string]$Path, $Body, [bool]$Authenticate) {
    $f = $global:ArtemisSentinelFixture
    [void]$f.Calls.Add("$Method $Path")
    if ($Path -eq '/api/auth/login') { return @{code=200; data=@{token='fixture-token'}} }
    if ($Path -eq '/api/me') {
        return @{code=200; data=@{disabled=$false; role=$f.Role; base_path=$f.BasePath; permission=8}}
    }
    if ($Path -eq '/api/fs/get') {
        $p = [string]$Body.path
        [void]$f.MetaPaths.Add($p)
        if ($f.Mode -eq 'Sentinel' -and $p -notin @('/ota','/ota/manifests','/ota/manifests/0.3.6.json','/ota/manifests/0.3.6.sig')) {
            throw 'Sentinel mode inspected an unrelated remote path.'
        }
        if ($f.Directories.ContainsKey($p)) { return @{code=200; data=@{is_dir=$true}} }
        if ($f.Files.ContainsKey($p)) { return @{code=200; data=@{is_dir=$false}} }
        return @{code=500; message='object not found'}
    }
    if ($Path -eq '/api/fs/mkdir') {
        $p = [string]$Body.path
        if ($p -notin @('/ota','/ota/manifests','/ota/objects')) { throw 'Unexpected directory.' }
        if ($f.Mode -eq 'Sentinel' -and $p -eq '/ota/objects') { throw 'Sentinel mode created objects.' }
        $f.Directories[$p] = $true
        return @{code=200}
    }
    throw 'Unexpected API request.'
}
function Read-PublicBytes([string]$RelativePath, [int]$Limit) {
    $f = $global:ArtemisSentinelFixture
    if ($f.Mode -eq 'Sentinel' -and $RelativePath -notin @('manifests/0.3.6.json','manifests/0.3.6.sig')) {
        throw 'Sentinel mode read an unrelated remote file.'
    }
    $p = '/ota/' + $RelativePath
    if (-not $f.Files.ContainsKey($p)) { throw 'Fixture remote file is missing.' }
    $bytes = [byte[]]$f.Files[$p]
    [void]$f.Reads.Add($RelativePath)
    if ($f.FinalReadFailure -and $f.Writes.Count -eq 2) { throw 'Fixture final readback failed.' }
    if ($bytes.Length -gt $Limit) { throw 'Fixture remote file is too large.' }
    return ,$bytes
}
function Upload-OpenListFile([string]$LocalPath, [string]$RemotePath) {
    $f = $global:ArtemisSentinelFixture
    if ($f.Mode -eq 'Sentinel' -and $RemotePath -notin @('/ota/manifests/0.3.6.json','/ota/manifests/0.3.6.sig')) {
        throw 'Sentinel mode wrote an unrelated remote file.'
    }
    if ($f.Mode -eq 'Sentinel' -and $f.Files.ContainsKey($RemotePath)) { throw 'Existing target must not be overwritten.' }
    [void]$f.Writes.Add($RemotePath)
    $bytes = [IO.File]::ReadAllBytes($LocalPath)
    if ($f.CorruptUpload -and $bytes.Length -gt 0) { $bytes[0] = $bytes[0] -bxor 1 }
    $f.Files[$RemotePath] = $bytes
}
function Test-PublicObject([string]$RelativePath, [long]$ExpectedLength, [string]$ExpectedHash) {
    $f = $global:ArtemisSentinelFixture
    $p = '/ota/' + $RelativePath
    if (-not $f.Files.ContainsKey($p)) { throw 'Uploaded fixture file is missing.' }
    $bytes = [byte[]]$f.Files[$p]
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    if ($bytes.Length -ne $ExpectedLength -or $hash -cne $ExpectedHash) { throw 'Uploaded fixture file failed verification.' }
    [void]$f.Verified.Add($p)
}
'@
    foreach ($function in ($functions | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        $replacement = if ($function.Name -eq 'Invoke-OpenListJson') { $mocks } else { '' }
        $source = $source.Substring(0, $function.Extent.StartOffset) + $replacement + $source.Substring($function.Extent.EndOffset)
    }
    $mockPublisher = [scriptblock]::Create($source)
    $credential = New-Object System.Management.Automation.PSCredential('fixture', (ConvertTo-SecureString 'fixture' -AsPlainText -Force))
    function New-FixtureState([string]$Mode) {
        return [pscustomobject]@{
            Mode=$Mode; Files=@{}; Directories=@{'/ota'=$true; '/ota/manifests'=$true; '/ota/objects'=$true}
            Role=0; BasePath='/fixture'; CorruptUpload=$false; FinalReadFailure=$false
            Calls=(New-Object 'System.Collections.Generic.List[string]')
            MetaPaths=(New-Object 'System.Collections.Generic.List[string]')
            Writes=(New-Object 'System.Collections.Generic.List[string]')
            Verified=(New-Object 'System.Collections.Generic.List[string]')
            Reads=(New-Object 'System.Collections.Generic.List[string]')
        }
    }
    function Invoke-FixturePublisher($State, [switch]$NormalUpdate, [switch]$PassSourceInSentinelMode) {
        $global:ArtemisSentinelFixture = $State
        try {
            $argsForPublisher = @{
                Repository=$repository; TargetVersion='0.3.6'; RemoteRoot='/ota'; PublicBase=[Uri]'https://fixture.invalid/d/fixture/ota/'
                Server=[Uri]'https://fixture.invalid'; PublicKeyPath=$publicPath; Credential=$credential
            }
            if ($NormalUpdate) { $argsForPublisher.FromVersion = '0.3.5' }
            else {
                $argsForPublisher.SentinelOnly = $true
                if ($PassSourceInSentinelMode) { $argsForPublisher.FromVersion = '0.3.5' }
            }
            & $mockPublisher @argsForPublisher
        } finally { Remove-Variable -Name ArtemisSentinelFixture -Scope Global -ErrorAction SilentlyContinue }
    }
    $remoteOldJson = [Text.Encoding]::UTF8.GetBytes('untouched remote old manifest')
    $remoteOldSig = [Text.Encoding]::ASCII.GetBytes('untouched remote old signature')
    $state = New-FixtureState 'Sentinel'
    $state.Files['/ota/manifests/0.3.5.json'] = $remoteOldJson
    $state.Files['/ota/manifests/0.3.5.sig'] = $remoteOldSig
    Invoke-FixturePublisher $state
    Assert ($state.Writes.Count -eq 2 -and $state.Verified.Count -eq 2) 'Target marker pair was not uploaded and verified exactly once.'
    Assert (($state.Reads -join ',') -ceq 'manifests/0.3.6.json,manifests/0.3.6.sig') 'Publication did not finally read the complete signed target pair.'
    Assert (Equal-Bytes $state.Files['/ota/manifests/0.3.5.json'] $remoteOldJson) 'Old remote manifest changed.'
    Assert (Equal-Bytes $state.Files['/ota/manifests/0.3.5.sig'] $remoteOldSig) 'Old remote signature changed.'
    Assert ($state.MetaPaths -notcontains '/ota/manifests/0.3.5.json' -and $state.MetaPaths -notcontains '/ota/manifests/0.3.5.sig') 'Old remote paths were inspected.'
    $state.Writes.Clear(); $state.Verified.Clear()
    Invoke-FixturePublisher $state
    Assert ($state.Writes.Count -eq 0) 'Retry wrote an existing identical target.'

    $partial = New-FixtureState 'Sentinel'
    $partial.Files['/ota/manifests/0.3.6.json'] = $targetJson
    Invoke-FixturePublisher $partial
    Assert ($partial.Writes.Count -eq 1 -and $partial.Writes[0] -ceq '/ota/manifests/0.3.6.sig') 'Partial retry should upload only the missing signature.'
    $conflict = New-FixtureState 'Sentinel'
    $conflict.Files['/ota/manifests/0.3.6.sig'] = [Text.Encoding]::ASCII.GetBytes('different signature')
    Assert-Rejected { Invoke-FixturePublisher $conflict } 'A conflicting remote target signature was accepted.'
    Assert ($conflict.Writes.Count -eq 0) 'Conflict preflight allowed a partial upload.'
    $future = New-FixtureState 'Sentinel'
    $future.Files['/ota/manifests/0.3.6.json'] = [Text.Encoding]::UTF8.GetBytes('{"from":"0.3.6","to":"0.3.7"}')
    $future.Files['/ota/manifests/0.3.6.sig'] = [Text.Encoding]::ASCII.GetBytes('other release signature')
    Assert-Rejected { Invoke-FixturePublisher $future } 'A pre-existing future update was accepted for overwrite.'
    Assert ($future.Writes.Count -eq 0) 'A pre-existing future update was overwritten.'
    Assert-Rejected { Invoke-FixturePublisher (New-FixtureState 'Sentinel') -PassSourceInSentinelMode } 'SentinelOnly accepted FromVersion.'
    $admin = New-FixtureState 'Sentinel'; $admin.Role = 1
    Assert-Rejected { Invoke-FixturePublisher $admin } 'A privileged publisher account was accepted.'
    Assert ($admin.Writes.Count -eq 0) 'An invalid account wrote files.'
    $wrongBase = New-FixtureState 'Sentinel'; $wrongBase.BasePath = '/other'
    Assert-Rejected { Invoke-FixturePublisher $wrongBase } 'An incorrectly scoped download base was accepted.'
    Assert ($wrongBase.Writes.Count -eq 0) 'An incorrectly scoped download base allowed writes.'
    $finalFailure = New-FixtureState 'Sentinel'; $finalFailure.FinalReadFailure = $true
    Assert-Rejected { Invoke-FixturePublisher $finalFailure } 'A failure during final complete readback was accepted.'
    $corrupt = New-FixtureState 'Sentinel'; $corrupt.CorruptUpload = $true
    Assert-Rejected { Invoke-FixturePublisher $corrupt } 'A corrupt uploaded target passed readback verification.'
    Assert ($corrupt.Writes.Count -eq 1) 'Readback verification did not stop after the first corrupt upload.'
    $corrupt.CorruptUpload = $false; $corrupt.Writes.Clear()
    Assert-Rejected { Invoke-FixturePublisher $corrupt } 'Retry accepted a corrupt existing target.'
    Assert ($corrupt.Writes.Count -eq 0) 'Retry overwrote a corrupt existing target.'

    [IO.File]::WriteAllText($targetSigPath, 'invalid signature')
    $invalid = New-FixtureState 'Sentinel'
    Assert-Rejected { Invoke-FixturePublisher $invalid } 'An invalid marker signature was accepted.'
    Assert ($invalid.Calls.Count -eq 0 -and $invalid.Writes.Count -eq 0) 'Invalid signature reached the server.'
    [IO.File]::WriteAllBytes($targetSigPath, $targetSig)
    $wrong = [ordered]@{schema=1; product='ArtemisOS-15'; from='0.3.5'; to='0.3.6'; notes=''; files=@()}
    $wrongBytes = [Text.Encoding]::UTF8.GetBytes(($wrong | ConvertTo-Json -Depth 8))
    [IO.File]::WriteAllBytes($targetJsonPath, $wrongBytes)
    [IO.File]::WriteAllText($targetSigPath, [Convert]::ToBase64String($rsa.SignData($wrongBytes, 'SHA256')))
    $wrongState = New-FixtureState 'Sentinel'
    Assert-Rejected { Invoke-FixturePublisher $wrongState } 'An update manifest was accepted as a sentinel.'
    Assert ($wrongState.Calls.Count -eq 0 -and $wrongState.Writes.Count -eq 0) 'Wrong marker reached the server.'
    [IO.File]::WriteAllBytes($targetJsonPath, $targetJson)
    [IO.File]::WriteAllBytes($targetSigPath, $targetSig)

    # Check the pre-existing normal update mode still handles signed updates.
    $objectBytes = [Text.Encoding]::UTF8.GetBytes('new version file')
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $objectHash = [BitConverter]::ToString($sha.ComputeHash($objectBytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    [void][IO.Directory]::CreateDirectory((Join-Path $repository 'objects'))
    [IO.File]::WriteAllBytes((Join-Path $repository "objects\$objectHash"), $objectBytes)
    $update = [ordered]@{schema=1; product='ArtemisOS-15'; from='0.3.5'; to='0.3.6'; notes='fixture';
        files=@([ordered]@{path='version.ini'; base_sha256='-'; sha256=$objectHash; size=$objectBytes.Length})}
    $updateBytes = [Text.Encoding]::UTF8.GetBytes(($update | ConvertTo-Json -Depth 8))
    [IO.File]::WriteAllBytes((Join-Path $repository 'manifests\0.3.5.json'), $updateBytes)
    [IO.File]::WriteAllText((Join-Path $repository 'manifests\0.3.5.sig'), [Convert]::ToBase64String($rsa.SignData($updateBytes, 'SHA256')))
    $oldMarker = [ordered]@{schema=1; product='ArtemisOS-15'; from='0.3.5'; to='0.3.5'; notes=''; files=@()}
    $oldMarkerBytes = [Text.Encoding]::UTF8.GetBytes(($oldMarker | ConvertTo-Json -Depth 8))
    $normal = New-FixtureState 'Update'
    $normal.Files['/ota/manifests/0.3.5.json'] = $oldMarkerBytes
    $normal.Files['/ota/manifests/0.3.5.sig'] = [Text.Encoding]::ASCII.GetBytes([Convert]::ToBase64String($rsa.SignData($oldMarkerBytes, 'SHA256')))
    Invoke-FixturePublisher $normal -NormalUpdate
    Assert ($normal.Writes.Count -eq 5 -and $normal.Verified.Count -eq 5) 'Normal update publication regressed.'
    Assert (Equal-Bytes $normal.Files['/ota/manifests/0.3.5.json'] $updateBytes) 'Normal update source manifest was not published.'
    Write-Host 'Passed: sentinel-only generation, signed upload scope, idempotency, partial retry, conflicts, signature, parameter isolation and normal update regression.'
} finally { $rsa.Dispose() }
