param([string]$Version='1.0.7')
$ErrorActionPreference='Stop'
foreach($module in @('Microsoft.PowerShell.Utility','Microsoft.PowerShell.Management','Microsoft.PowerShell.Security')){Import-Module (Join-Path $PSHOME ('Modules\'+$module+'\'+$module+'.psd1')) -ErrorAction Stop}
if($Version -cne '1.0.7'){throw 'This release recipe is pinned to 1.0.7.'}
$project=Split-Path -Parent $PSScriptRoot
$release=Join-Path $project 'build\release-1.0.7-direct'
$package=Join-Path $release 'package'
if(Test-Path -LiteralPath $package){throw 'Never overwrite a prepared release.'}
$baseline=Join-Path $project 'releases\1.0.6'
$preview=Join-Path $project 'build\sunshine-display-20261112\frontend'
if((Get-FileHash (Join-Path $preview 'ArtemisFrontend.exe')).Hash -cne 'DD30EAD542C75B8424BC64544F2ADAD85E11243C775EC5A9DF0EED9C6771DBFD'){throw 'Unexpected frontend.'}
[void][IO.Directory]::CreateDirectory($package)
foreach($folder in @('stage','tools')){[void][IO.Directory]::CreateDirectory((Join-Path $package $folder))}
foreach($file in @(Get-ChildItem $baseline -File | Where-Object Name -notin @('ota-baseline.json','server.txt')) + @(Get-ChildItem (Join-Path $baseline update) -File -Recurse) + @(Get-ChildItem (Join-Path $baseline licenses) -File -Recurse)){
 if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unsafe baseline.'}
 $relative=$file.FullName.Substring($baseline.Length+1)
 $target=Join-Path $package ('stage\'+$relative)
 [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
 [IO.File]::Copy($file.FullName,$target,$false)
}
foreach($relative in @('update\core.ps1','update\server.txt','carrier-operators.xml','ArtemisOS15-wizard.png','ArtemisOS15-banner.bmp')){
 [IO.File]::Copy((Join-Path $project ('stage\'+$relative)),(Join-Path $package ('stage\'+$relative)),$true)
}
foreach($name in @('ArtemisFrontend.exe','ArtemisFrontend.pdb')){[IO.File]::Copy((Join-Path $preview $name),(Join-Path $package ('stage\update\frontend\'+$name)),$true)}
[IO.File]::WriteAllText((Join-Path $package 'stage\version.ini'),"[ArtemisOS]`r`nVersion=$Version`r`n",[Text.Encoding]::ASCII)
foreach($file in @('installer.iss','ChineseSimplified.isl','tools\InstallerOtaConfig.iss','tools\Optimize-SparseFreshInstall.ps1')){[IO.File]::Copy((Join-Path $project $file),(Join-Path $package $file),$false)}
$old='https://cloudx.playones.com/sd/YCsIY2UB/sources/ArtemisOS15-Display-Sources-1.0.6.zip?d'
$new='https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/sources/ArtemisOS15-Display-Sources-1.0.6.zip'
foreach($relative in @('update\frontend\third-party\NOTICE.txt','update\frontend\third-party\sources.json')){
 $file=Join-Path $package ('stage\'+$relative)
 [IO.File]::WriteAllText($file,([IO.File]::ReadAllText($file).Replace($old,$new)),[Text.UTF8Encoding]::new($false))
}
$inputRecord=[ordered]@{version=$Version;package=$package;baseline=$baseline;sdk=(Join-Path $project 'build\slim-sdk-1.0.4');runtime='37.3.9 Beta';systemImageSha256='ab633cc0504a61c6006cd39d2b371dff8e341f0176e70384597692d7d90a2752';frontendSha256=(Get-FileHash (Join-Path $package 'stage\update\frontend\ArtemisFrontend.exe')).Hash.ToLowerInvariant();coreSha256=(Get-FileHash (Join-Path $package 'stage\update\core.ps1')).Hash.ToLowerInvariant();otaBase=([IO.File]::ReadAllText((Join-Path $package 'stage\update\server.txt')).Trim());dataIncluded=$false;upgradePrototypeIncluded=$false;preparedUtc=[DateTime]::UtcNow.ToString('o')}
[IO.File]::WriteAllText((Join-Path $release 'inputs.json'),($inputRecord|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
$compiler=Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'
$args=@('proxy',('"'+$compiler+'"'),'/Qp',('/DSdkSource="'+$inputRecord.sdk+'"'),'/DReleaseAppId=ArtemisOS15-Release',('/DSparseImageSha256='+$inputRecord.systemImageSha256),('/O"'+$release+'"'),('"'+(Join-Path $package 'installer.iss')+'"'))
$process=Start-Process -FilePath (Get-Command rtk.exe).Source -ArgumentList $args -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $release 'installer-build.log') -RedirectStandardError (Join-Path $release 'installer-build-error.log')
Write-Output ('Build started PID '+$process.Id+'; inputs: '+(Join-Path $release 'inputs.json'))
