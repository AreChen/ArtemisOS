<# Repackage the frozen 1.0.7 product without changing its OTA baseline. #>
param([switch]$Compile)
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$release=Join-Path $project 'build\release-1.0.7-r2'
$package=Join-Path $release package
if(Test-Path -LiteralPath $package){throw 'Refusing to overwrite a prepared installer revision.'}
$original=Join-Path $project 'build\release-1.0.7-direct\package'
$sdk=Join-Path $project 'build\slim-sdk-1.0.4'
[void][IO.Directory]::CreateDirectory($package)
foreach($file in Get-ChildItem -LiteralPath $original -Recurse -File){
 if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unsafe frozen package.'}
 $relative=$file.FullName.Substring($original.Length+1)
 $target=Join-Path $package $relative
 [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
 [IO.File]::Copy($file.FullName,$target,$false)
}
foreach($relative in @('installer.iss','tools\InstallerUpgrade.iss','tools\InstallerOtaConfig.iss')){
 [IO.File]::Copy((Join-Path $project $relative),(Join-Path $package $relative),$true)
}
$manifest=Join-Path $package 'tools\installer-payload.ini'
& (Join-Path $PSScriptRoot 'Write-InstallerPayloadManifest.ps1') -PackageRoot $package -SdkRoot $sdk -OutputFile $manifest
$record=[ordered]@{version='1.0.7';installerRevision='r2';package=$package;sdk=$sdk;previousPackage=$original;managedProductUnchanged=$true;userDataIncluded=$false;manifestSha256=(Get-FileHash $manifest).Hash.ToLowerInvariant();preparedUtc=[DateTime]::UtcNow.ToString('o')}
[IO.File]::WriteAllText((Join-Path $release inputs.json),($record|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
if($Compile){
 $compiler=Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'
 $arguments=@('proxy',('"'+$compiler+'"'),'/Qp',('/DSdkSource="'+$sdk+'"'),'/DReleaseAppId=ArtemisOS15-Release','/DInstallerRevision=r2',('/DPayloadManifest="'+$manifest+'"'),'/DSparseImageSha256=ab633cc0504a61c6006cd39d2b371dff8e341f0176e70384597692d7d90a2752',('/O"'+$release+'"'),('"'+(Join-Path $package installer.iss)+'"'))
 $process=Start-Process (Get-Command rtk.exe).Source -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $release installer-build.log) -RedirectStandardError (Join-Path $release installer-build-error.log)
 Write-Output ('Installer revision build PID '+$process.Id)
}
