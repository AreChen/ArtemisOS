<# Test the release coordinator against an in-memory OpenList fixture only. #>
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$Backup,
    [Parameter(Mandatory = $true)][string]$BaseRoot,
    [Parameter(Mandatory = $true)][string]$TargetRoot
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop
$project = Split-Path -Parent $PSScriptRoot
$Repository = [IO.Path]::GetFullPath($Repository)
$Backup = [IO.Path]::GetFullPath($Backup)
$BaseRoot = [IO.Path]::GetFullPath($BaseRoot)
$TargetRoot = [IO.Path]::GetFullPath($TargetRoot)
$source = [IO.File]::ReadAllText((Join-Path $project 'tools\Publish-OpenList-ReleaseBridge.ps1'))
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Coordinator did not parse.' }
$names = @('Invoke-OpenListJson','Read-Remote','Upload-RecoverySignature','Publish-Bridge')
$functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names }, $true))
if ($functions.Count -ne $names.Count) { throw 'Cannot isolate the coordinator transports.' }
$mocks = @'
function Invoke-OpenListJson([string]$Method, [string]$Path, $Body, [bool]$Authenticated) {
    $s = $global:ArtemisBridgeFixture
    if ($Path -ceq '/api/auth/login') { return @{code=200; data=@{token='fixture-token'}} }
    if ($Path -ceq '/api/me') { return @{code=200; data=@{disabled=$false;role=$s.Role;base_path='/CLOUD/Footage/EAPIL/Artemis';permission=65528}} }
    if ($Path -clike '/api/share/get*') {
        return @{code=200;data=@{disabled=$false;pwd='';files=@($s.ShareRoot);expires=''}}
    }
    if ($Path -ceq '/api/fs/get') {
        $p = [string]$Body.path
        if (-not $p.StartsWith('/ota/', [StringComparison]::Ordinal)) { throw 'Unexpected fixture get path.' }
        $key = $p.Substring(5)
        if ($s.Files.ContainsKey($key)) { return @{code=200;data=@{is_dir=$false}} }
        return @{code=500;message='object not found'}
    }
    if ($Path -ceq '/api/fs/list') {
        $p = [string]$Body.path
        if ($p -notin @('/ota/manifests','/ota/objects')) { throw 'Unexpected fixture list path.' }
        $prefix = $p.Substring(5) + '/'
        if (-not $s.ListRounds.ContainsKey($p)) { $s.ListRounds[$p] = 0 }
        if ([int]$Body.page -eq 1) { $s.ListRounds[$p]++ }
        $items = @($s.Files.Keys | Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) } | Sort-Object | ForEach-Object {
            $modified = if ($s.ListFault -ceq 'changed-snapshot' -and $s.ListRounds[$p] -gt 1) { 'changed' } else { 'stable' }
            @{name=$_.Substring($prefix.Length);is_dir=$false;size=$s.Files[$_].Length;modified=$modified}
        })
        $total = $items.Count
        $start = ([int]$Body.page - 1) * [int]$Body.per_page
        $pageItems = @($items | Select-Object -Skip $start -First ([int]$Body.per_page))
        if ($s.ListFault -ceq 'unsupported-pagination') { $pageItems = @($items | Select-Object -First ([int]$Body.per_page)) }
        if ($s.ListFault -ceq 'incomplete-page' -and $pageItems.Count -gt 0) { $pageItems = @($pageItems | Select-Object -Skip 1) }
        if ($s.ListFault -ceq 'duplicate-entry' -and [int]$Body.page -eq 2 -and $pageItems.Count -gt 0) { $pageItems[0] = $items[0] }
        if ($s.ListFault -ceq 'changing-total' -and [int]$Body.page -eq 2) { $total++ }
        return @{code=200;data=@{content=$pageItems;total=$total}}
    }
    if ($Path -ceq '/api/fs/remove') {
        if ($Body.dir -cnotin @('/ota/manifests','/ota/objects') -or @($Body.names).Count -ne 1 -or $Body.follow_seed) {
            throw 'Unexpected fixture delete request.'
        }
        $key = $Body.dir.Substring(5) + '/' + $Body.names[0]
        if ($s.FailRemove -ceq $key) { throw 'Simulated delete interruption.' }
        [void]$s.Writes.Add('delete:' + $key)
        [void]$s.Files.Remove($key)
        return @{code=200}
    }
    throw 'Unexpected fixture API request.'
}
function Read-Remote([string]$Relative) {
    $s = $global:ArtemisBridgeFixture
    if (-not $s.Files.ContainsKey($Relative)) { return $null }
    return ,[byte[]]$s.Files[$Relative]
}
function Read-UpdateBytes([Uri]$Uri, [int]$Maximum) {
    $s = $global:ArtemisBridgeFixture
    $m = [regex]::Match($Uri.AbsolutePath, '/(manifests/[^/]+|objects/[^/]+)$')
    if (-not $m.Success -or -not $s.Files.ContainsKey($m.Groups[1].Value)) { throw 'Fixture download missing.' }
    $bytes = [byte[]]$s.Files[$m.Groups[1].Value]
    if ($bytes.Length -gt $Maximum) { throw 'Fixture download too large.' }
    return ,$bytes
}
function Upload-RecoverySignature([string]$LocalPath) {
    $s = $global:ArtemisBridgeFixture
    [void]$s.Writes.Add('recover:manifests/0.3.6.sig')
    $s.Files['manifests/0.3.6.sig'] = [IO.File]::ReadAllBytes($LocalPath)
}
function Publish-Bridge {
    $s = $global:ArtemisBridgeFixture
    [void]$s.Writes.Add('publish:object')
    $s.Files[$s.NewObjectPath] = $s.NewObject
    [void]$s.Writes.Add('publish:json')
    $s.Files['manifests/0.3.6.json'] = $s.NewJson
    if ($s.FailPublish) { throw 'Simulated publication interruption.' }
    [void]$s.Writes.Add('publish:sig')
    $s.Files['manifests/0.3.6.sig'] = $s.NewSig
}
'@
foreach ($function in ($functions | Sort-Object { $_.Extent.StartOffset } -Descending)) {
    $replacement = if ($function.Name -eq 'Invoke-OpenListJson') { $mocks } else { '' }
    $source = $source.Substring(0, $function.Extent.StartOffset) + $replacement + $source.Substring($function.Extent.EndOffset)
}
$source = $source.Replace('$project = Split-Path -Parent $PSScriptRoot', '$project = $global:ArtemisBridgeFixture.Project')
$coordinator = [scriptblock]::Create($source)
$dummySecret = ConvertTo-SecureString 'fixture-only' -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential('fixture', $dummySecret)
$oldObject = '6ed4bbc044d2311cb01c54dea352cc260b694c98f87d30c5703a876bb2aba60c'
$oldPaths = @('manifests/0.3.4.json','manifests/0.3.4.sig','manifests/0.3.5.json',
    'manifests/0.3.5.sig','manifests/0.3.6.json','manifests/0.3.6.sig',('objects/' + $oldObject))
