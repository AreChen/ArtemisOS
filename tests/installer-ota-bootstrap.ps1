param([string]$Compiler = (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'))
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$project = Split-Path -Parent $PSScriptRoot
$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$work = Join-Path $parent ('artemisos-bootstrap-fixture-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
[IO.File]::WriteAllText((Join-Path $work '.fixture-only'), 'fixture')
$serverJob = $null
$ascii = [Text.Encoding]::ASCII
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    Write-Host "PASS: $Message"
}
function Put([string]$Path, [string]$Value) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Value, $ascii)
}
function Record([string]$Path, [string]$Id) {
    return [pscustomobject]@{ Hive='CurrentUser'; View='Registry64'; AppId=$Id; InstallLocation=$Path; AppPath=$Path;
        UninstallString=('"' + (Join-Path $Path 'unins000.exe') + '"') }
}
function Registrations([object[]]$Rows) {
    [IO.File]::WriteAllText((Join-Path $work 'registry.json'), (ConvertTo-Json -InputObject @($Rows) -Depth 5), $ascii)
}
function Invoke-Boot([string]$Action, [string]$Path = '') {
    $argsForTest = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',
        (Join-Path $project 'tools\Invoke-OtaBootstrapFixture.ps1'),'-FixtureRoot',$work,'-Action',$Action)
    if ($Path) { $argsForTest += @('-ExplicitPath',$Path) }
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & rtk proxy powershell.exe @argsForTest 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    return [pscustomobject]@{ Code=$code; Output=$output }
}
function New-Install([string]$Name, [string]$Version) {
    $root = Join-Path $work $Name
    [void][IO.Directory]::CreateDirectory($root)
    Copy-Item -LiteralPath (Join-Path $project 'stage\update') -Destination (Join-Path $root 'update') -Recurse
    # Isolated fixture: exercise the real OTA transaction except for the
    # registration callback, which is disabled to prohibit real registry access.
    $applyPath = Join-Path $root 'update\apply.ps1'
    $apply = [IO.File]::ReadAllText($applyPath)
    $call = "        Sync-WindowsAppRegistration `$root `$manifest.to 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'"
    if (-not $apply.Contains($call)) { throw 'Cannot isolate the OTA registry callback.' }
    $apply = $apply.Replace($call, '        # Fixture: no access to real registry.')
    [IO.File]::WriteAllText($applyPath, $apply, [Text.UTF8Encoding]::new($true))
    Put (Join-Path $root 'version.ini') "[ArtemisOS]`nVersion=$Version`n"
    Put (Join-Path $root 'launch.ps1') 'old launcher'
    Put (Join-Path $root 'settings.ps1') 'old settings'
    Put (Join-Path $root 'sdk\emulator\emulator.exe') 'old runtime'
    Put (Join-Path $root 'sdk\system-images\android-35\google_apis\x86_64\system.img') 'old system image'
    Put (Join-Path $root 'unins000.exe') 'fixture uninstall program'
    Put (Join-Path $root 'unins000.dat') 'fixture uninstall log'
    Put (Join-Path $root 'data\preferences.ini') "profile=high`nunknown=keep`n"
    Put (Join-Path $root 'data\avd\userdata.img') 'fixture user data'
    return $root
}
try {
    $base = New-Install 'installed' '1.0.0'
    $target = Join-Path $work 'target-release'
    Copy-Item -LiteralPath $base -Destination $target -Recurse
    Put (Join-Path $target 'version.ini') "[ArtemisOS]`nVersion=1.0.1`n"
    [IO.File]::AppendAllText((Join-Path $target 'update\apply.ps1'), "`r`n# fixture target updater`r`n", [Text.UTF8Encoding]::new($false))
    $keys = Join-Path $work 'keys'
    $repository = Join-Path $work 'repository'
    [void][IO.Directory]::CreateDirectory($keys)
    Add-Type -AssemblyName System.Security
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(2048)
    $rsa.PersistKeyInCsp = $false
    try {
        $public = $rsa.ToXmlString($false)
        $private = [Text.Encoding]::UTF8.GetBytes($rsa.ToXmlString($true))
        $protected = [Security.Cryptography.ProtectedData]::Protect($private, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        [IO.File]::WriteAllBytes((Join-Path $keys 'ota-private.dpapi'), $protected)
        foreach ($dir in @($base,$target)) { Put (Join-Path $dir 'update\trusted-key.xml') $public }
    } finally { $rsa.Dispose(); if ($private) { [Array]::Clear($private, 0, $private.Length) } }
    $inventoryDir = Join-Path $work 'generated-inventories'
    & (Join-Path $project 'tools\New-OtaBootstrapInventories.ps1') -BaselineRoot $base -TargetRoot $target -FromVersion '1.0.0' -ToVersion '1.0.1' -OutputDirectory $inventoryDir
    Copy-Item -LiteralPath (Join-Path $inventoryDir 'baseline.json') -Destination (Join-Path $work 'baseline.json')
    Copy-Item -LiteralPath (Join-Path $inventoryDir 'target.json') -Destination (Join-Path $work 'target.json')
    foreach ($scenario in @('recovery','added','deleted')) {
        $invalidSnapshot = Join-Path $work ('invalid-snapshot-' + $scenario)
        Copy-Item -LiteralPath $target -Destination $invalidSnapshot -Recurse
        switch ($scenario) {
            'recovery' { [IO.File]::AppendAllText((Join-Path $invalidSnapshot 'update\recovery.ps1'), "`r`n# unsupported change`r`n") }
            'added' { Put (Join-Path $invalidSnapshot 'unexpected.txt') 'unsupported addition' }
            'deleted' { Remove-Item -LiteralPath (Join-Path $invalidSnapshot 'launch.ps1') }
        }
        $blocked = $false
        try {
            & (Join-Path $project 'tools\New-OtaBootstrapInventories.ps1') -BaselineRoot $base -TargetRoot $invalidSnapshot -FromVersion '1.0.0' -ToVersion '1.0.1' -OutputDirectory (Join-Path $work ('invalid-inventory-' + $scenario))
        } catch { $blocked = $true }
        Assert $blocked "inventory generation rejects $scenario"
    }
    & (Join-Path $project 'tools\Publish-Update.ps1') -BaseRoot $base -TargetRoot $target -Repository $repository -KeyDirectory $keys -IncludeSdk
    $portFile = Join-Path $work 'port'
    $stopFile = Join-Path $work 'stop'
    $serverJob = Start-Job -ArgumentList $repository, $portFile, $stopFile -ScriptBlock {
        param($repo, $portFile, $stopFile)
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            [IO.File]::WriteAllText($portFile, [string]([Net.IPEndPoint]$listener.LocalEndpoint).Port)
            while (-not [IO.File]::Exists($stopFile)) {
                if (-not $listener.Pending()) { Start-Sleep -Milliseconds 40; continue }
                $client = $listener.AcceptTcpClient()
                $stream = $client.GetStream()
                $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 4096, $true)
                try {
                    $line = $reader.ReadLine()
                    while (($header = $reader.ReadLine()) -and $header.Length -gt 0) { }
                    $file = $null
                    if ($line -match '^GET /(manifests/\d+\.\d+\.\d+\.(json|sig)|objects/[0-9a-f]{64}) HTTP/1\.[01]$') {
                        $file = Join-Path $repo $matches[1].Replace('/','\')
                    }
                    $ok = $file -and [IO.File]::Exists($file)
                    $bytes = if ($ok) { [IO.File]::ReadAllBytes($file) } else { [byte[]]@() }
                    $status = if ($ok) { '200 OK' } else { '404 Not Found' }
                    $headerBytes = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
                    $stream.Write($headerBytes, 0, $headerBytes.Length)
                    if ($bytes.Length) { $stream.Write($bytes, 0, $bytes.Length) }
                    $stream.Flush()
                } finally { $reader.Dispose(); $stream.Dispose(); $client.Dispose() }
            }
        } finally { $listener.Stop() }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath $portFile) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $portFile)) { throw 'Fixture server did not start.' }
    Put (Join-Path $base 'data\update\server.txt') ('http://127.0.0.1:' + [IO.File]::ReadAllText($portFile) + '/')
    $wrapperFixture = Join-Path $work 'wrapper-fixture'
    Copy-Item -LiteralPath $base -Destination $wrapperFixture -Recurse
    $productionFixture = Join-Path $work 'production-fixture'
    Copy-Item -LiteralPath $base -Destination $productionFixture -Recurse
    $migrationBackup = Join-Path $productionFixture ('.data-fresh-before-migration-' + [Guid]::NewGuid().ToString('N') + '\userdata.img')
    Put $migrationBackup 'retained migration data'
    Copy-Item -LiteralPath (Join-Path $project 'tools\ArtemisInstallDiscovery.psm1') -Destination (Join-Path $work 'ArtemisInstallDiscovery.psm1')
    $productionCode = [IO.File]::ReadAllText((Join-Path $project 'tools\Invoke-OtaBootstrap.ps1'))
    # Replace only the real-registry seams in this test copy. The production
    # baseline validation, signature, staging, mutex and apply paths stay intact.
    $registrationPattern = '(?ms)^function Get-Registration\(\[string\]\$InstallRoot\) \{.*?^\}'
    $beforeSubstitution = $productionCode
    $productionCode = [regex]::Replace($productionCode, $registrationPattern,
        'function Get-Registration([string]$InstallRoot) { return (Get-ArtemisProductInfo $InstallRoot).Path }')
    $registrationRead = '        $displayVersion = (Get-ItemProperty -LiteralPath $registryPath -Name DisplayVersion -ErrorAction Stop).DisplayVersion'
    if (-not $productionCode.Contains($registrationRead) -or $productionCode -ceq $beforeSubstitution) {
        throw 'Could not isolate the production fixture registration seams.'
    }
    $productionCode = $productionCode.Replace($registrationRead, "        `$displayVersion = '1.0.1'")
    $productionScript = Join-Path $work 'production.ps1'
    [IO.File]::WriteAllText($productionScript, $productionCode, [Text.UTF8Encoding]::new($true))
    $productionDisk = (Get-FileHash -LiteralPath (Join-Path $productionFixture 'data\avd\userdata.img')).Hash
    $productionPrefs = (Get-FileHash -LiteralPath (Join-Path $productionFixture 'data\preferences.ini')).Hash
    $productionUnins = (Get-FileHash -LiteralPath (Join-Path $productionFixture 'unins000.dat')).Hash
    $processMock = @'
