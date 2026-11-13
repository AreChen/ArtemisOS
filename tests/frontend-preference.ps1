$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
foreach($module in @('Microsoft.PowerShell.Utility','Microsoft.PowerShell.Management')){Import-Module (Join-Path $PSHOME ('Modules\'+$module+'\'+$module+'.psd1'))}
$project=Split-Path -Parent $PSScriptRoot
$fixture=Join-Path $project ('build\frontend-preference-tests\'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'data'))
foreach($name in @('settings.ps1','configure.ps1')){Copy-Item -LiteralPath (Join-Path $project ('stage\'+$name)) -Destination $fixture}
$checks=0
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Reject([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Assert $failed $Message}
. (Join-Path $fixture 'settings.ps1')
$defaults=Get-ArtemisPreferences
Assert ($defaults.PSObject.Properties.Name -contains 'Frontend' -and $defaults.Frontend -ceq 'artemis') 'A missing preference must default to the Artemis frontend.'
[IO.File]::WriteAllText($script:ArtemisPreferencesPath,"profile=medium`ncleanup=0`nvideo_compat=0`ncarrier=unicom`ngraphics=vulkan_intel`nresolution=1080p`nfuture_key=keep=all`nFuture.Key2=保留中文`nfrontend=unknown`n",[Text.Encoding]::UTF8)
Assert ((Get-ArtemisPreferences).Frontend -ceq 'artemis') 'Old preferences must use the Artemis frontend.'
& (Join-Path $fixture 'configure.ps1') -NoGui -SetFrontend native
$saved=Get-ArtemisPreferences
Assert ($saved.Frontend -ceq 'native' -and $saved.Profile -ceq 'medium' -and $saved.Graphics -ceq 'vulkan_intel' -and $saved.Resolution -ceq '1080p') 'Switching frontend changed unrelated preferences.'
Assert ((Read-ArtemisKeyValues $script:ArtemisPreferencesPath)['future_key'] -ceq 'keep=all') 'Unknown preference was dropped.'
foreach($arguments in @(@('low','1','1'),@('medium','0','0','telecom'),@('high','1','1','unicom','host','720p'))){Write-ArtemisPreferences @arguments;Assert ((Get-ArtemisPreferences).Frontend -ceq 'native') 'An old positional writer reset the native frontend.'}
& (Join-Path $fixture 'configure.ps1') -NoGui -SetProfile medium -SetResolution 1080p
Assert ((Get-ArtemisPreferences).Frontend -ceq 'native') 'Changing another setting reset the frontend.'
$before=[IO.File]::ReadAllText($script:ArtemisPreferencesPath)
Reject {Write-ArtemisPreferences 'low' '1' '1' 'mobile' 'host' '720p' 'bad'} 'Invalid frontend was accepted.'
Assert ([IO.File]::ReadAllText($script:ArtemisPreferencesPath) -ceq $before) 'Invalid frontend changed preferences.'
& (Join-Path $fixture 'configure.ps1') -NoGui -SetFrontend artemis
Assert ((Get-ArtemisPreferences).Frontend -ceq 'artemis') 'Switching back did not persist.'
Assert ((Read-ArtemisKeyValues $script:ArtemisPreferencesPath)['future_key'] -ceq 'keep=all') 'Later writes dropped unknown preference.'
Assert ((Read-ArtemisKeyValues $script:ArtemisPreferencesPath)['Future.Key2'] -ceq '保留中文') 'Unknown Unicode or extended-key preference changed.'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'stage\launch.ps1'),[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'Launch syntax failed.'
$function=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-ArtemisLaunchMode'},$false)
. ([scriptblock]::Create($function.Extent.Text))
foreach($preference in @('artemis','native')){foreach($available in @($false,$true)){foreach($headless in @($false,$true)){foreach($external in @($false,$true)){
    if($headless -and $external){Reject {Get-ArtemisLaunchMode -Headless -ExternalDisplay -FrontendAvailable:$available -Preference $preference} 'Conflicting modes accepted.';continue}
    $mode=Get-ArtemisLaunchMode -Headless:$headless -ExternalDisplay:$external -FrontendAvailable:$available -Preference $preference
    Assert ($mode.DelegateFrontend -eq ($preference -ceq 'artemis' -and $available -and -not $headless -and -not $external)) 'Incorrect delegation.'
    Assert ($mode.InitializeHeadless -eq ($headless -or $external) -and $mode.StartBridge -eq (-not $headless)) 'Initialization or bridge constraint changed.'
    if($headless){Assert (($mode.EmulatorArguments -join '|') -ceq '-no-window|-no-audio|-no-boot-anim') 'Headless arguments changed.'}elseif($external){Assert (($mode.EmulatorArguments -join '|') -ceq '-no-window') 'External display must remain hidden.'}else{Assert ($mode.EmulatorArguments.Count -eq 0) 'Native or ordinary mode hid its window.'}
}}}}
Assert ((Get-ArtemisLaunchMode -FrontendAvailable).DelegateFrontend) 'Default function callers lost old behavior.'
Reject {Get-ArtemisLaunchMode -Preference invalid} 'Unknown frontend launch preference accepted.'
# Execute the real launcher prefix, replacing only the native process boundary
# and later heavyweight startup. This proves preferences precede delegation and
# invalid ExternalDisplay identity still rejects even when native is selected.
$source=[IO.File]::ReadAllText((Join-Path $project 'stage\launch.ps1'))
$cut=$source.IndexOf('    $launchMutex = Enter-ArtemisLaunchLock $installRoot')
Assert ($cut -gt 0) 'Cannot find launch boundary.'
$prefix=$source.Substring(0,$cut)+"`n    [IO.File]::WriteAllText((Join-Path `$installRoot 'route.txt'),'native-runtime')`n} catch { [Console]::Error.WriteLine(`$_.Exception.Message); exit 17 }`n"
$prefix=$prefix.Replace("`$ErrorActionPreference = 'Stop'","`$ErrorActionPreference = 'Stop'`nfunction Start-Process { param(`$FilePath,`$ArgumentList,`$WorkingDirectory) [IO.File]::WriteAllText((Join-Path `$WorkingDirectory 'route.txt'),'artemis-frontend') }")
[IO.File]::WriteAllText((Join-Path $fixture 'launch.ps1'),$prefix,[Text.UTF8Encoding]::new($true))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'update\frontend'))
[IO.File]::WriteAllText((Join-Path $fixture 'update\frontend\ArtemisFrontend.exe'),'not-executable')
Copy-Item -LiteralPath (Join-Path $project 'stage\update\frontend-handoff.ps1') -Destination (Join-Path $fixture 'update')
foreach($choice in @('artemis','native')){
    & (Join-Path $fixture 'configure.ps1') -NoGui -SetFrontend $choice
    & rtk proxy powershell.exe -NoProfile -NonInteractive -File (Join-Path $fixture 'launch.ps1') -Port 5584
    Assert ($LASTEXITCODE -eq 0 -and [IO.File]::ReadAllText((Join-Path $fixture 'route.txt')) -ceq $(if($choice -eq 'native'){'native-runtime'}else{'artemis-frontend'})) 'Real launcher prefix ignored frontend preference.'
}
$old=$ErrorActionPreference
try{$ErrorActionPreference='Continue';$rejected=@(& rtk proxy powershell.exe -NoProfile -NonInteractive -File (Join-Path $fixture 'launch.ps1') -ExternalDisplay -SessionId invalid -FrontendPid 0 2>&1);$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
Assert ($code -eq 17 -and ($rejected -join ' ') -match '(?i)session|display|identity') 'Native preference bypassed external identity validation.'
Write-Output "PASS: $checks frontend preference and launch route checks. Fixture: $fixture"
