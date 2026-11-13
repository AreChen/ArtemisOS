param([string]$Repository,[string]$TargetRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
foreach($module in @('Microsoft.PowerShell.Utility','Microsoft.PowerShell.Management')){Import-Module (Join-Path $PSHOME ('Modules\'+$module+'\'+$module+'.psd1')) -ErrorAction Stop}
$project=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
if(-not $Repository){$Repository=Join-Path $project 'build\release-1.0.7\repository'}
if(-not $TargetRoot){$TargetRoot=Join-Path $project 'build\release-1.0.7\target'}
$fixture=Join-Path $project ('build\display-recovery-ota-tests\'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
function Assert([bool]$ok,[string]$message){if(-not $ok){throw $message}}
function Hash([string]$path){if(-not [IO.File]::Exists($path)){return '-'};(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()}
function Copy-Small([string]$source,[string]$destination){
    Assert (-not (Test-Path -LiteralPath $destination)) 'Use a new isolated install.'
    $files=@(Get-ChildItem -LiteralPath $source -File|Where-Object Name -notin @('server.txt','ota-baseline.json'))+@(Get-ChildItem -LiteralPath (Join-Path $source 'update') -File -Recurse)
    foreach($file in $files){
        Assert (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Reparse input not supported.'
        $relative=$file.FullName.Substring($source.Length+1)
        $output=Join-Path $destination $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $output))
        [IO.File]::Copy($file.FullName,$output,$false)
    }
}
function Add-PreservedData([string]$root){
    $data=@{'data\preferences.ini'="profile=medium`r`ngraphics=vulkan`r`ncarrier=unicom`r`nresolution=1080p`r`n";'data\setup-state.ini'="locale=1`r`nnetwork=1`r`nlauncher_rotation=1`r`n";'data\avd\preserved-marker.bin'='application-data-must-survive'}
    $hashes=@{}
    foreach($relative in $data.Keys){$path=Join-Path $root $relative;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $path));[IO.File]::WriteAllText($path,$data[$relative],[Text.Encoding]::ASCII);$hashes[$relative]=Hash $path}
    return $hashes
}
function Stage([string]$root,$manifest){
    $staging=Join-Path $root ('data\update\staged-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($staging)
    [IO.File]::Copy((Join-Path $Repository 'manifests\1.0.6.json'),(Join-Path $staging 'manifest.json'),$false)
    [IO.File]::Copy((Join-Path $Repository 'manifests\1.0.6.sig'),(Join-Path $staging 'manifest.sig'),$false)
    foreach($entry in $manifest.files){[IO.File]::Copy((Join-Path $Repository ('objects\'+$entry.sha256)),(Join-Path $staging $entry.sha256),$false)}
    return $staging
}
function Apply([string]$root,[string]$staging){
    $old=$ErrorActionPreference
    try{$ErrorActionPreference='Continue';$output=@(& rtk proxy powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'update\apply.ps1') -Staging $staging -Serial emulator-5584 -NoRestart 2>&1);$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
    [IO.File]::WriteAllText((Join-Path $root 'apply-output.log'),($output -join "`r`n"),[Text.UTF8Encoding]::new($false))
    return $code
}
$raw=Get-Content -LiteralPath (Join-Path $Repository 'manifests\1.0.6.json') -Raw|ConvertFrom-Json
$expected=@('update/frontend/ArtemisFrontend.exe','update/frontend/ArtemisFrontend.pdb','version.ini')
Assert ((($raw.files.path|Sort-Object) -join '|') -ceq (($expected|Sort-Object) -join '|')) 'Unexpected release payload.'
foreach($entry in $raw.files){Assert ((Hash (Join-Path $Repository ('objects\'+$entry.sha256))) -ceq $entry.sha256 -and (Hash (Join-Path $TargetRoot $entry.path)) -ceq $entry.sha256) 'Signed object differs from target.'}
$cases=@()
foreach($name in @('1.0.6','1.0.6-ota','1.0.6-ota-from-full')){
    $source=Join-Path $project ('releases\'+$name)
    $root=Join-Path $fixture $name
    Copy-Small $source $root
    $dataBefore=Add-PreservedData $root
    $preserved=@{}
    foreach($file in @(Get-ChildItem -LiteralPath $root -File)+@(Get-ChildItem -LiteralPath (Join-Path $root 'update') -File -Recurse)){
        $relative=$file.FullName.Substring($root.Length+1).Replace('\','/')
        if($relative -cnotin $expected){$preserved[$relative]=Hash $file.FullName}
    }
    . (Join-Path $root 'update\core.ps1')
    $manifest=Verify-UpdateManifest $root ([IO.File]::ReadAllBytes((Join-Path $Repository 'manifests\1.0.6.json'))) ([IO.File]::ReadAllBytes((Join-Path $Repository 'manifests\1.0.6.sig')))
    Assert ($manifest.from -ceq '1.0.6' -and $manifest.to -ceq '1.0.7') 'Unexpected transition.'
    foreach($entry in $manifest.files){Assert ((Hash (Get-UpdateTarget $root $entry.path)) -ceq $entry.base_sha256) ('Published baseline conflict: '+$name+'/'+$entry.path)}
    $staging=Stage $root $manifest
    Assert ((Apply $root $staging) -eq 0) ('Old apply failed; see '+$root)
    Assert ((Get-UpdateVersion $root) -ceq '1.0.7') 'Version commit failed.'
    foreach($entry in $manifest.files){Assert ((Hash (Get-UpdateTarget $root $entry.path)) -ceq $entry.sha256) 'An installed object differs.'}
    foreach($relative in $preserved.Keys){Assert ((Hash (Join-Path $root $relative)) -ceq $preserved[$relative]) ('Unrelated release file changed: '+$relative)}
    foreach($relative in $dataBefore.Keys){Assert ((Hash (Join-Path $root $relative)) -ceq $dataBefore[$relative]) 'User data changed.'}
    $journal=Get-Content -LiteralPath (Join-Path $root 'data\update\pending\transaction.json') -Raw|ConvertFrom-Json
    Assert ($journal.to -ceq '1.0.7' -and $journal.files.Count -eq 3 -and $journal.files[-1].path -ceq 'version.ini') 'Invalid rollback journal.'
    foreach($entry in $journal.files){Assert ((Hash (Join-Path $root ('data\update\pending\'+$entry.backup))) -ceq $entry.sha256) 'Invalid rollback copy.'}
    if([IO.File]::Exists((Join-Path $root 'update\launch-current.ps1'))){
        & rtk proxy powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'update\launch-current.ps1') -NoLaunch -Headless
        Assert ($LASTEXITCODE -eq 0 -and (Get-UpdateVersion $root) -ceq '1.0.7') 'Legacy launcher migration overwrote the new release.'
    }
    $sentinel=Verify-UpdateManifest $root ([IO.File]::ReadAllBytes((Join-Path $Repository 'manifests\1.0.7.json'))) ([IO.File]::ReadAllBytes((Join-Path $Repository 'manifests\1.0.7.sig'))) -AllowNoUpdate
    Assert ($sentinel.from -ceq '1.0.7' -and $sentinel.to -ceq '1.0.7' -and $sentinel.files.Count -eq 0) 'Invalid target sentinel.'
    $export=Join-Path $fixture ('validated-'+$name.Replace('1.0.6','1.0.7'))
    Copy-Small $root $export
    $cases+=[ordered]@{baseline=$name;ok=$true;root=$root;export=$export;signed=$true;realFrozenApply=$true;installedObjects=3;rollbackCopies=3;unrelatedFilesPreserved=$preserved.Count;dataPreserved=$true}
    Write-Output ('PASS signed OTA: '+$name+' -> 1.0.7, data, legacy entries and unrelated files preserved.')
}
$root=Join-Path $fixture 'modified-frontend'
Copy-Small (Join-Path $project 'releases\1.0.6') $root
$dataBefore=Add-PreservedData $root
[IO.File]::AppendAllText((Join-Path $root 'update\frontend\ArtemisFrontend.exe'),'local-modification',[Text.Encoding]::ASCII)
$modified=Hash (Join-Path $root 'update\frontend\ArtemisFrontend.exe')
$staging=Stage $root $raw
Assert ((Apply $root $staging) -ne 0 -and (Get-UpdateVersion $root) -ceq '1.0.6' -and (Hash (Join-Path $root 'update\frontend\ArtemisFrontend.exe')) -ceq $modified) 'Unknown frontend was accepted or partially overwritten.'
Assert (-not (Test-Path -LiteralPath (Join-Path $root 'data\update\pending'))) 'Rejected update created a file transaction.'
foreach($relative in $dataBefore.Keys){Assert ((Hash (Join-Path $root $relative)) -ceq $dataBefore[$relative]) 'Rejected update altered user data.'}
$result=[ordered]@{ok=$true;from='1.0.6';to='1.0.7';fixture=$fixture;manifestSha256=(Hash (Join-Path $Repository 'manifests\1.0.6.json'));downloadBytes=[long](($raw.files|Measure-Object size -Sum).Sum);cases=$cases;modifiedFrontendRejected=$true;sdkIncluded=$false;androidStarted=$false;completedUtc=[DateTime]::UtcNow.ToString('o')}
[IO.File]::WriteAllText((Join-Path $project 'build\release-1.0.7\ota-test-result.json'),($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
Write-Output ('PASS: three frozen 1.0.6 lineages, strict modified-file rejection; evidence '+$fixture)