function Get-CimInstance {
    param($ClassName, $Filter, $ErrorAction)
    if ($Filter -notmatch "Name='qemu-system-x86_64-headless.exe'") { return }
    if ($env:ARTEMIS_FIXTURE_PROCESS_MODE -eq 'unreadable') {
        return [pscustomobject]@{ExecutablePath=$null}
    }
    return [pscustomobject]@{ExecutablePath=(Join-Path $env:ARTEMIS_FIXTURE_PROCESS_ROOT 'sdk\emulator\qemu\windows-x86_64\qemu-system-x86_64-headless.exe')}
}
'@
    $entry = "try {`n    if (`$FromVersion -notmatch"
    if (-not $productionCode.Contains($entry)) { throw 'Could not isolate process detection test.' }
    $blockedScript = Join-Path $work 'production-process-test.ps1'
    [IO.File]::WriteAllText($blockedScript, $productionCode.Replace($entry, ($processMock + "`n" + $entry)), [Text.UTF8Encoding]::new($true))
    $env:ARTEMIS_FIXTURE_PROCESS_ROOT = $productionFixture
    foreach ($mode in @('headless','unreadable')) {
        $env:ARTEMIS_FIXTURE_PROCESS_MODE = $mode
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $processOutput = & rtk proxy powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $blockedScript -Target $productionFixture -BaselineInventory (Join-Path $work 'baseline.json') -TargetInventory (Join-Path $work 'target.json') -FromVersion '1.0.0' -ToVersion '1.0.1' 2>&1 | Out-String
            $processCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousPreference }
        Assert ($processCode -ne 0 -and [IO.File]::ReadAllText((Join-Path $productionFixture 'version.ini')) -match 'Version=1\.0\.0') "production candidate blocks fixture process: $mode"
    }
    Remove-Item Env:ARTEMIS_FIXTURE_PROCESS_MODE, Env:ARTEMIS_FIXTURE_PROCESS_ROOT
    $outside = Join-Path $work 'outside-update'
    Put (Join-Path $outside 'sentinel.txt') 'outside must remain unchanged'
    $junction = Join-Path $productionFixture 'data\update\pending'
    [void](New-Item -ItemType Junction -Path $junction -Target $outside)
    try {
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $junctionOutput = & rtk proxy powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $productionScript -Target $productionFixture -BaselineInventory (Join-Path $work 'baseline.json') -TargetInventory (Join-Path $work 'target.json') -FromVersion '1.0.0' -ToVersion '1.0.1' 2>&1 | Out-String
            $junctionCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousPreference }
        Assert ($junctionCode -ne 0 -and [IO.File]::ReadAllText((Join-Path $outside 'sentinel.txt')) -ceq 'outside must remain unchanged' -and
            [IO.File]::ReadAllText((Join-Path $productionFixture 'version.ini')) -match 'Version=1\.0\.0') 'a junction in update state is rejected without touching its external target'
    } finally {
        $link = Get-Item -LiteralPath $junction -Force
        if (-not ($link.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Expected test junction is not a reparse point.' }
        [IO.Directory]::Delete($junction)
    }
    foreach ($scenario in @('recovery','added','deleted','substitution','unmatched-manifest','wrong-target-hash','wrong-version')) {
        $rows = [IO.File]::ReadAllText((Join-Path $work 'target.json')) | ConvertFrom-Json
        $rows = @($rows)
        $testVersion = '1.0.1'
        switch ($scenario) {
            'recovery' { $row = $rows | Where-Object { $_.path -ieq 'update/recovery.ps1' }; $row.sha256 = ('0' * 64) }
            'added' { $rows += [pscustomobject]@{path='extra.txt';sha256=('0' * 64)} }
            'deleted' { $rows = @($rows | Where-Object { $_.path -ine 'launch.ps1' }) }
            'substitution' {
                $rows = @($rows | Where-Object { $_.path -ine 'launch.ps1' })
                $rows += [pscustomobject]@{path='extra.txt';sha256=('0' * 64)}
            }
            'unmatched-manifest' { $row = $rows | Where-Object { $_.path -ieq 'launch.ps1' }; $row.sha256 = ('0' * 64) }
            'wrong-target-hash' { $row = $rows | Where-Object { $_.path -ieq 'update/apply.ps1' }; $row.sha256 = ('0' * 64) }
            'wrong-version' { $testVersion = '1.0.2' }
        }
        $invalidInventory = Join-Path $work ('invalid-target-' + $scenario + '.json')
        [IO.File]::WriteAllText($invalidInventory, (ConvertTo-Json -InputObject $rows -Depth 5), [Text.UTF8Encoding]::new($true))
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $invalidOutput = & rtk proxy powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $productionScript -Target $productionFixture -BaselineInventory (Join-Path $work 'baseline.json') -TargetInventory $invalidInventory -FromVersion '1.0.0' -ToVersion $testVersion 2>&1 | Out-String
            $invalidCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousPreference }
        Assert ($invalidCode -ne 0 -and [IO.File]::ReadAllText((Join-Path $productionFixture 'version.ini')) -match 'Version=1\.0\.0' -and
            (Get-FileHash -LiteralPath (Join-Path $productionFixture 'data\avd\userdata.img')).Hash -eq $productionDisk -and
            (Get-FileHash -LiteralPath (Join-Path $productionFixture 'data\preferences.ini')).Hash -eq $productionPrefs -and
            (Get-FileHash -LiteralPath (Join-Path $productionFixture 'unins000.dat')).Hash -eq $productionUnins) "bootstrap refuses $scenario without modifying fixture data"
    }
    # Forge a different, *validly signed* fixture manifest with a wrong source
    # hash. This must reach the signed-versus-pinned comparison and stop there.
    $manifestPath = Join-Path $repository 'manifests\1.0.0.json'
    $signaturePath = Join-Path $repository 'manifests\1.0.0.sig'
    $originalManifest = [IO.File]::ReadAllBytes($manifestPath)
    $originalSignature = [IO.File]::ReadAllBytes($signaturePath)
    $badResultFile = Join-Path $work 'bad-signature-source-hash-result.txt'
    try {
        $manifest = [Text.Encoding]::UTF8.GetString($originalManifest) | ConvertFrom-Json
        $row = $manifest.files | Where-Object { $_.path -ieq 'update/apply.ps1' }
        if ($null -eq $row) { throw 'Signed fixture lacks the expected file.' }
        $row.base_sha256 = '0' * 64
        $badBytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $manifest -Depth 8))
        $private = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes((Join-Path $keys 'ota-private.dpapi')), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        $signer = New-Object Security.Cryptography.RSACryptoServiceProvider
        $signer.PersistKeyInCsp = $false
        try {
            $signer.FromXmlString([Text.Encoding]::UTF8.GetString($private))
            $badSignature = $signer.SignData($badBytes, 'SHA256')
        } finally { $signer.Dispose(); [Array]::Clear($private, 0, $private.Length) }
        [IO.File]::WriteAllBytes($manifestPath, $badBytes)
        [IO.File]::WriteAllText($signaturePath, [Convert]::ToBase64String($badSignature), $ascii)
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $invalidOutput = & rtk proxy powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $productionScript -Target $productionFixture -BaselineInventory (Join-Path $work 'baseline.json') -TargetInventory (Join-Path $work 'target.json') -FromVersion '1.0.0' -ToVersion '1.0.1' -ResultFile $badResultFile 2>&1 | Out-String
            $invalidCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousPreference }
        $expectedReason = -join @((0x7b7e,0x540d,0x66f4,0x65b0,0x4e0e,0x53d1,0x884c,0x6e05,0x5355,0x4e0d,0x4e00,0x81f4) | ForEach-Object { [char]$_ })
        Assert ($invalidCode -ne 0 -and [IO.File]::ReadAllText($badResultFile, [Text.Encoding]::UTF8).Contains($expectedReason) -and
            [IO.File]::ReadAllText((Join-Path $productionFixture 'version.ini')) -match 'Version=1\.0\.0' -and
            (Get-FileHash -LiteralPath (Join-Path $productionFixture 'data\avd\userdata.img')).Hash -eq $productionDisk) 'a validly signed manifest with an incorrect source hash is rejected'
    } finally {
        [IO.File]::WriteAllBytes($manifestPath, $originalManifest)
        [IO.File]::WriteAllBytes($signaturePath, $originalSignature)
    }
    $productionResult = & rtk proxy powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $productionScript -Target $productionFixture -BaselineInventory (Join-Path $work 'baseline.json') -TargetInventory (Join-Path $work 'target.json') -FromVersion '1.0.0' -ToVersion '1.0.1' 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw ('Production candidate failed in isolated fixture: ' + $productionResult) }
    Assert ([IO.File]::ReadAllText((Join-Path $productionFixture 'version.ini')) -match 'Version=1\.0\.1' -and
        (Get-FileHash -LiteralPath (Join-Path $productionFixture 'data\avd\userdata.img')).Hash -eq $productionDisk -and
        (Get-FileHash -LiteralPath (Join-Path $productionFixture 'data\preferences.ini')).Hash -eq $productionPrefs -and
        (Get-FileHash -LiteralPath (Join-Path $productionFixture 'unins000.dat')).Hash -eq $productionUnins -and
        [IO.File]::ReadAllText($migrationBackup) -ceq 'retained migration data') 'production candidate validates and applies the signed fixture while preserving data, migration backup and uninstall log'
    # Compile the actual bootstrap with isolated discovery and registration
    # seams, then execute it against the same real signed fixture repository.
    if (-not (Test-Path -LiteralPath $Compiler -PathType Leaf)) { throw 'Inno compiler is required for wrapper testing.' }
    $fixtureTools = Join-Path $work 'fixture-tools'
    [void][IO.Directory]::CreateDirectory($fixtureTools)
    Copy-Item -LiteralPath (Join-Path $project 'tools\ArtemisInstallDiscovery.psm1') -Destination (Join-Path $fixtureTools 'ArtemisInstallDiscovery.psm1')
    Copy-Item -LiteralPath $productionScript -Destination (Join-Path $fixtureTools 'Invoke-OtaBootstrap.ps1')
    $discoverSource = [IO.File]::ReadAllText((Join-Path $project 'tools\Find-ArtemisInstallations.ps1'))
    $registryLine = '$registry = Get-ArtemisRegistryRegistrations'
    if (-not $discoverSource.Contains($registryLine)) { throw 'Cannot isolate wrapper discovery.' }
    $mock = @'