$bridgeJson = [IO.File]::ReadAllBytes((Join-Path $Repository 'manifests\0.3.6.json'))
$bridgeSig = [IO.File]::ReadAllBytes((Join-Path $Repository 'manifests\0.3.6.sig'))
$bridge = [Text.Encoding]::UTF8.GetString($bridgeJson) | ConvertFrom-Json
$objectPath = 'objects/' + $bridge.files[0].sha256
$newObject = [IO.File]::ReadAllBytes((Join-Path $Repository ($objectPath.Replace('/', '\'))))
function New-Fixture {
    $files = @{}
    foreach ($p in $oldPaths) { $files[$p] = [IO.File]::ReadAllBytes((Join-Path $Backup ($p.Replace('/', '\')))) }
    foreach ($p in @('manifests/1.0.0.json','manifests/1.0.0.sig')) {
        $files[$p] = [IO.File]::ReadAllBytes((Join-Path $Repository ($p.Replace('/', '\'))))
    }
    return [pscustomobject]@{ Files=$files; Writes=(New-Object 'System.Collections.Generic.List[string]');
        NewObject=$newObject; NewObjectPath=$objectPath; NewJson=$bridgeJson; NewSig=$bridgeSig;
        FailPublish=$false; FailRemove=''; ShareRoot='/CLOUD/Footage/EAPIL/Artemis/ota'; Role=0; Project=$project;
        ListFault=''; ListRounds=@{} }
}
function Invoke-Fixture($Fixture, [switch]$Apply) {
    $global:ArtemisBridgeFixture = $Fixture
    $argsForCoordinator = @{ Repository=$Repository; Backup=$Backup; BaseRoot=$BaseRoot; TargetRoot=$TargetRoot;
        Credential=$credential; Execute=[bool]$Apply }
    try { & $coordinator @argsForCoordinator }
    finally { Remove-Variable -Name ArtemisBridgeFixture -Scope Global -ErrorAction SilentlyContinue }
}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message }; Write-Host ('PASS: ' + $Message) }
function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    Assert $rejected $Message
}
function Assert-Final($Fixture) {
    foreach ($p in @('manifests/0.3.6.json','manifests/0.3.6.sig','manifests/1.0.0.json','manifests/1.0.0.sig',$objectPath)) {
        if (-not $Fixture.Files.ContainsKey($p)) { throw 'A required final file is missing.' }
    }
    foreach ($p in @('manifests/0.3.4.json','manifests/0.3.4.sig','manifests/0.3.5.json','manifests/0.3.5.sig',('objects/' + $oldObject))) {
        if ($Fixture.Files.ContainsKey($p)) { throw 'An obsolete file remains.' }
    }
}
try {
    $dry = New-Fixture
    Invoke-Fixture $dry
    Assert ($dry.Writes.Count -eq 0) 'Default preflight makes no writes.'

    $normal = New-Fixture
    Invoke-Fixture $normal -Apply
    Assert-Final $normal
    Assert ($normal.Writes.Count -eq 8) 'Normal publication and five exact deletions complete.'
    $normal.Writes.Clear(); Invoke-Fixture $normal -Apply
    Assert ($normal.Writes.Count -eq 0) 'A completed operation is idempotent.'

    $interrupted = New-Fixture; $interrupted.FailPublish = $true
    Assert-Rejected { Invoke-Fixture $interrupted -Apply } 'Interruption after new JSON stops the operation.'
    Assert ($interrupted.Files.ContainsKey('manifests/0.3.4.json')) 'Interrupted publication retains old files.'
    $interrupted.FailPublish = $false; $interrupted.Writes.Clear()
    Invoke-Fixture $interrupted -Apply
    Assert-Final $interrupted
    Assert ($interrupted.Writes[0] -ceq 'recover:manifests/0.3.6.sig') 'Exact partial state repairs only the signature first.'

    $deletePartial = New-Fixture; $deletePartial.FailRemove = 'manifests/0.3.5.json'
    Assert-Rejected { Invoke-Fixture $deletePartial -Apply } 'A deletion failure stops the operation.'
    $deletePartial.FailRemove = ''; $deletePartial.Writes.Clear()
    Invoke-Fixture $deletePartial -Apply
    Assert-Final $deletePartial
    Assert ($deletePartial.Writes.Count -eq 3) 'A partial cleanup resumes remaining exact deletions.'

    $tampered = New-Fixture; $tampered.Files['manifests/0.3.4.json'] = [byte[]](1,2,3)
    Assert-Rejected { Invoke-Fixture $tampered -Apply } 'Changed old files stop publication.'
    Assert ($tampered.Writes.Count -eq 0) 'Changed old files caused no writes.'
    $unknown = New-Fixture; $unknown.Files['manifests/other.json'] = [byte[]](1)
    Assert-Rejected { Invoke-Fixture $unknown -Apply } 'Unknown remote files stop publication.'
    Assert ($unknown.Writes.Count -eq 0) 'Unknown remote files caused no writes.'
    foreach ($fault in @('unsupported-pagination','incomplete-page','duplicate-entry','changing-total','changed-snapshot')) {
        $inventoryFault = New-Fixture; $inventoryFault.ListFault = $fault
        Assert-Rejected { Invoke-Fixture $inventoryFault -Apply } ('Invalid inventory is rejected: ' + $fault)
        Assert ($inventoryFault.Writes.Count -eq 0) ('Invalid inventory causes no writes: ' + $fault)
    }
    $scope = New-Fixture; $scope.ShareRoot = '/CLOUD/Footage/EAPIL/other'
    Assert-Rejected { Invoke-Fixture $scope -Apply } 'A changed share scope stops publication.'
    Assert ($scope.Writes.Count -eq 0) 'A changed share scope caused no writes.'
    $admin = New-Fixture; $admin.Role = 1
    Assert-Rejected { Invoke-Fixture $admin -Apply } 'A privileged publishing account is rejected.'
    Assert ($admin.Writes.Count -eq 0) 'A privileged publishing account caused no writes.'
    $targetBad = New-Fixture; $targetBad.Files['manifests/1.0.0.json'] = [byte[]](7)
    Assert-Rejected { Invoke-Fixture $targetBad -Apply } 'A changed target marker stops publication.'
    Assert ($targetBad.Writes.Count -eq 0) 'A changed target marker caused no writes.'
    $objectBad = New-Fixture; $objectBad.Files[$objectPath] = [byte[]](5)
    Assert-Rejected { Invoke-Fixture $objectBad -Apply } 'A changed update object stops publication.'
    Assert ($objectBad.Writes.Count -eq 0) 'A changed update object caused no writes.'
    $partialBad = New-Fixture; $partialBad.Files['manifests/0.3.6.json'] = $bridgeJson
    $partialBad.Files['manifests/0.3.6.sig'] = [byte[]](9); $partialBad.Files[$objectPath] = $newObject
    Assert-Rejected { Invoke-Fixture $partialBad -Apply } 'An unrecognized partial pair is rejected.'
    Assert ($partialBad.Writes.Count -eq 0) 'An unrecognized partial pair caused no writes.'
    $partialMissing = New-Fixture; $partialMissing.Files['manifests/0.3.6.json'] = $bridgeJson
    Assert-Rejected { Invoke-Fixture $partialMissing -Apply } 'A partial pair with a missing object is rejected.'
    Assert ($partialMissing.Writes.Count -eq 0) 'A partial pair with a missing object caused no writes.'
} finally {
    $credential = $null; $dummySecret = $null
    Remove-Variable -Name ArtemisBridgeFixture -Scope Global -ErrorAction SilentlyContinue
}
