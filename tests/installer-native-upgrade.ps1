<# Real Inno Setup integration test, unique registration and tiny payload only.
   No production instance, real SDK, credentials or Android data are touched. #>
param([string]$Iscc = (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),[switch]$LegacyIdentity)
$ErrorActionPreference = 'Stop'
foreach ($module in @('Microsoft.PowerShell.Utility','Microsoft.PowerShell.Management','Microsoft.PowerShell.Security')) {
    Import-Module (Join-Path $PSHOME ('Modules\'+$module+'\'+$module+'.psd1')) -ErrorAction Stop
}
$project = Split-Path -Parent $PSScriptRoot
$token = [Guid]::NewGuid().ToString('N')
$root = Join-Path $project ('build\installer-native-upgrade-'+$token)
$id = 'ArtemisNativeUpgrade-'+$token
$installedId = $id
if($LegacyIdentity){$installedId='ArtemisNativeUpgrade-Old-'+$token}
$registration = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\'+$installedId+'_is1'
$newRegistration = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\'+$id+'_is1'
$recoveryRegistration = 'HKCU:\Software\ArtemisOS\InstallerRecovery\'+$installedId
$staleId='ArtemisNativeUpgrade-S-'+$token
$staleRegistration='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\'+$staleId+'_is1'
$activeAliasRoot=Join-Path $root 'other existing installation'
$staleMissingRoot=Join-Path $root 'missing retired installation'
$installed = Join-Path $root 'installed with spaces'
$results = [Collections.Generic.List[object]]::new()
$rtk = (Get-Command rtk.exe -ErrorAction Stop).Source
$frozenInputs=Join-Path $root 'inputs'
[void][IO.Directory]::CreateDirectory((Join-Path $frozenInputs 'tools'))
$sourceHashes=[ordered]@{}
foreach($relative in @('installer.iss','tools\InstallerUpgrade.iss','tools\InstallerOtaConfig.iss')) {
    $inputFile=Join-Path $project $relative
    if(Test-Path -LiteralPath $inputFile){
        $copy=Join-Path $frozenInputs $relative
        [IO.File]::Copy($inputFile,$copy,$false)
        $sourceHashes[$relative]=(Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$source = [IO.File]::ReadAllText((Join-Path $frozenInputs 'installer.iss'))
function Write-File([string]$Path,[string]$Text) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}
function Assert([bool]$Condition,[string]$Message) {
    $results.Add([pscustomobject]@{check=$Message;passed=$Condition})
    if (-not $Condition) { throw $Message }
    Write-Host ('PASS: '+$Message)
}
function Run-Setup([string]$Executable,[string[]]$Arguments,[string]$Name) {
    $parameters = @('proxy',('"'+$Executable+'"'),'/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',('"/LOG='+$root+'\'+$Name+'.log"'))
    $parameters += @($Arguments | ForEach-Object {'"'+$_+'"'})
    $process = Start-Process -FilePath $rtk -ArgumentList $parameters -PassThru -WindowStyle Hidden
    if (-not $process.WaitForExit(60000)) {
        # Limit termination to this fixture's own descendants.
        $all = @(Get-CimInstance Win32_Process)
        $ids = [Collections.Generic.HashSet[int]]::new(); [void]$ids.Add($process.Id)
        do { $changed=$false; foreach($item in $all){if($ids.Contains([int]$item.ParentProcessId) -and $ids.Add([int]$item.ProcessId)){$changed=$true}} } while($changed)
        foreach($fixturePid in $ids){Stop-Process -Id $fixturePid -Force -ErrorAction SilentlyContinue}
        throw ('Fixture setup timed out: '+$Name)
    }
    return $process.ExitCode
}
function Compile([string]$Version,[string]$Name,[string]$Identity=$id,[string]$Alias='') {
    $build = Join-Path $root $Name
    [void][IO.Directory]::CreateDirectory($build)
    $payload = [ordered]@{
        'launch.ps1'='fixture launch '+$Version
        'settings.ps1'='fixture settings '+$Version
        'sdk\emulator\emulator.exe'='fixture SDK (not executable)'
        'sdk\emulator\source.properties'="Pkg.Revision=37.3.9`r`n"
        'sdk\system-images\android-35\google_apis\x86_64\system.img'='fixture immutable image'
        'update\core.ps1'='fixture updater '+$Version
        '使用说明.txt'='fixture Unicode document '+$Version
    }
    if($Version -eq '1.0.6'){$payload['update\legacy-owned.txt']='fixture old-version-only managed file'}
    if($Version -eq '1.0.7'){$payload['update\new-managed.txt']='fixture new-version-only managed file'}
    $payload['version.ini']="[ArtemisOS]`r`nVersion=$Version`r`n"
    $manifest = [Collections.Generic.List[string]]::new();$manifest.Add('[Files]')
    $fileLines = [Collections.Generic.List[string]]::new()
    $fileLines.Add('#ifdef PayloadManifest')
    $fileLines.Add('Source: "{#PayloadManifest}"; Flags: dontcopy')
    $fileLines.Add('#endif')
    $hasUpgrade = $source.Contains('#include "tools\InstallerUpgrade.iss"')
    foreach($relative in $payload.Keys) {
        $file=Join-Path $build ('payload\'+$relative);Write-File $file $payload[$relative]
        $manifest.Add($relative+'='+(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant())
        $destination=Split-Path -Parent $relative
        $line='Source: "'+$file+'"; DestDir: "{app}'+$(if($destination){'\'+$destination})+'"; Flags: ignoreversion'
        if($hasUpgrade){$line+='; Check: NeedsManagedFile'}
        $fileLines.Add($line)
    }
    $server=Join-Path $build 'server.txt';Write-File $server "https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/`r`n"
    $fileLines.Add('Source: "'+$server+'"; DestDir: "{app}\update"; Flags: onlyifdoesntexist')
    [IO.File]::WriteAllText((Join-Path $build 'payload.ini'),($manifest -join "`r`n"),[Text.UTF8Encoding]::new($true))
    $text=$source
    $text=$text.Replace('MessagesFile: "ChineseSimplified.isl"','MessagesFile: "'+(Join-Path $project 'ChineseSimplified.isl')+'"')
    foreach($include in @('InstallerOtaConfig.iss','InstallerUpgrade.iss')) {
        $text=$text.Replace('#include "tools\'+$include+'"','#include "'+(Join-Path $frozenInputs ('tools\'+$include))+'"')
    }
    $text=[regex]::Replace($text,'(?ms)^\[Files\]\r?\n.*?(?=^\[Icons\])',('[Files]'+"`r`n"+($fileLines -join "`r`n")+"`r`n`r`n"))
    $text=[regex]::Replace($text,'(?ms)^\[Icons\]\r?\n.*?(?=^\[Code\])','')
    $text=[regex]::Replace($text,'(?m)^(SetupIconFile|WizardSmallImageFile|WizardImageFile)=.*\r?\n','')
    $text=[regex]::Replace($text,'(?m)^OutputDir=.*$','OutputDir='+$build)
    $text=[regex]::Replace($text,'(?m)^OutputBaseFilename=.*$','OutputBaseFilename='+$Name)
    $text=[regex]::Replace($text,'(?<!Suppressible)MsgBox\(([^\r\n]*?), (mbError|mbCriticalError), MB_OK\)','SuppressibleMsgBox($1, $2, MB_OK, IDOK)')
    $iss=Join-Path $build 'fixture.iss';Write-File $iss $text
    $compilerArgs=@('proxy',$Iscc,'/Qp','/DPackageCompression=none','/DUpgradeTestFixture=1',('/DReleaseAppId='+$Identity),('/DReleaseShortcutName='+$id),('/DReleaseDefaultDirName='+$id),('/DVersionSource='+$build+'\payload\version.ini'),('/DPayloadManifest='+$build+'\payload.ini'))
    if($Alias){$compilerArgs+=('/DUpgradeLegacyTestId='+$Alias)}
    $compilerArgs+=$iss
    # PS5 treats each native stderr line as an ErrorRecord. Capture all of them
    # without truncating the compiler diagnostic at its first line.
    $previousErrorAction=$ErrorActionPreference
    try {$ErrorActionPreference='Continue';$output=@(& $rtk @compilerArgs 2>&1);$compileExit=$LASTEXITCODE}
    finally {$ErrorActionPreference=$previousErrorAction}
    Write-File (Join-Path $build 'compile.log') ($output -join "`r`n")
    if($compileExit -ne 0){throw ('Fixture compilation failed: '+($output -join "`n"))}
    return Join-Path $build ($Name+'.exe')
}
function Assert-Data([hashtable]$Expected) {
    foreach($relative in $Expected.Keys){Assert ((Get-FileHash -LiteralPath (Join-Path $installed $relative)).Hash -ceq $Expected[$relative]) ('unchanged user bytes: '+$relative)}
}
function Get-RegistrySnapshot([string]$Identity=$installedId) {
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,[Microsoft.Win32.RegistryView]::Registry64)
    $key=$base.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Uninstall\'+$Identity+'_is1')
    try {
        if(-not $key){throw 'Expected fixture uninstall key is missing.'}
        $snapshot=[ordered]@{}
        foreach($name in @($key.GetValueNames()|Sort-Object)) {
            $snapshot[$name]=[ordered]@{kind=$key.GetValueKind($name).ToString();value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}
        }
        return $snapshot
    } finally {if($key){$key.Dispose()};$base.Dispose()}
}
function Assert-RegistrySnapshot($Expected,[string]$Identity=$installedId,[string]$Context='rollback') {
    $actual=Get-RegistrySnapshot $Identity
    Assert ($actual.Count -eq $Expected.Count) ($Context+' restores every original registry value without extras')
    foreach($name in $Expected.Keys) {
        Assert ($actual.Contains($name)) ($Context+' retains registry value: '+$name)
        Assert ($actual[$name].kind -ceq $Expected[$name].kind) ($Context+' preserves registry value type: '+$name)
        Assert (($actual[$name].value|ConvertTo-Json -Compress) -ceq ($Expected[$name].value|ConvertTo-Json -Compress)) ($Context+' preserves exact registry value: '+$name)
    }
}
function Assert-BusyLocks([string]$Installer) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        $upper=[IO.Path]::GetFullPath($installed).TrimEnd([char[]]'\/').ToUpperInvariant()
        $lower=[IO.Path]::GetFullPath($installed).TrimEnd('\').ToLowerInvariant()
        $upperHash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($upper)))).Replace('-','')
        $lowerHash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($lower)))).Replace('-','')
    } finally {$sha.Dispose()}
    $locks=@{
        launch='Global\ArtemisOS-Launch-'+$upperHash
        frontend='Local\ArtemisOS-Frontend-'+$upperHash.ToLowerInvariant()
        updater='Local\ArtemisOS-Update-'+$lowerHash.Substring(0,24)
    }
    foreach($name in $locks.Keys) {
        $mutex=[Threading.Mutex]::new($true,$locks[$name])
        try {Assert ((Run-Setup $Installer @() ('busy-'+$name)) -ne 0) ('existing '+$name+' lock prevents an upgrade')}
        finally {$mutex.ReleaseMutex();$mutex.Dispose()}
    }
}
[void][IO.Directory]::CreateDirectory($root)
Assert (-not (Test-Path -LiteralPath $registration)) 'unique fixture registration starts absent'
$succeeded=$false
try {
    $old=Compile '1.0.6' 'old' $installedId
    $alias=$staleId;if($LegacyIdentity){$alias=$installedId}
    $new=Compile '1.0.7' 'new' $id $alias
    if(-not $LegacyIdentity){$activeAliasInstaller=Compile '1.0.6' 'active-alias' $staleId}
    Assert ((Run-Setup $old @('/DIR='+$installed) 'fresh') -eq 0) 'old version installs successfully'
    Assert (Test-Path -LiteralPath $registration) 'old version owns real unique Inno registration'
    $immutableImage=Join-Path $installed 'sdk\system-images\android-35\google_apis\x86_64\system.img'
    $originalImageWriteTicks=(Get-Item -LiteralPath $immutableImage).LastWriteTimeUtc.Ticks
    New-ItemProperty -LiteralPath $registration -Name ArtemisFixtureUnicode -Value "  `"Quoted fixture value 中文`"`r`ntrailing space  " -PropertyType String |Out-Null
    $originalRegistry=Get-RegistrySnapshot
    Assert ($originalRegistry['UninstallString'].value.StartsWith('"') -and $originalRegistry['UninstallString'].value.Contains('installed with spaces')) 'native uninstall command initially quotes a path containing spaces'
    $bytes=@{}
    foreach($relative in @('data\avd\ArtemisOS_15.avd\userdata-qemu.img','data\installed-app.apk','data\login-state.txt','data\pictures\photo.png','data\preferences.ini','user-owned-note.txt')) {
        $text='fixture user bytes '+$relative
        if($relative -eq 'data\preferences.ini'){$text="profile=high`r`ngraphics=vulkan_intel`r`ncarrier=unicom`r`nresolution=1080p`r`nfuture_custom_key=preserve-exactly`r`n"}
        Write-File (Join-Path $installed $relative) $text
        $bytes[$relative]=(Get-FileHash -LiteralPath (Join-Path $installed $relative)).Hash
    }
    Write-File (Join-Path $installed 'update\server.txt') "https://custom.example/ota/`r`n"
    Write-File (Join-Path $installed 'data\update\server.txt') "https://override.example/repository/`r`n"
    $servers=@{};foreach($relative in @('update\server.txt','data\update\server.txt')){$servers[$relative]=(Get-FileHash -LiteralPath (Join-Path $installed $relative)).Hash}
    if(-not $LegacyIdentity) {
        Assert (-not (Test-Path -LiteralPath $staleRegistration)) 'unique alias registration starts absent'
        Assert ((Run-Setup $activeAliasInstaller @('/DIR='+$activeAliasRoot) 'active-alias-install') -eq 0) 'second identity has a real independent native installation'
        $activeAliasRegistry=Get-RegistrySnapshot $staleId
        $activeAliasFileHash=(Get-FileHash -LiteralPath (Join-Path $activeAliasRoot 'launch.ps1')).Hash
        Assert ((Run-Setup $new @() 'two-valid-installations') -ne 0) 'two existing installation identities are rejected without choosing one'
        Assert-RegistrySnapshot $originalRegistry
        Assert-RegistrySnapshot $activeAliasRegistry $staleId 'second active identity'
        Assert ((Get-FileHash -LiteralPath (Join-Path $activeAliasRoot 'launch.ps1')).Hash -ceq $activeAliasFileHash) 'ambiguous upgrade leaves the second installation files unchanged'
        Assert-Data $bytes;Assert-Data $servers
        Assert ((Run-Setup (Join-Path $activeAliasRoot 'unins000.exe') @() 'active-alias-uninstall') -eq 0) 'independent alias test installation uninstalls safely'
        Assert (-not (Test-Path -LiteralPath $staleRegistration)) 'independent alias uninstall removes only its own registration'
        Assert (-not (Test-Path -LiteralPath $staleMissingRoot)) 'retired alias directory is genuinely absent'
        New-Item -Path $staleRegistration -Force|Out-Null
        New-ItemProperty -LiteralPath $staleRegistration -Name InstallLocation -Value $staleMissingRoot -PropertyType String|Out-Null
        New-ItemProperty -LiteralPath $staleRegistration -Name DisplayName -Value 'Synthetic stale historical installation' -PropertyType String|Out-Null
        New-ItemProperty -LiteralPath $staleRegistration -Name DisplayVersion -Value '0.3.5' -PropertyType String|Out-Null
        New-ItemProperty -LiteralPath $staleRegistration -Name FixtureValue -Value '  "preserve stale registration 中文"  ' -PropertyType String|Out-Null
        $staleSnapshot=Get-RegistrySnapshot $staleId
    }
    if($source.Contains('#include "tools\InstallerUpgrade.iss"')) {
        $originalManaged=@{}
        foreach($relative in @('launch.ps1','settings.ps1','version.ini','update\core.ps1','使用说明.txt','unins000.exe','unins000.dat')){$originalManaged[$relative]=(Get-FileHash -LiteralPath (Join-Path $installed $relative)).Hash}
        Assert ((Run-Setup $new @('/FAILUPGRADE=1') 'injected-failure') -eq 8) 'injected pre-commit failure reports an unsuccessful upgrade'
        Assert-Data $originalManaged;Assert-Data $bytes;Assert-Data $servers
        Assert (-not (Test-Path -LiteralPath (Join-Path $installed 'update\new-managed.txt'))) 'rollback removes a newly introduced managed file'
        Assert ((Get-ItemProperty -LiteralPath $registration).DisplayVersion -eq '1.0.6') 'failed upgrade restores original version registration'
        Assert-RegistrySnapshot $originalRegistry
        Assert (-not (Test-Path -LiteralPath (Join-Path $installed '.artemis-install-pending.ini'))) 'successful rollback clears the pending marker'
        Assert (-not (Test-Path -LiteralPath $recoveryRegistration)) 'ordinary rollback clears independent recovery registration'
        Assert ((Run-Setup $new @('/CRASHUPGRADE=1') 'hard-interruption') -eq 9) 'hard interruption exits before normal installer cleanup'
        $pending=Join-Path $installed '.artemis-install-pending.ini'
        Assert (Test-Path -LiteralPath $pending) 'hard interruption leaves a persistent pending recovery marker'
        $backupToken=[regex]::Match([IO.File]::ReadAllText($pending),'(?im)^Backup=([0-9a-f]{32})\r?$').Groups[1].Value
        Assert ($backupToken.Length -eq 32) 'pending marker identifies a contained backup journal'
        $interruptedJournal=Join-Path $installed ('.artemis-install-backups\'+$backupToken+'\journal.ini')
        Assert (Test-Path -LiteralPath $interruptedJournal) 'interrupted upgrade retained its verified backup journal'
        Assert ([IO.File]::ReadAllText((Join-Path $installed 'launch.ps1')) -ceq 'fixture launch 1.0.7') 'interruption occurred after new program files had been applied'
        Assert (Test-Path -LiteralPath $recoveryRegistration) 'hard interruption retains the independent recovery locator'
        $locator=Get-ItemProperty -LiteralPath $recoveryRegistration
        Assert ($locator.Root -ieq $installed) 'independent recovery locator records the fixture root'
        Assert ($locator.Token -ceq $backupToken) 'independent recovery locator identifies the pending verified backup'
        if($installedId -notlike 'ArtemisNativeUpgrade-*'){throw 'Refusing to alter any non-fixture uninstall registration.'}
        Remove-Item -LiteralPath $registration -Recurse -Force
        Assert (-not (Test-Path -LiteralPath $registration)) 'fixture simulates the native uninstall-key rebuilding interruption window'
        Assert-Data $bytes;Assert-Data $servers
    }
    $upgrade=Run-Setup $new @() 'upgrade'
    Assert ($upgrade -eq 0) ('registered old version upgrades without /DIR (exit '+$upgrade+')')
    if($interruptedJournal){
        Assert ([IO.File]::ReadAllText($interruptedJournal) -match '(?im)^State=restored\r?$') 'next installation restored the interrupted transaction before continuing'
        Assert (-not (Test-Path -LiteralPath $pending)) 'successful recovery and upgrade clears the persistent pending marker'
        Assert (-not (Test-Path -LiteralPath $recoveryRegistration)) 'successful recovery and upgrade clears the independent recovery locator'
    }
    Assert-Data $bytes;Assert-Data $servers
    Assert ((Get-ItemProperty -LiteralPath $registration).DisplayVersion -eq '1.0.7') 'registration advances to 1.0.7'
    if($staleSnapshot){Assert-RegistrySnapshot $staleSnapshot $staleId 'untouched stale identity'}
    if($LegacyIdentity){Assert (-not (Test-Path -LiteralPath $newRegistration)) 'legacy upgrade reuses original AppId without creating a second registration'}
    Assert ([IO.Path]::GetFullPath((Get-ItemProperty -LiteralPath $registration).InstallLocation).TrimEnd('\') -ieq $installed) 'same registered directory is reused'
    Assert ((Get-ChildItem -LiteralPath $installed -Filter 'unins*.dat').Count -eq 1) 'one appended uninstall log remains'
    Assert ([IO.File]::ReadAllText((Join-Path $installed 'launch.ps1')) -ceq 'fixture launch 1.0.7') 'program files upgraded'
    Assert ([IO.File]::ReadAllText((Join-Path $installed '使用说明.txt')) -ceq 'fixture Unicode document 1.0.7') 'Unicode-named program file upgraded and recovered correctly'
    Assert ([IO.File]::ReadAllText((Join-Path $installed 'update\legacy-owned.txt')) -ceq 'fixture old-version-only managed file') 'upgrade preserves a managed file owned only by the original uninstall log'
    Assert ([IO.File]::ReadAllText((Join-Path $installed 'update\new-managed.txt')) -ceq 'fixture new-version-only managed file') 'upgrade installs and owns its newly introduced managed file'
    Assert-BusyLocks $new
    Assert-Data $bytes;Assert-Data $servers
    $repairSdk=Join-Path $installed 'sdk\emulator\source.properties'
    $expectedSdkHash=(Get-FileHash -LiteralPath (Join-Path $root 'new\payload\sdk\emulator\source.properties')).Hash
    Write-File $repairSdk 'fixture damaged SDK metadata'
    Assert ((Get-FileHash -LiteralPath $repairSdk).Hash -cne $expectedSdkHash) 'repair fixture starts with a genuinely corrupted SDK file'
    Assert ((Run-Setup $new @() 'repair') -eq 0) 'same-version repair succeeds'
    Assert ((Get-FileHash -LiteralPath $repairSdk).Hash -ceq $expectedSdkHash) 'same-version repair restores the corrupt SDK file to the packaged SHA256'
    Assert ((Get-Item -LiteralPath $immutableImage).LastWriteTimeUtc.Ticks -eq $originalImageWriteTicks) 'unchanged system image is never rewritten during upgrade or SDK repair'
    Assert-Data $bytes;Assert-Data $servers
    Assert ((Run-Setup $old @() 'downgrade') -ne 0) 'downgrade is rejected'
    Assert ((Run-Setup $new @('/DIR='+$root+'\wrong-target') 'wrong-target') -ne 0) 'different explicit directory is rejected for an existing identity'
    Assert-Data $bytes;Assert-Data $servers
    foreach($relative in @('update\server.txt','data\update\server.txt')){Write-File (Join-Path $installed $relative) "https://cloudx.playones.com/sd/YCsIY2UB/?d`r`n"}
    Assert ((Run-Setup $new @() 'official-repair') -eq 0) 'official retired endpoint can be repaired in place'
    foreach($relative in @('update\server.txt','data\update\server.txt')){Assert ([IO.File]::ReadAllText((Join-Path $installed $relative)).Trim() -ceq 'https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/') ('official OTA address repaired: '+$relative)}
    Assert-Data $bytes
    $uninstall=Join-Path $installed 'unins000.exe'
    Assert ((Run-Setup $uninstall @() 'uninstall') -eq 0) 'native combined uninstaller succeeds'
    Assert (-not (Test-Path -LiteralPath $registration)) 'native combined uninstaller removes the registration'
    if($staleSnapshot){Assert-RegistrySnapshot $staleSnapshot $staleId 'stale identity after active uninstall'}
    Assert (-not (Test-Path -LiteralPath $recoveryRegistration)) 'no independent recovery registration remains after final uninstall'
    Assert (-not (Test-Path -LiteralPath (Join-Path $installed 'launch.ps1'))) 'native combined uninstaller removes upgraded program files'
    Assert (-not (Test-Path -LiteralPath (Join-Path $installed 'update\legacy-owned.txt'))) 'combined uninstall removes files recorded only by the old installer'
    Assert (-not (Test-Path -LiteralPath (Join-Path $installed 'update\new-managed.txt'))) 'combined uninstall removes files recorded only by the new installer'
    Assert-Data $bytes
    $occupied=Join-Path $root 'unregistered';Write-File (Join-Path $occupied 'data\preferences.ini') 'untouched'
    Assert ((Run-Setup $new @('/DIR='+$occupied) 'unregistered') -ne 0) 'unregistered existing Android directory remains protected'
    Assert ([IO.File]::ReadAllText((Join-Path $occupied 'data\preferences.ini')) -ceq 'untouched') 'unregistered data remains unchanged'
    $succeeded=$true
} finally {
    Write-File (Join-Path $root 'result.json') ([pscustomobject]@{success=$succeeded;fixture=$root;identity=$id;installedIdentity=$installedId;legacyIdentity=[bool]$LegacyIdentity;sourceHashes=$sourceHashes;assertions=@($results.ToArray());completedUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Depth 6)
    if(Test-Path -LiteralPath $registration){
        $uninstall=Join-Path $installed 'unins000.exe'
        if(Test-Path -LiteralPath $uninstall){[void](Run-Setup $uninstall @() 'cleanup-uninstall')}
    }
    # Failed synthetic runs retain files and journals for diagnosis, but must
    # not leave test-only locators in the user's real registry indefinitely.
    if(-not $succeeded -and (Test-Path -LiteralPath $recoveryRegistration)) {
        $fixtureLocator=Get-ItemProperty -LiteralPath $recoveryRegistration
        if($installedId -notlike 'ArtemisNativeUpgrade-*' -or $fixtureLocator.Root -ine $installed){throw 'Refusing to clean an unverified recovery registration.'}
        Remove-Item -LiteralPath $recoveryRegistration -Recurse -Force
    }
    if(-not $LegacyIdentity -and (Test-Path -LiteralPath $staleRegistration)) {
        $aliasLocation=(Get-ItemProperty -LiteralPath $staleRegistration).InstallLocation
        if($staleId -notlike 'ArtemisNativeUpgrade-*'){throw 'Refusing to clean a non-fixture alias registration.'}
        if($aliasLocation -ieq $activeAliasRoot -and (Test-Path -LiteralPath (Join-Path $activeAliasRoot 'unins000.exe'))){[void](Run-Setup (Join-Path $activeAliasRoot 'unins000.exe') @() 'cleanup-active-alias')}
        elseif($aliasLocation -ieq $staleMissingRoot){Remove-Item -LiteralPath $staleRegistration -Recurse -Force}
        else {throw 'Refusing to clean an alias registration outside this fixture.'}
    }
    Write-Host ('Evidence: '+$root)
}