$fixtureRoot = [IO.Path]::GetFullPath($env:ARTEMIS_BOOTSTRAP_FIXTURE_ROOT).TrimEnd('\')
if ((Split-Path -Leaf $fixtureRoot) -cnotmatch '^artemisos-bootstrap-fixture-[0-9a-f]{32}$' -or
    -not [IO.File]::Exists((Join-Path $fixtureRoot '.fixture-only'))) { throw 'Invalid test fixture.' }
$parsed = [IO.File]::ReadAllText((Join-Path $fixtureRoot 'registry.json')) | ConvertFrom-Json
$records = @(); foreach ($record in $parsed) { if ($null -ne $record) { $records += $record } }
$registry = [pscustomobject]@{Records=$records;Issues=@()}
'@
    $discoverSource = $discoverSource.Replace($registryLine, $mock)
    [IO.File]::WriteAllText((Join-Path $fixtureTools 'Find-ArtemisInstallations.ps1'), $discoverSource, [Text.UTF8Encoding]::new($true))
    $inner = @'
[Setup]
AppName=Fixture fresh package
AppVersion=1.0
DefaultDirName={tmp}\fresh-child
DisableWelcomePage=yes
DisableDirPage=yes
DisableReadyPage=yes
DisableFinishedPage=yes
PrivilegesRequired=lowest
Uninstallable=no
CreateUninstallRegKey=no
Compression=none
OutputBaseFilename=fixture-fresh
[Code]
procedure CurStepChanged(Step: TSetupStep);
begin
  if Step = ssPostInstall then SaveStringToFile(ExpandConstant('{app}\fresh-ran.txt'), 'fixture', False);
end;
'@
    [IO.File]::WriteAllText((Join-Path $work 'fresh.iss'), $inner, $ascii)
    & rtk proxy $Compiler ("/O$work") (Join-Path $work 'fresh.iss') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot compile nested fixture.' }
    & rtk proxy $Compiler ("/O$work") '/Ffixture-bootstrap' ("/DFreshInstaller=$work\fixture-fresh.exe") `
        ("/DBaselineInventory=$work\baseline.json") ("/DTargetInventory=$work\target.json") `
        ("/DDiscoveryModule=$fixtureTools\ArtemisInstallDiscovery.psm1") ("/DDiscoverySource=$fixtureTools\Find-ArtemisInstallations.ps1") `
        ("/DBootstrapSource=$fixtureTools\Invoke-OtaBootstrap.ps1") '/DArtemisBootstrapExperimental' '/DBootstrapFromVersion=1.0.0' '/DBootstrapToVersion=1.0.1' (Join-Path $project 'installer-ota-bootstrap.iss') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot compile bootstrap fixture.' }
    $env:ARTEMIS_BOOTSTRAP_FIXTURE_ROOT = $work
    $wrapper = Join-Path $work 'fixture-bootstrap.exe'
    Registrations @((Record $wrapperFixture 'ArtemisOS15-Release'))
    $wrapperLog = Join-Path $work 'wrapper-upgrade.log'
    $wrapperPrefs = (Get-FileHash -LiteralPath (Join-Path $wrapperFixture 'data\preferences.ini')).Hash
    $wrapperUnins = (Get-FileHash -LiteralPath (Join-Path $wrapperFixture 'unins000.dat')).Hash
    & rtk proxy $wrapper /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- ("/DIR=$wrapperFixture") ("/LOG=$wrapperLog")
    if ($LASTEXITCODE -ne 0) { throw ('Wrapper upgrade failed, code ' + $LASTEXITCODE + ': ' + [IO.File]::ReadAllText($wrapperLog)) }
    Assert ([IO.File]::ReadAllText((Join-Path $wrapperFixture 'version.ini')) -match 'Version=1\.0\.1' -and
        (Get-FileHash -LiteralPath (Join-Path $wrapperFixture 'data\preferences.ini')).Hash -eq $wrapperPrefs -and
        (Get-FileHash -LiteralPath (Join-Path $wrapperFixture 'unins000.dat')).Hash -eq $wrapperUnins -and
        [IO.File]::ReadAllText($wrapperLog) -notmatch 'Extracting temporary file: .*fixture-fresh\.exe') 'installer bootstrap applies signed OTA without releasing the fresh package or touching data and uninstall log'
    $other = Join-Path $work 'wrapper-other'
    Copy-Item -LiteralPath $base -Destination $other -Recurse
    Put (Join-Path $other 'version.ini') "[ArtemisOS]`nVersion=0.3.5`n"
    Registrations @((Record $base 'ArtemisOS15-Release'),(Record $other '{E49344F1-069E-4DA4-A5B7-232C0BE325A8}'))
    & rtk proxy $wrapper /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-
    Assert ($LASTEXITCODE -ne 0 -and [IO.File]::ReadAllText((Join-Path $base 'version.ini')) -match 'Version=1\.0\.0') 'silent bootstrap refuses multiple installations without /DIR'
    $silent = Start-Process -FilePath $wrapper -ArgumentList @('/SILENT','/NORESTART','/SP-') -WindowStyle Hidden -PassThru
    if (-not $silent.WaitForExit(25000)) {
        $silent.Kill(); $silent.WaitForExit()
        throw 'Silent bootstrap blocked waiting for a dialog.'
    }
    Assert ($silent.ExitCode -ne 0) 'SILENT without SUPPRESSMSGBOXES exits without a dialog for multiple installations'
    & rtk proxy $wrapper /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- ("/DIR=$other")
    Assert ($LASTEXITCODE -ne 0 -and [IO.File]::ReadAllText((Join-Path $other 'version.ini')) -match 'Version=0\.3\.5') 'bootstrap refuses an unsupported selected version'
    $offline = Join-Path $work 'wrapper-offline'
    Copy-Item -LiteralPath $base -Destination $offline -Recurse
    Put (Join-Path $offline 'data\update\server.txt') 'http://127.0.0.1:1/'
    Registrations @((Record $offline 'ArtemisOS15-Release'))
    & rtk proxy $wrapper /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- ("/DIR=$offline")
    Assert ($LASTEXITCODE -ne 0 -and [IO.File]::ReadAllText((Join-Path $offline 'version.ini')) -match 'Version=1\.0\.0' -and
        [IO.File]::ReadAllText((Join-Path $offline 'data\avd\userdata.img')) -ceq 'fixture user data') 'offline bootstrap stops without changing the installed version or data'
    Registrations @()
    $freshTarget = Join-Path $work 'fresh-selected'
    & rtk proxy $wrapper /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- ("/DIR=$freshTarget")
    Assert ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $freshTarget 'fresh-ran.txt'))) 'installer bootstrap extracts and runs the nested package on a fresh install'
    Remove-Item Env:ARTEMIS_BOOTSTRAP_FIXTURE_ROOT
    $record = Record $base 'ArtemisOS15-Release'
    Registrations @()
    $first = Invoke-Boot 'Plan'
    if ($first.Code -ne 0) { throw ('Fresh plan failed: ' + $first.Output) }
    Assert ($first.Output.Trim() -ceq 'fresh') 'no registration chooses the fresh branch'
    Registrations @($record)
    Assert ((Invoke-Boot 'Plan').Output.Trim() -ceq ('selected=' + $base)) 'one registered installation is selected'
    $second = New-Install 'older' '0.3.5'
    $secondRecord = Record $second '{E49344F1-069E-4DA4-A5B7-232C0BE325A8}'
    Registrations @($record,$secondRecord)
    Assert ((Invoke-Boot 'Plan').Code -ne 0) 'multiple registrations do not select an arbitrary installation'
    Assert ((Invoke-Boot 'Plan' $base).Code -eq 0) 'an explicit fixture directory selects the intended installation'
    Assert ((Invoke-Boot 'Plan' $second).Code -ne 0) 'unsupported 0.3.5 is refused'
    Registrations @($record)
    $beforePrefs = (Get-FileHash -LiteralPath (Join-Path $base 'data\preferences.ini')).Hash
    $beforeDisk = (Get-FileHash -LiteralPath (Join-Path $base 'data\avd\userdata.img')).Hash
    Put (Join-Path $work 'running.flag') '1'
    Assert ((Invoke-Boot 'Apply').Code -ne 0) 'a running fixture emulator blocks the upgrade'
    Remove-Item -LiteralPath (Join-Path $work 'running.flag')
    Put (Join-Path $base 'launch.ps1') 'tampered'
    Assert ((Invoke-Boot 'Apply').Code -ne 0) 'a modified baseline is rejected'
    Put (Join-Path $base 'launch.ps1') 'old launcher'
    $signature = Join-Path $repository 'manifests\1.0.0.sig'
    $savedSignature = [IO.File]::ReadAllBytes($signature)
    Put $signature ([Convert]::ToBase64String((New-Object byte[] 256)))
    Assert ((Invoke-Boot 'Apply').Code -ne 0) 'an invalid signature is rejected'
    [IO.File]::WriteAllBytes($signature, $savedSignature)
    $r = Invoke-Boot 'Apply'
    if ($r.Code -ne 0) { throw ('Valid signed fixture OTA failed: ' + $r.Output) }
    Assert ([IO.File]::ReadAllText((Join-Path $base 'version.ini')) -match 'Version=1\.0\.1' -and
        [IO.File]::ReadAllText((Join-Path $base 'launch.ps1')) -ceq 'old launcher') 'a signed OTA updates an exact baseline to the pinned target'
    Assert ((Get-FileHash -LiteralPath (Join-Path $base 'data\preferences.ini')).Hash -eq $beforePrefs -and
        (Get-FileHash -LiteralPath (Join-Path $base 'data\avd\userdata.img')).Hash -eq $beforeDisk) 'the signed OTA preserves fixture user data and preferences'
} finally {
    Remove-Item Env:ARTEMIS_BOOTSTRAP_FIXTURE_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:ARTEMIS_FIXTURE_PROCESS_MODE, Env:ARTEMIS_FIXTURE_PROCESS_ROOT -ErrorAction SilentlyContinue
    if ($serverJob) {
        [IO.File]::WriteAllText((Join-Path $work 'stop'), '1')
        Wait-Job -Job $serverJob -Timeout 10 | Out-Null
        if ($serverJob.State -eq 'Running') { Stop-Job -Job $serverJob }
        Remove-Job -Job $serverJob -Force
    }
    if (Test-Path -LiteralPath $work) {
        $item = Get-Item -LiteralPath $work -Force
        if ($item.Parent.FullName.TrimEnd('\') -ine $parent -or $item.Name -cnotmatch '^artemisos-bootstrap-fixture-[0-9a-f]{32}$' -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe fixture cleanup.' }
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
