$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
foreach($module in @('Microsoft.PowerShell.Utility','Microsoft.PowerShell.Management','Microsoft.PowerShell.Security')){Import-Module (Join-Path $PSHOME ('Modules\'+$module+'\'+$module+'.psd1')) -ErrorAction Stop}
$project=Split-Path -Parent $PSScriptRoot
$release=Join-Path $project 'build\release-1.1.1'
$previous=Join-Path $project 'releases\1.1.0'
$stage=Join-Path $project stage
$target=Join-Path $release 'package\stage'
$approved=@('configure.ps1','settings.ps1','version.ini','update/frontend/ArtemisFrontend.exe')
$nonShippedSourceFiles=@('ArtemisOS15-banner.bmp','ArtemisOS15-wizard.png','carrier-operators.xml','update/test-marker.txt')
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Product-Files([string]$Root){
 $files=@(Get-ChildItem -LiteralPath $Root -File)
 foreach($directory in Get-ChildItem -LiteralPath $Root -Directory){
  if($directory.Name -in @('sdk','data')){continue}
  if($directory.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Product directories cannot be reparse points.'}
  $files+=@(Get-ChildItem -LiteralPath $directory.FullName -File -Recurse)
 }
 return $files
}
if(Test-Path -LiteralPath $target){throw 'Refusing to overwrite a frozen OTA target.'}
if((Get-Content -Encoding UTF8 (Join-Path $stage version.ini) -Raw) -notmatch '(?m)^Version=1\.1\.1\s*$' -or
 (Get-Content -Encoding UTF8 (Join-Path $previous version.ini) -Raw) -notmatch '(?m)^Version=1\.1\.0\s*$'){throw 'Expected source 1.1.1 and frozen baseline 1.1.0.'}
$baseFiles=@{};$sourceFiles=@{}
foreach($file in Product-Files $previous){
 $relative=$file.FullName.Substring($previous.Length+1).Replace('\','/');$baseFiles[$relative]=$file.FullName
 # Keep the already released symbol bytes in the frozen inventory. New build
 # symbols are development outputs and must never become a fifth OTA object.
 if($file.Extension -ieq '.pdb'){$sourceFiles[$relative]=$file.FullName}
}
foreach($file in Product-Files $stage){
 if($file.Extension -ieq '.pdb'){continue}
 if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Source product files cannot be reparse points.'}
 $relative=$file.FullName.Substring($stage.Length+1).Replace('\','/')
 if($relative -in $nonShippedSourceFiles){continue}
 if(-not $baseFiles.ContainsKey($relative)){throw ('Unreviewed additional product file: '+$relative)}
 $sourceFiles[$relative]=$file.FullName
}
if($baseFiles.Count -eq 0 -or $baseFiles.Count -ne $sourceFiles.Count){throw 'Baseline/source product inventory differs.'}
foreach($relative in $baseFiles.Keys){
 if(-not $sourceFiles.ContainsKey($relative)){throw ('Product file missing from source: '+$relative)}
 if($relative -cnotin $approved -and (Hash $baseFiles[$relative]) -cne (Hash $sourceFiles[$relative])){throw ('Unreviewed product change: '+$relative)}
}
foreach($relative in $approved){if((Hash $sourceFiles[$relative]) -ceq (Hash $baseFiles[$relative])){throw ('Reviewed payload has not changed yet: '+$relative)}}
$inventory=[ordered]@{}
foreach($relative in ($baseFiles.Keys|Sort-Object)){
 $source=if($relative -cin $approved){$sourceFiles[$relative]}else{$baseFiles[$relative]}
 if((Get-Item -LiteralPath $source).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Frozen product files cannot be reparse points.'}
 $output=Join-Path $target $relative
 [void][IO.Directory]::CreateDirectory((Split-Path -Parent $output))
 # Independent copies are essential: the new frontend must never rewrite an
 # executable hardlinked to an old baseline or to a currently running install.
 [IO.File]::Copy($source,$output,$false)
 $inventory[$relative]=Hash $output
 if($inventory[$relative] -cne (Hash $source)){throw ('Copy changed: '+$relative)}
}
$prior=Get-Content -Encoding UTF8 (Join-Path $project 'build\release-1.1.0\build-result.json') -Raw|ConvertFrom-Json
if($inventory['update/frontend/runtime/scrcpy-server'] -cne $prior.secureServerSha256){throw 'Secure display server changed outside the reviewed payload.'}
$record=[ordered]@{version='1.1.1';from='1.1.0';targetRoot=$target;previousRoot=$previous;changedProductFiles=$approved;fileHashes=$inventory;sdkIncluded=$false;systemImageUnchanged=$true;runtimeUnchanged=$true;frontendBinaryChanged=$true;secureServerSha256=$prior.secureServerSha256;sourceUrl=$prior.sourceUrl;sourceSha256=$prior.sourceSha256;sourceEvidenceReusedFrom='1.0.9';defaultMaxFps=60;maxFpsMinimum=1;maxFpsMaximum=240;userDataIncluded=$false;androidStarted=$false;liveInstallationModified=$false;amdHardwareVerified=$false;published=$false;preparedUtc=[DateTime]::UtcNow.ToString('o')}
[IO.File]::WriteAllText((Join-Path $release inputs.json),($record|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
Write-Output ('Frozen OTA-only 1.1.1 target ready: '+$approved.Count+' replacements; independent product copies, no SDK or Android startup.')
