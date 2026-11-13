param([string]$Repository)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Management\Microsoft.PowerShell.Management.psd1') -ErrorAction Stop
$project = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
if (-not $Repository) { $Repository = Join-Path $project 'build\ota-1.0.5-intel-vulkan\repository' }
$Repository = (Resolve-Path -LiteralPath $Repository).ProviderPath.TrimEnd('\')
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$oldCoreHash = '3a0d3ed7fe46c9870b849f8c8a37e5a81aa61513884f972a815ca877424d40e2'
$oldApplyHash = '2851d2ee7a44192bfb28a2ddac25c4ca9fbda9ddad674c63d49271196451c06c'
$oldLauncherHash = '6af5e91c467d0b4dbc9d6b1f34a5bf25aef2f422437864aad47b52e98d6b4840'
$expectedPaths = @('configure.ps1', 'initialize.ps1', 'launch.ps1', 'settings.ps1', 'version.ini')

function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Bytes([string]$Path) { return [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) }
function Assert-NoReparse([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    while ($null -ne $item) {
        Assert (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'A fixture path traverses a reparse point.'
        $item = if ($item -is [IO.DirectoryInfo]) { $item.Parent } else { $item.Directory }
    }
}
function Copy-SmallInstall([string]$Source, [string]$Destination) {
    Assert-NoReparse $Source
    Assert (-not (Test-Path -LiteralPath $Destination)) 'The isolated install already exists.'
    [void][IO.Directory]::CreateDirectory($Destination)
    # Only enumerate root files and the small updater tree, never SDK or AVD.
    $files = @(Get-ChildItem -LiteralPath $Source -File -Force)
    $update = Join-Path $Source 'update'
    Assert-NoReparse $update
    foreach ($item in Get-ChildItem -LiteralPath $update -Recurse -Force) {
        Assert (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'The small updater tree contains a reparse point.'
        if ($item -is [IO.FileInfo] -and $item.Name -ine 'server.txt') { $files += $item }
    }
    $snapshot = @{}
    foreach ($file in $files) {
        Assert-NoReparse $file.FullName
        Assert ($file.Length -le 2MB) 'A root/updater file is unexpectedly large.'
        $relative = $file.FullName.Substring($Source.Length + 1)
        $target = Join-Path $Destination $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        Copy-Item -LiteralPath $file.FullName -Destination $target
        $snapshot[$relative] = Hash $file.FullName
    }
    return $snapshot
}
function Add-PreservedData([string]$Root, [string]$Graphics) {
    $preferences = Join-Path $Root 'data\preferences.ini'
    $marker = Join-Path $Root 'data\avd\preserved-marker.txt'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $marker))
    $text = "profile=medium`r`ncleanup=0`r`ncarrier=unicom`r`ngraphics=$Graphics`r`nresolution=900p`r`ncustom_preserved=keep-exact-bytes`r`n"
    [IO.File]::WriteAllText($preferences, $text, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllBytes($marker, [byte[]](0,1,2,13,10,64,127,128,254,255))
    return @{ preferences=$preferences; marker=$marker; preferencesBefore=(Bytes $preferences); markerBefore=(Bytes $marker) }
}
function Assert-PreservedData($Data) {
    Assert ((Bytes $Data.preferences) -ceq $Data.preferencesBefore) 'The updater changed preferences.'
    Assert ((Bytes $Data.marker) -ceq $Data.markerBefore) 'The updater changed the AVD data marker.'
}
function Stage-LocalObjects([string]$Root, $Manifest, [string]$ManifestPath, [string]$SignaturePath) {
    $staging = Join-Path $Root ('data\update\staged-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($staging)
    Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $staging 'manifest.json')
    Copy-Item -LiteralPath $SignaturePath -Destination (Join-Path $staging 'manifest.sig')
    foreach ($file in $Manifest.files) {
        $object = Join-Path $Repository ('objects\' + $file.sha256)
        Assert-NoReparse $object
        Assert ((Get-Item -LiteralPath $object).Length -eq [long]$file.size -and (Hash $object) -ceq $file.sha256) ('A signed object is incorrect: ' + $file.path)
        Copy-Item -LiteralPath $object -Destination (Join-Path $staging $file.sha256)
    }
    return $staging
}
function Invoke-OldApply([string]$Root, [string]$Staging) {
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& rtk proxy $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $Root 'update\apply.ps1') -Staging $Staging -Serial 'emulator-5584' -NoRestart 2>&1)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    if ($code -ne 0 -and $output.Count -gt 0) { Write-Host ('Legacy apply returned ' + $code + '; details remain in its isolated update.log.') }
    return $code
}
function Remove-FixtureCase([string]$Path, [string]$Fixture, [string]$Parent) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $fixtureFull = [IO.Path]::GetFullPath($Fixture).TrimEnd('\')
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    Assert ((Split-Path -Leaf $fixtureFull) -match '^[0-9a-f]{32}$') 'The fixture directory is not a GUID.'
    Assert ([string]::Equals((Split-Path -Parent $fixtureFull), $parentFull, [StringComparison]::OrdinalIgnoreCase)) 'The fixture is outside the test build directory.'
    Assert ($full.StartsWith(($fixtureFull + '\'), [StringComparison]::OrdinalIgnoreCase)) 'Unsafe cleanup target outside the owned GUID fixture.'
    $resolved = (Resolve-Path -LiteralPath $full).ProviderPath.TrimEnd('\')
    Assert ([string]::Equals($resolved, $full, [StringComparison]::OrdinalIgnoreCase)) 'The cleanup target resolves to another path.'
    Assert-NoReparse $full
    foreach ($item in Get-ChildItem -LiteralPath $full -Force -Recurse) {
        Assert (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'The cleanup tree contains a reparse point.'
    }
    Remove-Item -LiteralPath $full -Recurse -Force
}

$testParent = Join-Path $project 'build\intel-vulkan-ota-release-tests'
[void][IO.Directory]::CreateDirectory($testParent)
Assert-NoReparse $testParent
$fixture = Join-Path $testParent ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$resultPath = Join-Path $fixture 'result.json'
$result = [ordered]@{
    schemaVersion=1; ok=$false; from='1.0.4'; to='1.0.5'; repository=$Repository
    androidStarted=$false; networkUsed=$false; sdkOrSystemImageScanned=$false
    manifestSha256=$null; downloadBytes=0; cases=@(); modifiedScriptRejection=$null
    fixturesCleaned=$false; error=$null; completedUtc=$null
}
$failure = $null
$step = 'read signed local repository'
$roots = @()
try {
    $manifestPath = Join-Path $Repository 'manifests\1.0.4.json'
    $signaturePath = Join-Path $Repository 'manifests\1.0.4.sig'
    $manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
    $signatureBytes = [IO.File]::ReadAllBytes($signaturePath)
    $sentinelBytes = [IO.File]::ReadAllBytes((Join-Path $Repository 'manifests\1.0.5.json'))
    $sentinelSignature = [IO.File]::ReadAllBytes((Join-Path $Repository 'manifests\1.0.5.sig'))
    $result.manifestSha256 = Hash $manifestPath
    foreach ($case in @(
        @{ name='full-host'; release='1.0.4'; graphics='host'; bootstrap=$false },
        @{ name='ota-swiftshader'; release='1.0.4-ota'; graphics='swiftshader'; bootstrap=$true }
    )) {
        $step = $case.name + ': copy frozen small files'
        $source = Join-Path $project ('releases\' + $case.release)
        Assert ((Hash (Join-Path $source 'update\core.ps1')) -ceq $oldCoreHash) 'The core is not the frozen real 1.0.4 updater.'
        Assert ((Hash (Join-Path $source 'update\apply.ps1')) -ceq $oldApplyHash) 'The apply script is not the frozen real 1.0.4 updater.'
        $root = Join-Path $fixture $case.name
        $roots += $root
        $sourceSnapshot = Copy-SmallInstall $source $root
        Assert (-not (Test-Path -LiteralPath (Join-Path $root 'sdk'))) 'A small-file fixture must not copy SDK.'
        . (Join-Path $root 'update\core.ps1')
        Assert ((Get-UpdateVersion $root) -ceq '1.0.4' -and (Hash (Join-Path $root 'launch.ps1')) -ceq $oldLauncherHash) 'The source release is not a normalized 1.0.4 installation.'
        $data = Add-PreservedData $root $case.graphics
        $unchanged = @{}
        foreach ($relative in @('start-auto.vbs','start-software.vbs','configure.vbs','update\launch-current.ps1','update\launcher-1.0.4.ps1')) {
            $path = Join-Path $root $relative
            $unchanged[$relative] = if (Test-Path -LiteralPath $path -PathType Leaf) { Hash $path } else { '-' }
        }

        $step = $case.name + ': verify old-core signature and all base paths'
        $manifest = Verify-UpdateManifest $root $manifestBytes $signatureBytes
        Assert ($manifest.from -ceq '1.0.4' -and $manifest.to -ceq '1.0.5') 'Unexpected release transition.'
        $paths = @($manifest.files | ForEach-Object { $_.path } | Sort-Object)
        Assert ($paths.Count -eq 5 -and (($paths -join '|') -ceq ($expectedPaths -join '|'))) 'The signed update must contain exactly the five common root files.'
        foreach ($file in $manifest.files) {
            Assert ((Hash (Get-UpdateTarget $root $file.path)) -ceq $file.base_sha256) ('The frozen lineage does not match a base hash: ' + $file.path)
        }
        $staging = Stage-LocalObjects $root $manifest $manifestPath $signaturePath
        $step = $case.name + ': apply with the real old updater'
        Assert ((Invoke-OldApply $root $staging) -eq 0) 'The real 1.0.4 apply -NoRestart failed.'
        Assert ((Get-UpdateVersion $root) -ceq '1.0.5') 'The real updater did not commit version 1.0.5.'
        foreach ($file in $manifest.files) {
            Assert ((Hash (Get-UpdateTarget $root $file.path)) -ceq $file.sha256) ('The installed signed object is incorrect: ' + $file.path)
        }
        Assert-PreservedData $data
        $journalPath = Join-Path $root 'data\update\pending\transaction.json'
        $journal = [IO.File]::ReadAllText($journalPath) | ConvertFrom-Json
        Assert ($journal.from -ceq '1.0.4' -and $journal.to -ceq '1.0.5' -and @($journal.files).Count -eq 5) 'The real updater did not write the expected rollback journal.'
        foreach ($entry in $journal.files) {
            Assert ($entry.existed -eq $true -and (Hash (Join-Path (Split-Path -Parent $journalPath) $entry.backup)) -ceq $entry.sha256) 'An old-file rollback backup is incorrect.'
        }
        $journalBefore = Hash $journalPath
        $launcherAfter = Hash (Join-Path $root 'launch.ps1')
        if ($case.bootstrap) {
            $step = $case.name + ': old bootstrap must preserve the 1.0.5 launcher twice'
            foreach ($attempt in 1..2) {
                & rtk proxy $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'update\launch-current.ps1') -NoLaunch -Headless
                Assert ($LASTEXITCODE -eq 0) 'The old bootstrap rejected the newer release.'
                Assert ((Hash (Join-Path $root 'launch.ps1')) -ceq $launcherAfter -and (Hash $journalPath) -ceq $journalBefore) 'The old bootstrap overwrote the newer launcher or its journal.'
                Assert-PreservedData $data
            }
        }
        foreach ($relative in $unchanged.Keys) {
            $path = Join-Path $root $relative
            $after = if (Test-Path -LiteralPath $path -PathType Leaf) { Hash $path } else { '-' }
            Assert ($after -ceq $unchanged[$relative]) ('The update altered an excluded shortcut or legacy sidecar: ' + $relative)
        }
        $step = $case.name + ': verify the signed target no-update sentinel'
        $sentinel = Verify-UpdateManifest $root $sentinelBytes $sentinelSignature -AllowNoUpdate
        Assert ($sentinel.from -ceq '1.0.5' -and $sentinel.to -ceq '1.0.5' -and @($sentinel.files).Count -eq 0) 'The signed target no-update sentinel is invalid.'
        foreach ($relative in $sourceSnapshot.Keys) {
            Assert ((Hash (Join-Path $source $relative)) -ceq $sourceSnapshot[$relative]) 'The immutable source release was changed.'
        }
        $result.downloadBytes = [long](($manifest.files | Measure-Object -Property size -Sum).Sum)
        $result.cases += [ordered]@{
            name=$case.name; sourceBase=$source; ok=$true; oldCoreSha256=$oldCoreHash; oldApplySha256=$oldApplyHash
            signatureVerified=$true; basePathsVerified=5; installedObjectsVerified=5; committedVersion='1.0.5'
            modernLauncherSha256=$launcherAfter; rollbackBackupsVerified=5; journalSha256=$journalBefore
            preferencesByteExact=$true; avdMarkerByteExact=$true; excludedShortcutsAndSidecarsUnchanged=$true
            bootstrapCalls=if ($case.bootstrap) { 2 } else { 0 }; signedNoUpdateSentinelVerified=$true
        }
        Write-Host ('PASS: ' + $case.name + ' signed 5-file update, real old apply, exact data preservation and target sentinel.')
    }

    $step = 'negative: modified local script must be rejected before changing the installation'
    $root = Join-Path $fixture 'modified-settings'
    $roots += $root
    [void](Copy-SmallInstall (Join-Path $project 'releases\1.0.4') $root)
    . (Join-Path $root 'update\core.ps1')
    $data = Add-PreservedData $root 'host'
    [IO.File]::AppendAllText((Join-Path $root 'settings.ps1'), "`r`n# Local modification: updater must preserve this file.`r`n", [Text.Encoding]::ASCII)
    $before = @{}
    foreach ($relative in $expectedPaths) { $before[$relative] = Hash (Join-Path $root $relative) }
    $manifest = Verify-UpdateManifest $root $manifestBytes $signatureBytes
    $staging = Stage-LocalObjects $root $manifest $manifestPath $signaturePath
    $exitCode = Invoke-OldApply $root $staging
    Assert ($exitCode -ne 0) 'A locally modified base script was accepted.'
    Assert ((Get-UpdateVersion $root) -ceq '1.0.4') 'A rejected update changed the installed version.'
    foreach ($relative in $expectedPaths) {
        Assert ((Hash (Join-Path $root $relative)) -ceq $before[$relative]) 'The rejected update changed an installed script.'
    }
    Assert-PreservedData $data
    Assert (-not (Test-Path -LiteralPath (Join-Path $root 'data\update\pending'))) 'A base-hash rejection began a transaction.'
    $rejectionLog = [IO.File]::ReadAllText((Join-Path $root 'data\update\update.log'))
    Assert ($rejectionLog.Contains('settings.ps1')) 'The negative case failed without identifying the modified script.'
    $result.modifiedScriptRejection = [ordered]@{
        ok=$true; path='settings.ps1'; exitCode=$exitCode; signedManifestVerified=$true
        versionUnchanged=$true; scriptsByteExact=$true; preferencesByteExact=$true; avdMarkerByteExact=$true; transactionNotStarted=$true
    }
    Write-Host 'PASS: real old apply rejects modified settings.ps1 and preserves scripts, preferences and AVD marker.'
    $step = 'safely remove only the owned small-file installs'
    foreach ($root in $roots) { Remove-FixtureCase $root $fixture $testParent }
    $result.fixturesCleaned = $true
    $result.ok = $true
} catch {
    $failure = $_
    $result.error = [ordered]@{ step=$step; message=$_.Exception.Message }
} finally {
    $result.completedUtc = [DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    Write-Host ('Evidence: ' + $resultPath)
}
if ($null -ne $failure) { throw $failure }
Write-Host 'PASS: both genuine 1.0.4 lineages update to 1.0.5 without Android, SDK enumeration or network access.'
