param([string]$Repository, [string]$TargetRoot, [string]$ExportDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Management\Microsoft.PowerShell.Management.psd1') -ErrorAction Stop
$project = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
if (-not $Repository) { $Repository = Join-Path $project 'build\release-1.0.6\repository' }
if (-not $TargetRoot) { $TargetRoot = Join-Path $project 'build\release-1.0.6\ota-target' }
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$oldCoreHash = '3a0d3ed7fe46c9870b849f8c8a37e5a81aa61513884f972a815ca877424d40e2'
$oldApplyHash = '2851d2ee7a44192bfb28a2ddac25c4ca9fbda9ddad674c63d49271196451c06c'
$preservedPaths = @('start-auto.vbs','start-software.vbs','update/launch-current.ps1','update/launcher-1.0.4.ps1')
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Hash([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '-' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Bytes([string]$Path) { return [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) }
function Assert-NoReparse([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    while ($null -ne $item) {
        Assert (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'A fixture or source traverses a reparse point.'
        $item = if ($item -is [IO.DirectoryInfo]) { $item.Parent } else { $item.Directory }
    }
}
function Copy-InstallFiles([string]$Source, [string]$Destination) {
    Assert-NoReparse $Source
    Assert (-not (Test-Path -LiteralPath $Destination)) 'The isolated installation already exists.'
    [void][IO.Directory]::CreateDirectory($Destination)
    # Enumerate only root files and update: never SDK, userdata or AVD trees.
    $files = @(Get-ChildItem -LiteralPath $Source -File -Force | Where-Object { $_.Name -ine 'server.txt' })
    foreach ($item in Get-ChildItem -LiteralPath (Join-Path $Source 'update') -Recurse -Force) {
        Assert (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'The update tree contains a reparse point.'
        if ($item -is [IO.FileInfo] -and $item.Name -ine 'server.txt') { $files += $item }
    }
    $snapshot = @{}
    foreach ($file in $files) {
        Assert-NoReparse $file.FullName
        Assert ($file.Length -le 128MB) 'An updater input is unexpectedly large.'
        $relative = $file.FullName.Substring($Source.Length + 1)
        $target = Join-Path $Destination $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        [IO.File]::Copy($file.FullName, $target, $false)
        $snapshot[$relative] = Hash $file.FullName
    }
    return $snapshot
}
function Add-Data([string]$Root, [string]$Graphics) {
    $paths = @('data\preferences.ini','data\setup-state.ini','data\avd\preserved-marker.txt')
    foreach ($relative in $paths) { [void][IO.Directory]::CreateDirectory((Split-Path -Parent (Join-Path $Root $relative))) }
    [IO.File]::WriteAllText((Join-Path $Root $paths[0]), "profile=medium`r`ncarrier=unicom`r`ngraphics=$Graphics`r`nresolution=900p`r`ncustom_preserved=exact-bytes`r`n", (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $Root $paths[1]), "locale=1`r`nnetwork=1`r`nlauncher_rotation=1`r`n", [Text.Encoding]::ASCII)
    [IO.File]::WriteAllBytes((Join-Path $Root $paths[2]), [byte[]](0,1,2,13,10,64,127,128,254,255))
    $snapshot = @{}
    foreach ($relative in $paths) { $snapshot[$relative] = Bytes (Join-Path $Root $relative) }
    return @{ Root=$Root; Snapshot=$snapshot }
}
function Assert-Data($Data) {
    foreach ($relative in $Data.Snapshot.Keys) { Assert ((Bytes (Join-Path $Data.Root $relative)) -ceq $Data.Snapshot[$relative]) ('Preserved data changed: ' + $relative) }
}
function Run-Script([string]$Path, [string[]]$Arguments) {
    $saved = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& rtk proxy $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Path @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $saved }
    return [pscustomobject]@{Code=$code;Output=($output -join "`n")}
}
function Stage-Objects([string]$Root, $Manifest, [string]$ManifestPath, [string]$SignaturePath) {
    $staging = Join-Path $Root ('data\update\staged-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($staging)
    Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $staging 'manifest.json')
    Copy-Item -LiteralPath $SignaturePath -Destination (Join-Path $staging 'manifest.sig')
    foreach ($file in $Manifest.files) { Copy-Item -LiteralPath (Join-Path $Repository ('objects\' + $file.sha256)) -Destination (Join-Path $staging $file.sha256) }
    return $staging
}
function Remove-OwnedCase([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $fixtureFull = [IO.Path]::GetFullPath($fixture).TrimEnd('\')
    Assert ((Split-Path -Leaf $fixtureFull) -cmatch '^[a-f0-9]{32}$' -and [string]::Equals((Split-Path -Parent $fixtureFull), $testParent, [StringComparison]::OrdinalIgnoreCase)) 'The test fixture is not our GUID directory.'
    Assert ($full.StartsWith(($fixtureFull + '\'), [StringComparison]::OrdinalIgnoreCase)) 'Cleanup escaped the owned GUID fixture.'
    Assert ([string]::Equals((Resolve-Path -LiteralPath $full).ProviderPath.TrimEnd('\'), $full, [StringComparison]::OrdinalIgnoreCase)) 'The cleanup path resolves elsewhere.'
    Assert-NoReparse $full
    foreach ($item in Get-ChildItem -LiteralPath $full -Recurse -Force) { Assert (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Cleanup found a reparse point.' }
    Remove-Item -LiteralPath $full -Recurse -Force
}
function Start-OwnedProcess([string]$Path, [string[]]$Arguments) {
    $quoted = @($Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
    $process = Start-Process -FilePath $Path -ArgumentList $quoted -WindowStyle Hidden -PassThru
    $script:ownedProcesses += [pscustomobject]@{Process=$process;Path=$Path;Ticks=$process.StartTime.ToUniversalTime().Ticks}
    return $process
}
function Wait-File([string]$Path) {
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    while (-not [IO.File]::Exists($Path)) {
        Assert ([DateTime]::UtcNow -lt $deadline) ('Fixture signal timed out: ' + (Split-Path -Leaf $Path))
        Start-Sleep -Milliseconds 25
    }
}

$testParent = Join-Path $project 'build\frontend-ota-release-tests'
[void][IO.Directory]::CreateDirectory($testParent)
Assert-NoReparse $testParent
$fixture = Join-Path $testParent ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$resultPath = Join-Path $fixture 'result.json'
$roots = @(); $ownedProcesses = @(); $failure = $null; $step = 'load final signed local repository'
$result = [ordered]@{schemaVersion=1;ok=$false;from='1.0.5';to='1.0.6';repository=$Repository;targetRoot=$TargetRoot;manifestSha256=$null;fileCount=0;downloadBytes=0;objectCount=0;cases=@();exportedSnapshots=@();modifiedLauncherRejected=$false;futureHandshake=$null;androidStarted=$false;networkUsed=$false;sdkOrImageScanned=$false;fixturesCleaned=$false;error=$null;completedUtc=$null}
try {
    $Repository = (Resolve-Path -LiteralPath $Repository).ProviderPath.TrimEnd('\')
    $TargetRoot = (Resolve-Path -LiteralPath $TargetRoot).ProviderPath.TrimEnd('\')
    $result.repository = $Repository
    $result.targetRoot = $TargetRoot
    if ($ExportDirectory) {
        $ExportDirectory = [IO.Path]::GetFullPath($ExportDirectory).TrimEnd('\')
        $allowedExportParent = Join-Path $project 'build\release-1.0.6'
        Assert ([string]::Equals((Split-Path -Parent $ExportDirectory),$allowedExportParent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $ExportDirectory) -cmatch '^[a-z0-9-]+$') 'Snapshot export must stay directly under the release build directory.'
        Assert (-not (Test-Path -LiteralPath $ExportDirectory)) 'Use a fresh snapshot export directory.'
        Assert-NoReparse $allowedExportParent
        [void][IO.Directory]::CreateDirectory($ExportDirectory)
    }
    $manifestPath = Join-Path $Repository 'manifests\1.0.5.json'
    $signaturePath = Join-Path $Repository 'manifests\1.0.5.sig'
    $manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
    $signatureBytes = [IO.File]::ReadAllBytes($signaturePath)
    $rawManifest = [Text.Encoding]::UTF8.GetString($manifestBytes) | ConvertFrom-Json
    $result.manifestSha256 = Hash $manifestPath
    $result.fileCount = @($rawManifest.files).Count
    $result.downloadBytes = [long](($rawManifest.files | Measure-Object -Property size -Sum).Sum)
    $result.objectCount = @($rawManifest.files.sha256 | Sort-Object -Unique).Count
    $expectedPaths = @()
    foreach ($path in @('launch.ps1','settings.ps1','initialize.ps1','configure.ps1','configure.vbs','start-auto.vbs','start-software.vbs','version.ini','ArtemisOS15.ico')) {
        $targetPath = Join-Path $TargetRoot $path
        if ([IO.File]::Exists($targetPath) -and (Hash $targetPath) -cne (Hash (Join-Path $project ('releases\1.0.5-ota-from-full\' + $path)))) { $expectedPaths += $path }
    }
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $TargetRoot 'update') -File -Recurse) {
        $path = $file.FullName.Substring($TargetRoot.Length + 1).Replace('\','/')
        if ($path -in @('update/recovery.ps1','update/trusted-key.xml','update/server.txt','update/test-marker.txt')) { continue }
        if ((Hash $file.FullName) -cne (Hash (Join-Path $project ('releases\1.0.5-ota-from-full\' + $path)))) { $expectedPaths += $path }
    }
    Assert ((($rawManifest.files.path | Sort-Object) -join '|') -ceq (($expectedPaths | Sort-Object) -join '|')) 'The repository does not contain exactly the complete target delta.'
    foreach ($required in @('launch.ps1','initialize.ps1','version.ini','update/apply.ps1','update/frontend-handoff.ps1','update/launcher-layout.ps1','update/frontend/ArtemisFrontend.exe','update/frontend/runtime/scrcpy.exe','update/frontend/runtime/scrcpy-server','update/frontend/runtime/SDL3.dll','update/frontend/third-party/sources.json')) {
        Assert ($required -cin @($rawManifest.files.path)) ('Missing required release payload: ' + $required)
    }
    foreach ($file in $rawManifest.files) {
        Assert ($file.path -notlike 'sdk/*' -and $file.path -cnotin $preservedPaths) 'The payload changes SDK or a lineage-specific entry.'
        $object = Join-Path $Repository ('objects\' + $file.sha256)
        Assert-NoReparse $object
        Assert ((Get-Item -LiteralPath $object).Length -eq [long]$file.size -and (Hash $object) -ceq $file.sha256 -and (Hash (Join-Path $TargetRoot $file.path)) -ceq $file.sha256) ('Incorrect signed object: ' + $file.path)
    }
    $offerRunner = Join-Path $fixture 'check-local-sentinel.ps1'
    [IO.File]::WriteAllText($offerRunner, @'
param([string]$Root,[string]$Repository)
$ErrorActionPreference='Stop'
. (Join-Path $Root 'update\core.ps1')
function Get-UpdateBaseUri([string]$Root) { return [Uri]'https://offline-fixture.invalid/' }
function Read-UpdateBytes([Uri]$Uri,[int]$Maximum) {
    if ($Uri.Host -cne 'offline-fixture.invalid' -or $Uri.AbsolutePath -cnotin @('/manifests/1.0.6.json','/manifests/1.0.6.sig')) { throw 'Unexpected local sentinel resource.' }
    $path=Join-Path $Repository $Uri.AbsolutePath.TrimStart('/')
    $bytes=[IO.File]::ReadAllBytes($path)
    if ($bytes.Length -gt $Maximum) { throw 'Local sentinel exceeds the real updater limit.' }
    return ,$bytes
}
if ($null -ne (Get-UpdateOffer $Root)) { throw 'The 1.0.6 no-update sentinel returned an update.' }
'@, [Text.Encoding]::ASCII)
    foreach ($case in @(@{name='from-full-host';release='1.0.5-ota-from-full';graphics='host'},@{name='from-ota-swiftshader';release='1.0.5-ota';graphics='swiftshader'})) {
        $step = $case.name + ': copy frozen real old updater'
        $source = Join-Path $project ('releases\' + $case.release)
        Assert ((Hash (Join-Path $source 'update\core.ps1')) -ceq $oldCoreHash -and (Hash (Join-Path $source 'update\apply.ps1')) -ceq $oldApplyHash) 'The source updater is not the frozen real 1.0.5 core/apply.'
        $root = Join-Path $fixture $case.name; $roots += $root
        $sourceSnapshot = Copy-InstallFiles $source $root
        Assert (-not (Test-Path -LiteralPath (Join-Path $root 'sdk'))) 'A legacy fixture unexpectedly includes SDK.'
        $data = Add-Data $root $case.graphics
        $unchanged = @{}; foreach ($relative in $preservedPaths) { $unchanged[$relative] = Hash (Join-Path $root $relative) }
        . (Join-Path $root 'update\core.ps1')
        $manifest = Verify-UpdateManifest $root $manifestBytes $signatureBytes
        Assert ($manifest.from -ceq '1.0.5' -and $manifest.to -ceq '1.0.6') 'Unexpected signed release transition.'
        foreach ($file in $manifest.files) { Assert ((Hash (Get-UpdateTarget $root $file.path)) -ceq $file.base_sha256) ('A published lineage conflicts with the strict base hash: ' + $file.path) }
        $staging = Stage-Objects $root $manifest $manifestPath $signaturePath
        $step = $case.name + ': true frozen apply of the complete frontend payload'
        $applied = Run-Script (Join-Path $root 'update\apply.ps1') @('-Staging',$staging,'-Serial','emulator-5584','-NoRestart')
        Assert ($applied.Code -eq 0) ('The frozen real 1.0.5 updater failed; inspect the isolated update.log. ' + $applied.Output)
        Assert ((Get-UpdateVersion $root) -ceq '1.0.6') 'The real old updater did not commit 1.0.6.'
        foreach ($file in $manifest.files) { Assert ((Hash (Get-UpdateTarget $root $file.path)) -ceq $file.sha256) ('An installed object differs from the signed payload: ' + $file.path) }
        Assert-Data $data
        $journalPath = Join-Path $root 'data\update\pending\transaction.json'
        $journal = [IO.File]::ReadAllText($journalPath) | ConvertFrom-Json
        Assert ($journal.from -ceq '1.0.5' -and $journal.to -ceq '1.0.6' -and @($journal.files).Count -eq $result.fileCount -and $journal.files[-1].path -ceq 'version.ini' -and [IO.File]::Exists((Join-Path (Split-Path -Parent $journalPath) 'completed.flag'))) 'The completed rollback journal is incorrect.'
        foreach ($entry in $journal.files) {
            $backup = Join-Path (Split-Path -Parent $journalPath) $entry.backup
            if ($entry.existed) { Assert ((Hash $backup) -ceq $entry.sha256) 'An existing-file rollback backup is incorrect.' }
            else { Assert ($entry.sha256 -ceq '-' -and -not [IO.File]::Exists($backup)) 'A newly added frontend file has an incorrect rollback entry.' }
        }
        $journalBefore = Hash $journalPath
        $launcherAfter = Hash (Join-Path $root 'launch.ps1')
        $bootstrapCalls = 0
        if ([IO.File]::Exists((Join-Path $root 'update\launch-current.ps1'))) {
            foreach ($attempt in 1..2) {
                $bootstrapped = Run-Script (Join-Path $root 'update\launch-current.ps1') @('-NoLaunch','-Headless')
                Assert ($bootstrapped.Code -eq 0 -and (Hash (Join-Path $root 'launch.ps1')) -ceq $launcherAfter -and (Hash $journalPath) -ceq $journalBefore) 'The historical bootstrap overwrote 1.0.6 or changed its journal.'
                $bootstrapCalls++
            }
        }
        foreach ($relative in $unchanged.Keys) { Assert ((Hash (Join-Path $root $relative)) -ceq $unchanged[$relative]) ('The OTA altered a preserved lineage path: ' + $relative) }
        . (Join-Path $root 'update\core.ps1')
        $sentinel = Verify-UpdateManifest $root ([IO.File]::ReadAllBytes((Join-Path $Repository 'manifests\1.0.6.json'))) ([IO.File]::ReadAllBytes((Join-Path $Repository 'manifests\1.0.6.sig'))) -AllowNoUpdate
        Assert ($sentinel.from -ceq '1.0.6' -and $sentinel.to -ceq '1.0.6' -and @($sentinel.files).Count -eq 0) 'The signed 1.0.6 no-update sentinel is incorrect.'
        $offer = Run-Script $offerRunner @('-Root',$root,'-Repository',$Repository)
        Assert ($offer.Code -eq 0) ('The installed Get-UpdateOffer did not return no update: ' + $offer.Output)
        Assert-Data $data
        foreach ($relative in $sourceSnapshot.Keys) { Assert ((Hash (Join-Path $source $relative)) -ceq $sourceSnapshot[$relative]) 'An immutable published baseline changed.' }
        if ($ExportDirectory) {
            $export = Join-Path $ExportDirectory ($case.release.Replace('1.0.5','1.0.6'))
            [void](Copy-InstallFiles $root $export)
            Assert (-not (Test-Path -LiteralPath (Join-Path $export 'data')) -and -not (Test-Path -LiteralPath (Join-Path $export 'sdk'))) 'A small-file release export contains data or SDK.'
            $result.exportedSnapshots += [ordered]@{path=$export;source=$source;realOldApply=$true;dataIncluded=$false;sdkIncluded=$false}
        }
        $result.cases += [ordered]@{name=$case.name;source=$source;ok=$true;oldCoreSha256=$oldCoreHash;oldApplySha256=$oldApplyHash;strictBasePathsVerified=$result.fileCount;installedObjectsVerified=$result.fileCount;rollbackEntriesVerified=$result.fileCount;committedVersion='1.0.6';preferencesByteExact=$true;setupStateByteExact=$true;avdMarkerByteExact=$true;legacyPathsUnchanged=$true;bootstrapCalls=$bootstrapCalls;signedNoUpdateOfferVerified=$true;launcherSha256=$launcherAfter;frontendSha256=(Hash (Join-Path $root 'update\frontend\ArtemisFrontend.exe'))}
        Write-Host ('PASS: ' + $case.name + ' complete signed ' + $result.fileCount + '-file payload using real old core/apply, data intact, target no-update offer.')
    }
    $successfulRoot = $root
    $step = 'negative: reject locally modified launch.ps1 before replacing files'
    $root = Join-Path $fixture 'modified-launcher'; $roots += $root
    [void](Copy-InstallFiles (Join-Path $project 'releases\1.0.5-ota-from-full') $root)
    $data = Add-Data $root 'host'
    [IO.File]::AppendAllText((Join-Path $root 'launch.ps1'), "`r`n# retained local modification`r`n", [Text.Encoding]::ASCII)
    $launcherBefore = Hash (Join-Path $root 'launch.ps1')
    $staging = Stage-Objects $root $rawManifest $manifestPath $signaturePath
    $rejected = Run-Script (Join-Path $root 'update\apply.ps1') @('-Staging',$staging,'-Serial','emulator-5584','-NoRestart')
    Assert ($rejected.Code -ne 0 -and (Get-UpdateVersion $root) -ceq '1.0.5' -and (Hash (Join-Path $root 'launch.ps1')) -ceq $launcherBefore -and -not (Test-Path -LiteralPath (Join-Path $root 'data\update\pending')) -and -not (Test-Path -LiteralPath (Join-Path $root 'update\frontend'))) 'A modified launcher was accepted or partially changed the install.'
    Assert-Data $data
    $result.modifiedLauncherRejected = $true
    Write-Host 'PASS: frozen updater rejects a modified launcher before starting its transaction.'

    # A narrow future-update test uses the newly installed updater/helper and
    # real, identity-bound fixture processes/pipe. The actual GUI is not started.
    $step = 'future upgrade: identity-bound frontend handoff and executable replacement'
    $root = Join-Path $fixture 'future-handoff'; $roots += $root
    [void](Copy-InstallFiles $successfulRoot $root)
    $data = Add-Data $root 'host'
    foreach ($relative in @('sdk\emulator\qemu\windows-x86_64','sdk\platform-tools')) { [void][IO.Directory]::CreateDirectory((Join-Path $root $relative)) }
    $stubPath = Join-Path $fixture 'FrontendReleaseFixture.exe'
    $stubSource = @'
using System;
using System.IO;
using System.IO.Pipes;
using System.Diagnostics;
using System.Text;
using System.Threading;
public static class FrontendReleaseFixture {
  static void KillOwned(string root, string path, string id, string ticks) {
    using (Process p=Process.GetProcessById(Int32.Parse(id))) {
      if (!String.Equals(p.MainModule.FileName, Path.Combine(root,path), StringComparison.OrdinalIgnoreCase) || p.StartTime.ToUniversalTime().Ticks.ToString()!=ticks) throw new Exception("Fixture identity mismatch");
      p.Kill(); if (!p.WaitForExit(5000)) throw new Exception("Fixture process did not exit");
    }
  }
  public static int Main(string[] args) {
    string name=Path.GetFileName(Environment.GetCommandLineArgs()[0]);
    if (name.StartsWith("qemu-system-",StringComparison.OrdinalIgnoreCase)) { Thread.Sleep(120000); return 0; }
    string root=Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"../.."));
    if (String.Equals(name,"emulator.exe",StringComparison.OrdinalIgnoreCase)) {
      var info=new ProcessStartInfo(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"qemu/windows-x86_64/qemu-system-x86_64-headless.exe"),"-port 5584"); info.UseShellExecute=false; info.CreateNoWindow=true;
      using (Process child=Process.Start(info)) using (Process own=Process.GetCurrentProcess()) {
        File.WriteAllLines(Path.Combine(root,"fixture-backend.txt"),new[]{own.Id.ToString(),own.StartTime.ToUniversalTime().Ticks.ToString(),child.Id.ToString(),child.StartTime.ToUniversalTime().Ticks.ToString()});
        Thread.Sleep(120000);
      }
      return 0;
    }
    if (String.Equals(name,"adb.exe",StringComparison.OrdinalIgnoreCase)) {
      if (String.Join(" ",args)!="-s emulator-5584 emu kill") return 3;
      string[] id=File.ReadAllLines(Path.Combine(root,"fixture-backend.txt"));
      KillOwned(root,"sdk/emulator/qemu/windows-x86_64/qemu-system-x86_64-headless.exe".Replace('/','\\'),id[2],id[3]);
      KillOwned(root,"sdk/emulator/emulator.exe".Replace('/','\\'),id[0],id[1]);
      File.WriteAllText(Path.Combine(root,"fixture-backend-stopped.txt"),"stopped after frontend acknowledgment"); return 0;
    }
    string pipe=null,session=null,mode="good";
    for(int i=0;i<args.Length;i++) {
      if(args[i]=="--root") root=args[++i]; else if(args[i]=="--pipe") pipe=args[++i]; else if(args[i]=="--session") session=args[++i]; else if(args[i]=="--mode") mode=args[++i];
    }
    using(var server=new NamedPipeServerStream(pipe,PipeDirection.InOut,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous)) {
      File.WriteAllText(Path.Combine(root,"pipe-ready-"+session),"ready"); server.WaitForConnection();
      using(var reader=new StreamReader(server,Encoding.UTF8,false,1024,true)) using(var writer=new StreamWriter(server,new UTF8Encoding(false),1024,true)) {
        File.WriteAllText(Path.Combine(root,"pipe-request-"+session),reader.ReadLine()); writer.WriteLine((mode=="wrong"?"wrong:":"ready:")+session);writer.Flush();
      }
    }
    return 0;
  }
}
'@
    Add-Type -OutputAssembly $stubPath -OutputType WindowsApplication -TypeDefinition $stubSource
    $frontendExe = Join-Path $root 'update\frontend\ArtemisFrontend.exe'
    Copy-Item -LiteralPath $stubPath -Destination $frontendExe -Force
    Copy-Item -LiteralPath $stubPath -Destination (Join-Path $root 'sdk\emulator\emulator.exe')
    Copy-Item -LiteralPath $stubPath -Destination (Join-Path $root 'sdk\emulator\qemu\windows-x86_64\qemu-system-x86_64-headless.exe')
    Copy-Item -LiteralPath $stubPath -Destination (Join-Path $root 'sdk\platform-tools\adb.exe')
    . (Join-Path $root 'update\frontend-handoff.ps1')
    $backend = Start-OwnedProcess (Join-Path $root 'sdk\emulator\emulator.exe') @('-port','5584')
    Wait-File (Join-Path $root 'fixture-backend.txt')
    $backendIdentity = [IO.File]::ReadAllLines((Join-Path $root 'fixture-backend.txt'))
    $child = Get-Process -Id ([int]$backendIdentity[2]) -ErrorAction Stop
    $ownedProcesses += [pscustomobject]@{Process=$child;Path=(Join-Path $root 'sdk\emulator\qemu\windows-x86_64\qemu-system-x86_64-headless.exe');Ticks=[long]$backendIdentity[3]}
    $staging = Join-Path $root ('data\update\staged-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($staging)
    $futureFiles = @()
    foreach ($replacement in @(@{path='update/frontend/ArtemisFrontend.exe';bytes=[byte[]](@([IO.File]::ReadAllBytes($frontendExe)) + [byte]0)},@{path='version.ini';bytes=[Text.Encoding]::ASCII.GetBytes("[ArtemisOS]`r`nVersion=1.0.7`r`n")})) {
        $objectPath = Join-Path $fixture ([Guid]::NewGuid().ToString('N') + '.object')
        [IO.File]::WriteAllBytes($objectPath,[byte[]]$replacement.bytes)
        $hash = Hash $objectPath
        Move-Item -LiteralPath $objectPath -Destination (Join-Path $staging $hash)
        $futureFiles += [ordered]@{path=$replacement.path;base_sha256=(Hash (Join-Path $root $replacement.path));sha256=$hash;size=$replacement.bytes.Length}
    }
    $futureBytes = [Text.Encoding]::UTF8.GetBytes((([ordered]@{schema=1;product='ArtemisOS-15';from='1.0.6';to='1.0.7';notes='isolated future handoff regression; ephemeral test key';files=$futureFiles}) | ConvertTo-Json -Depth 7))
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(2048)
    $rsa.PersistKeyInCsp = $false
    try {
        [IO.File]::WriteAllText((Join-Path $root 'update\trusted-key.xml'),$rsa.ToXmlString($false))
        [IO.File]::WriteAllBytes((Join-Path $staging 'manifest.json'),$futureBytes)
        [IO.File]::WriteAllText((Join-Path $staging 'manifest.sig'),[Convert]::ToBase64String($rsa.SignData($futureBytes,'SHA256')))
    } finally { $rsa.Dispose() }
    foreach ($mode in @('wrong','good')) {
        $session = [Guid]::NewGuid().ToString('N')
        $pipe = Get-ArtemisFrontendPipeName $root $session
        $frontend = Start-OwnedProcess $frontendExe @('--root',$root,'--pipe',$pipe,'--session',$session,'--mode',$mode)
        Wait-File (Join-Path $root ('pipe-ready-' + $session))
        New-ArtemisFrontendSession -InstallRoot $root -SessionId $session -Serial 'emulator-5584' -EmulatorPid $backend.Id -EmulatorStartTimeUtcTicks $backendIdentity[1] -FrontendPid $frontend.Id -FrontendStartTimeUtcTicks ($frontend.StartTime.ToUniversalTime().Ticks.ToString()) -GraphicsOverride auto -GraphicsRenderer host -StdoutLog fixture-stdout -StderrLog fixture-stderr
        $future = Run-Script (Join-Path $root 'update\apply.ps1') @('-Staging',$staging,'-Serial','emulator-5584','-EmulatorPid',[string]$backend.Id,'-NoRestart')
        Assert ([IO.File]::Exists((Join-Path $root ('pipe-request-' + $session)))) ('The future updater did not reach the frontend handshake: ' + $future.Output)
        Assert ([IO.File]::ReadAllText((Join-Path $root ('pipe-request-' + $session))) -ceq ('prepare-update:' + $session)) 'The installed updater sent the wrong session-bound pipe request.'
        if ($mode -ceq 'wrong') {
            Assert ($future.Code -ne 0 -and -not $backend.HasExited -and (Get-UpdateVersion $root) -ceq '1.0.6' -and -not (Test-Path -LiteralPath (Join-Path $root 'data\update\pending')) -and -not [IO.File]::Exists((Join-Path $root 'fixture-backend-stopped.txt'))) ('Rejected handshake reached shutdown or replacement: ' + $future.Output)
        } else {
            Assert ($future.Code -eq 0 -and $frontend.WaitForExit(2000) -and $backend.WaitForExit(2000) -and $child.WaitForExit(2000) -and (Get-UpdateVersion $root) -ceq '1.0.7' -and (Hash $frontendExe) -ceq $futureFiles[0].sha256 -and [IO.File]::Exists((Join-Path $root 'data\update\pending\completed.flag'))) ('The installed updater failed the future frontend replacement: ' + $future.Output)
        }
        Assert-Data $data
    }
    $result.futureHandshake = [ordered]@{ok=$true;installedApplySha256=(Hash (Join-Path $root 'update\apply.ps1'));installedHelperSha256=(Hash (Join-Path $root 'update\frontend-handoff.ps1'));realNamedPipe=$true;realProcessIdentityAndCim=$true;wrongAckCancelsBeforeShutdown=$true;goodAckExitsFrontendBeforeReplacingExe=$true;backendStoppedByUpdaterOnly=$true;futureVersion='1.0.7';ephemeralTestKey=$true;fixtureFrontendAndBackend=$true;dataByteExact=$true}
    Write-Host 'PASS: installed 1.0.6 updater rejects a wrong handoff, then replaces the exited frontend in a signed future-update fixture.'
    $step = 'safe cleanup of the owned fixture installs'
    foreach ($root in $roots) { Remove-OwnedCase $root }
    foreach ($file in @(Get-ChildItem -LiteralPath $fixture -File -Force)) {
        if ($file.Name -cne 'result.json') { Remove-OwnedCase $file.FullName }
    }
    $result.fixturesCleaned = $true
    $result.ok = $true
} catch {
    $failure = $_
    $result.error = [ordered]@{step=$step;message=$_.Exception.Message}
} finally {
    foreach ($owned in $ownedProcesses) {
        $process = $owned.Process
        $process.Refresh()
        if (-not $process.HasExited) {
            Assert ($process.StartTime.ToUniversalTime().Ticks -eq $owned.Ticks -and $owned.Path.StartsWith(($fixture + '\'),[StringComparison]::OrdinalIgnoreCase) -and [string]::Equals($process.MainModule.FileName,$owned.Path,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe owned process cleanup.'
            $process.Kill(); [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
    }
    $result.completedUtc = [DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText($resultPath,($result | ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
    Write-Host ('Evidence: ' + $resultPath)
}
if ($null -ne $failure) { throw $failure }
Write-Host 'PASS: complete 1.0.5 to 1.0.6 payload, both published lineages, strict data preservation, signed no-update sentinel and future update handoff.'
