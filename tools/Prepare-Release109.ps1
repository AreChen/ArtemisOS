param([switch]$Compile)
$ErrorActionPreference='Stop'
foreach($module in @('Microsoft.PowerShell.Utility','Microsoft.PowerShell.Management','Microsoft.PowerShell.Security')){Import-Module (Join-Path $PSHOME ('Modules\'+$module+'\'+$module+'.psd1'))}
$project=Split-Path -Parent $PSScriptRoot
$release=Join-Path $project 'build\release-1.0.9'
$package=Join-Path $release package
$previous=Join-Path $project 'build\release-1.0.8\package'
$sdk=Join-Path $project 'build\slim-sdk-1.0.4'
if(Test-Path -LiteralPath $package){throw 'Refusing to overwrite a frozen package.'}
if((Get-Content (Join-Path $project 'stage\version.ini') -Raw) -notmatch '(?m)^Version=1\.0\.9\s*$'){throw 'Expected source version 1.0.9.'}
$changed=@('configure.ps1','launch.ps1','settings.ps1','version.ini','update\frontend\runtime\scrcpy-server','update\frontend\third-party\NOTICE.txt','update\frontend\third-party\sources.json')
$secureSource=Join-Path $project 'stage\update\frontend\third-party\artemis-display'
foreach($file in Get-ChildItem -LiteralPath $secureSource -Recurse -File){$changed+='update\frontend\third-party\artemis-display\'+$file.FullName.Substring($secureSource.Length+1)}
foreach($relative in @('installer.iss','tools\InstallerUpgrade.iss','tools\InstallerOtaConfig.iss')){
 if((Get-FileHash (Join-Path $project $relative)).Hash -cne (Get-FileHash (Join-Path $previous $relative)).Hash){throw ('Installer source differs: '+$relative)}
}
[void][IO.Directory]::CreateDirectory($package)
foreach($file in Get-ChildItem -LiteralPath $previous -Recurse -File){
 if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unsafe frozen input.'}
 $relative=$file.FullName.Substring($previous.Length+1)
 if($relative -in @('tools\installer-payload.ini','tools\installer-payload-pre-bom.ini')){continue}
 $target=Join-Path $package $relative
 [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
 [IO.File]::Copy($file.FullName,$target,$false)
}
foreach($relative in $changed){
 $target=Join-Path $package ('stage\'+$relative)
 [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
 [IO.File]::Copy((Join-Path $project ('stage\'+$relative)),$target,$true)
}
$stage=Join-Path $package stage
foreach($file in Get-ChildItem -LiteralPath (Join-Path $previous stage) -Recurse -File){
 $relative=$file.FullName.Substring((Join-Path $previous stage).Length+1)
 if($relative -notin $changed -and (Get-FileHash $file.FullName).Hash -cne (Get-FileHash (Join-Path $stage $relative)).Hash){throw ('Unrelated product change: '+$relative)}
}
$secure=Get-Content (Join-Path $stage 'update\frontend\third-party\artemis-display\manifest.json') -Raw|ConvertFrom-Json
if($secure.revision -cne 'artemis-secure-display-r2' -or $secure.serverSha256 -cne (Get-FileHash (Join-Path $stage 'update\frontend\runtime\scrcpy-server')).Hash.ToLowerInvariant()){throw 'Wrong secure display build.'}
$manifest=Join-Path $package 'tools\installer-payload.ini'
& (Join-Path $PSScriptRoot 'Write-InstallerPayloadManifest.ps1') -PackageRoot $package -SdkRoot $sdk -OutputFile $manifest
$inputs=[ordered]@{version='1.0.9';package=$package;sdk=$sdk;previousPackage=$previous;changedProductFiles=$changed;runtime='37.3.9 Beta';systemImageSha256='ab633cc0504a61c6006cd39d2b371dff8e341f0176e70384597692d7d90a2752';secureServerSha256=$secure.serverSha256;userDataIncluded=$false;installerSourceSha256=(Get-FileHash (Join-Path $package installer.iss)).Hash.ToLowerInvariant();upgradeHelperSha256=(Get-FileHash (Join-Path $package 'tools\InstallerUpgrade.iss')).Hash.ToLowerInvariant();manifestSha256=(Get-FileHash $manifest).Hash.ToLowerInvariant();published=$false;preparedUtc=[DateTime]::UtcNow.ToString('o')}
[IO.File]::WriteAllText((Join-Path $release inputs.json),($inputs|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
Write-Output ('Frozen 1.0.9 package ready: '+$changed.Count+' changed product files.')
if($Compile){
 $compiler=Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'
 & rtk proxy $compiler /Qp ('/DSdkSource='+$sdk) /DReleaseAppId=ArtemisOS15-Release ('/DPayloadManifest='+$manifest) ('/DSparseImageSha256='+$inputs.systemImageSha256) ('/O'+$release) (Join-Path $package installer.iss)
 $code=$LASTEXITCODE
 [IO.File]::WriteAllText((Join-Path $release compiler-result.json),(@{exitCode=$code;finishedUtc=[DateTime]::UtcNow.ToString('o');helperSha256=$inputs.upgradeHelperSha256}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 exit $code
}
