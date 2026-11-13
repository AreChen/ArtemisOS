param([string]$Repository, [string]$Release)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Management\Microsoft.PowerShell.Management.psd1') -ErrorAction Stop
$project = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
if (-not $Release) { $Release = Join-Path $project 'build\ota-1.0.4-modern-vulkan' }
$Release = (Resolve-Path -LiteralPath $Release).ProviderPath.TrimEnd('\')
if (-not $Repository) { $Repository = Join-Path $Release 'repository' }
$Repository = (Resolve-Path -LiteralPath $Repository).ProviderPath.TrimEnd('\')
$oldCoreHash = '3a0d3ed7fe46c9870b849f8c8a37e5a81aa61513884f972a815ca877424d40e2'
$oldApplyHash = '2851d2ee7a44192bfb28a2ddac25c4ca9fbda9ddad674c63d49271196451c06c'
$newLauncherHash = '6af5e91c467d0b4dbc9d6b1f34a5bf25aef2f422437864aad47b52e98d6b4840'
$cases = @(
    @{ name='original-host'; base='base-original'; graphics='host'; launcher='f6ba9ca9102798014bed975dc2ad9d9f8409fac3f4f554d10e928f408ee0c07e' },
    @{ name='sd-fixed-swiftshader'; base='base-sd-fixed'; graphics='swiftshader'; launcher='49d234a4cee1e83af12385de3206e2a11939b2cabc35693dd885d1459fe7fac5' }
)
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Read-Bytes([string]$Path) { return [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) }
function Assert-NoReparse([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    while ($null -ne $item) {
        Assert (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'A fixture path traverses a reparse point.'
        $item = if ($item -is [IO.DirectoryInfo]) { $item.Parent } else { $item.Directory }
    }
}
function Copy-TestInstall([string]$Source, [string]$Destination) {
    Assert-NoReparse $Source
    Assert (-not (Test-Path -LiteralPath $Destination)) 'Test install already exists.'
    [void][IO.Directory]::CreateDirectory($Destination)
    foreach ($item in Get-ChildItem -LiteralPath $Source -Recurse -Force) {
        Assert (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Source tree contains a reparse point.'
        $relative = $item.FullName.Substring($Source.Length + 1)
        $dest = Join-Path $Destination $relative
        if ($item.PSIsContainer) { [void][IO.Directory]::CreateDirectory($dest); continue }
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $dest))
        if ($relative.StartsWith('sdk\', [StringComparison]::OrdinalIgnoreCase)) {
            [void](New-Item -ItemType HardLink -Path $dest -Target $item.FullName)
        } else {
            Copy-Item -LiteralPath $item.FullName -Destination $dest
        }
    }
}
function Remove-TestInstall([string]$Path, [string]$Fixture) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $prefix = [IO.Path]::GetFullPath($Fixture).TrimEnd('\') + '\'
    Assert ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) 'Unsafe test cleanup path.'
    Assert-NoReparse $full
    foreach ($item in Get-ChildItem -LiteralPath $full -Force -Recurse) {
        Assert (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Unsafe linked test cleanup tree.'
    }
    Remove-Item -LiteralPath $full -Recurse -Force
}

$manifestPath = Join-Path $Repository 'manifests\1.0.3.json'
$signaturePath = Join-Path $Repository 'manifests\1.0.3.sig'
Assert (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'The signed 1.0.3 -> 1.0.4 release repository is not ready.'
Assert (Test-Path -LiteralPath $signaturePath -PathType Leaf) 'The 1.0.3 release signature is missing.'
$manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
$signatureBytes = [IO.File]::ReadAllBytes($signaturePath)
$manifestHash = Hash $manifestPath
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$testParent = Join-Path $project 'build\modern-vulkan-ota-release-tests'
[void][IO.Directory]::CreateDirectory($testParent)
Assert-NoReparse $testParent
$fixture = Join-Path $testParent ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$resultPath = Join-Path $fixture 'result.json'
$result = [ordered]@{
    schemaVersion=1; ok=$false; from='1.0.3'; to='1.0.4'; repository=$Repository
    manifestSha256=$manifestHash; androidStarted=$false; sdkOrSystemImageScanned=$false
    cases=@(); retainedInstall=$null; error=$null; completedUtc=$null
}
$failure = $null
$step = 'preflight'
try {
    foreach ($case in $cases) {
        $step = $case.name + ': copy old install'
        $source = Join-Path $Release $case.base
        $root = Join-Path $fixture $case.name
        Assert ((Hash (Join-Path $source 'update\core.ps1')) -ceq $oldCoreHash) 'The fixture must use the genuine old core.'
        Assert ((Hash (Join-Path $source 'update\apply.ps1')) -ceq $oldApplyHash) 'The fixture must use the genuine 1.0.3 apply script.'
        Copy-TestInstall $source $root
        $corePath = Join-Path $root 'update\core.ps1'
        $applyPath = Join-Path $root 'update\apply.ps1'
        . $corePath
        Assert ((Get-UpdateVersion $root) -ceq '1.0.3') 'The copied install is not 1.0.3.'
        Assert ((Hash (Join-Path $root 'launch.ps1')) -ceq $case.launcher) 'The copied lineage launcher is incorrect.'

        $preferences = Join-Path $root 'data\preferences.ini'
        $marker = Join-Path $root 'data\avd\preserved-marker.txt'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $marker))
        $prefText = "profile=medium`r`ncleanup=0`r`nvideo_compat=1`r`ncarrier=unicom`r`ngraphics=$($case.graphics)`r`nresolution=1280x720`r`ncustom_preserved=keep-exact-bytes`r`n"
        [IO.File]::WriteAllText($preferences, $prefText, (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllBytes($marker, [byte[]](0,1,2,13,10,64,127,128,254,255))
        [IO.File]::WriteAllText((Join-Path $root 'data\graphics-swiftshader-1.0.1.flag'), '1', [Text.Encoding]::ASCII)
        $preferencesBefore = Read-Bytes $preferences
        $markerBefore = Read-Bytes $marker

        $step = $case.name + ': old-core signature and base verification'
        $manifest = Verify-UpdateManifest $root $manifestBytes $signatureBytes
        Assert ($manifest.from -ceq '1.0.3' -and $manifest.to -ceq '1.0.4') 'Unexpected release transition.'
        Assert (@($manifest.files | Where-Object path -EQ 'launch.ps1').Count -eq 0) 'A single-base manifest must not replace the lineage-dependent root launcher.'
        Assert (@($manifest.files | Where-Object { $_.path -like 'sdk/*' -and $_.path -notlike 'sdk/emulator/*' }).Count -eq 0) 'The runtime-only OTA must not include system images or platform-tools.'
        foreach ($required in @('start-auto.vbs','start-software.vbs','update/launch-current.ps1','update/launcher-1.0.4.ps1','sdk/emulator/modern-vulkan.json','version.ini')) {
            Assert (@($manifest.files | Where-Object path -EQ $required).Count -eq 1) ('Required release file missing: ' + $required)
        }
        $baseVerified = 0
        $sdkBaseVerified = 0
        foreach ($file in $manifest.files) {
            $dest = Get-UpdateTarget $root $file.path
            if ($file.base_sha256 -ceq '-') {
                Assert (-not (Test-Path -LiteralPath $dest)) ('A newly added path already exists: ' + $file.path)
            } else {
                Assert ((Hash $dest) -ceq $file.base_sha256) ('A legacy base hash does not match: ' + $file.path)
                if ($file.path -like 'sdk/*') { $sdkBaseVerified++ }
            }
            $baseVerified++
        }

        $step = $case.name + ': stage signed repository objects'
        $staging = Join-Path $root ('data\update\staged-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($staging)
        Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $staging 'manifest.json')
        Copy-Item -LiteralPath $signaturePath -Destination (Join-Path $staging 'manifest.sig')
        foreach ($file in $manifest.files) {
            $object = Join-Path $Repository ('objects\' + $file.sha256)
            Assert (Test-Path -LiteralPath $object -PathType Leaf) ('Release object is missing: ' + $file.path)
            Assert-NoReparse $object
            Assert ((Get-Item -LiteralPath $object).Length -eq [long]$file.size) ('Release object length differs: ' + $file.path)
            $dest = Join-Path $staging $file.sha256
            if (-not (Test-Path -LiteralPath $dest)) {
                if ([IO.Path]::GetPathRoot($object) -ieq [IO.Path]::GetPathRoot($dest)) {
                    [void](New-Item -ItemType HardLink -Path $dest -Target $object)
                } else { Copy-Item -LiteralPath $object -Destination $dest }
            }
        }

        $step = $case.name + ': real old apply -NoRestart'
        & rtk proxy $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $applyPath -Staging $staging -Serial 'emulator-5584' -NoRestart
        Assert ($LASTEXITCODE -eq 0) 'The real legacy update application failed.'
        Assert ((Get-UpdateVersion $root) -ceq '1.0.4') 'The update did not commit version 1.0.4.'
        Assert ((Hash (Join-Path $root 'launch.ps1')) -ceq $case.launcher) 'The common OTA unexpectedly replaced the lineage launcher.'
        Assert ((Read-Bytes $preferences) -ceq $preferencesBefore -and (Read-Bytes $marker) -ceq $markerBefore) 'The common OTA changed user data.'
        $installedHashes = @{}
        foreach ($file in $manifest.files) {
            $installedHashes[$file.path] = Hash (Join-Path $root $file.path)
            Assert ($installedHashes[$file.path] -ceq $file.sha256) ('An installed object is incorrect: ' + $file.path)
        }

        $step = $case.name + ': real bootstrap -NoLaunch'
        $bootstrap = Join-Path $root 'update\launch-current.ps1'
        & rtk proxy $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $bootstrap -NoLaunch -Headless
        Assert ($LASTEXITCODE -eq 0) 'The real launcher migration failed.'
        Assert ((Hash (Join-Path $root 'launch.ps1')) -ceq $newLauncherHash) 'The legacy launcher was not normalized to the frozen modern launcher.'
        $pending = Join-Path $root 'data\update\pending'
        $journalPath = Join-Path $pending 'transaction.json'
        $journal = [IO.File]::ReadAllText($journalPath) | ConvertFrom-Json
        $entry = @($journal.files | Where-Object path -EQ 'launch.ps1')
        Assert ($journal.schema -eq 1 -and $journal.from -ceq '1.0.3' -and $journal.to -ceq '1.0.4') 'The migration changed the transaction identity.'
        Assert ($journal.files.Count -eq $manifest.files.Count + 1 -and $entry.Count -eq 1) 'The rollback journal must add exactly one root launcher.'
        Assert ($entry[0].existed -eq $true -and $entry[0].sha256 -ceq $case.launcher -and $entry[0].backup -match '^[0-9]{4}\.bak$') 'The migration did not record the actual lineage backup.'
        Assert ((Hash (Join-Path $pending $entry[0].backup)) -ceq $case.launcher) 'The legacy launcher backup is incorrect.'
        Assert ((Test-Path -LiteralPath (Join-Path $pending 'completed.flag')) -and -not (Test-Path -LiteralPath (Join-Path $pending 'applying.flag'))) 'The migration transaction did not finish cleanly.'
        $journalHash = Hash $journalPath
        & rtk proxy $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $bootstrap -NoLaunch -Headless
        Assert ($LASTEXITCODE -eq 0) 'The second no-launch bootstrap failed.'
        Assert ((Hash $journalPath) -ceq $journalHash -and (Hash (Join-Path $root 'launch.ps1')) -ceq $newLauncherHash) 'The completed migration is not idempotent.'
        Assert ((Read-Bytes $preferences) -ceq $preferencesBefore -and (Read-Bytes $marker) -ceq $markerBefore) 'The launcher migration changed user data.'
        Assert ((Hash (Join-Path $source 'launch.ps1')) -ceq $case.launcher -and (Get-UpdateVersion $source) -ceq '1.0.3') 'The immutable source base was altered.'

        $step = $case.name + ': installed runtime metadata'
        $emulator = Join-Path $root 'sdk\emulator'
        $properties = [IO.File]::ReadAllText((Join-Path $emulator 'source.properties'))
        Assert ($properties -match '(?m)^Pkg.Revision=37\.3\.9\r?$' -and $properties -match '(?m)^Pkg.BuildId=16863232\r?$') 'The installed runtime version is incorrect.'
        $provider = [IO.File]::ReadAllText((Join-Path $emulator 'modern-vulkan.json')) | ConvertFrom-Json
        Assert ($provider.schemaVersion -eq 1 -and $provider.runtimeVersion -ceq '37.3.9' -and $provider.runtimeBuild -ceq '16863232' -and
            $provider.provider -ceq 'angle-swiftshader-vulkan' -and $provider.glesProvider -ceq 'lib64/gles_swiftshader' -and
            $provider.vulkanIcd -ceq 'lib64/vulkan/vk_swiftshader_icd.json' -and $provider.files.Count -eq 8) 'The installed modern provider metadata is incorrect.'
        foreach ($file in $provider.files) {
            Assert ($file.path -match '^lib64/(gles_swiftshader|vulkan)/[A-Za-z0-9._-]+$' -and $file.sha256 -match '^[a-f0-9]{64}$') 'The provider contains an unexpected path or hash.'
            $relative = 'sdk/emulator/' + $file.path
            $digest = if ($installedHashes.ContainsKey($relative)) { $installedHashes[$relative] } else { Hash (Join-Path $root $relative) }
            Assert ($digest -ceq $file.sha256) ('An installed provider file is incorrect: ' + $file.path)
        }
        foreach ($name in @('start-auto.vbs','start-software.vbs')) {
            $vbs = [IO.File]::ReadAllText((Join-Path $root $name))
            Assert ($vbs.Contains('update\launch-current.ps1') -and $vbs -notmatch '\s-Launch\b' -and $vbs.Contains('shell.Run command, 0, False')) 'An installed shortcut does not use the hidden migration entry.'
        }
        $result.cases += [ordered]@{
            name=$case.name; root=$root; sourceBase=$source; graphics=$case.graphics; ok=$true
            oldCoreSha256=$oldCoreHash; oldApplySha256=$oldApplyHash; oldSignatureVerified=$true
            basePathsVerified=$baseVerified; existingSdkHashesVerified=$sdkBaseVerified; installedObjectsVerified=$manifest.files.Count
            legacyLauncherSha256=$case.launcher; modernLauncherSha256=$newLauncherHash
            journalSha256=$journalHash; journalIncludesActualLauncherBackup=$true; bootstrapIdempotent=$true
            preferencesByteExact=$true; userMarkerByteExact=$true; providerFilesVerified=8
            runtimeVersion='37.3.9'; runtimeBuild='16863232'; provider='angle-swiftshader-vulkan'
            retainedLegacyGlesCm=(Test-Path -LiteralPath (Join-Path $emulator 'lib64\gles_swiftshader\libGLES_CM.dll'))
            retained=$true
        }
        Write-Host ('PASS: ' + $case.name + ' old-core signature, old apply, all manifest objects, migration, idempotency and byte-exact user data.')
    }
    $step = 'remove first successful install; retain software-rendering install for native boot'
    Remove-TestInstall $result.cases[0].root $fixture
    $result.cases[0].retained = $false
    $result.retainedInstall = $result.cases[1].root
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
Write-Host ('PASS: two genuine 1.0.3 lineages update to 1.0.4 without Android startup. Native-boot fixture: ' + $result.retainedInstall)
