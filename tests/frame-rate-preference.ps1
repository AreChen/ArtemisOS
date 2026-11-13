param([string]$SourceRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
foreach ($module in @('Microsoft.PowerShell.Utility','Microsoft.PowerShell.Management')) {
    Import-Module (Join-Path $PSHOME ('Modules\'+$module+'\'+$module+'.psd1'))
}
$project = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrEmpty($SourceRoot)) { $SourceRoot = Join-Path $project 'stage' }
$fixtureParent = Join-Path $project 'build\frame-rate-preference-tests'
$fixture = Join-Path $fixtureParent ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'data'))
$checks = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }; $script:checks++
}
function Reject([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert $rejected $Message
}
try {
    foreach ($name in @('settings.ps1','configure.ps1')) {
        Copy-Item -LiteralPath (Join-Path $SourceRoot $name) -Destination $fixture
    }
    . (Join-Path $fixture 'settings.ps1')
    $defaults = Get-ArtemisPreferences
    Assert ($defaults.PSObject.Properties.Name -contains 'MaxFps' -and $defaults.MaxFps -is [int] -and $defaults.MaxFps -eq 60) 'A missing preference must expose integer MaxFps=60.'
    foreach ($value in 1..240) { Assert (Test-ArtemisMaxFps ([string]$value)) ('A valid frame rate was rejected: '+$value) }
    $invalid = @($null,'',' ','0','00','01','060','241','999','2147483648','999999999999999999999999','-1','+60','60.0','6e1','0x3c','NaN',' 60','60 ',"`t60","60`t","60`n","60`r`n",'６０','٦٠','60;whoami','60&whoami','$(whoami)')
    foreach ($value in $invalid) { Assert (-not (Test-ArtemisMaxFps $value)) ('A noncanonical frame rate was accepted: '+[string]$value) }
    foreach ($value in @('',' ','0','01','241','60.0','+60',' 60','60 ','６０','60;whoami')) {
        [IO.File]::WriteAllText($script:ArtemisPreferencesPath, ('max_fps='+$value+"`n"), [Text.Encoding]::UTF8)
        Assert ((Get-ArtemisPreferences).MaxFps -eq 60) 'A malformed stored frame rate did not fall back to 60.'
    }
    foreach ($sample in @(@("max_fps=30`nmax_fps=120`n",120),@("max_fps=120`nmax_fps=bad`n",60),@("max_fps=bad`nmax_fps=30`n",30),@("MAX_FPS=120`n",120),@(" max_fps=120`n",60))) {
        [IO.File]::WriteAllText($script:ArtemisPreferencesPath, $sample[0], [Text.Encoding]::UTF8)
        Assert ((Get-ArtemisPreferences).MaxFps -eq $sample[1]) 'Stored duplicate-key or exact-key semantics changed.'
    }
    $device = 'PCI\VEN_1002&DEV_150E&SUBSYS_00000000&REV_C1\4&12345678&0&0041'
    Write-ArtemisPreferences 'medium' '0' '1' 'unicom' 'vulkan_amd' '1080p' 'native' $device '120'
    [IO.File]::AppendAllText($script:ArtemisPreferencesPath, "future_key=keep=all`nFuture.Key2=保留中文`n", [Text.Encoding]::UTF8)
    Assert ((Read-ArtemisKeyValues $script:ArtemisPreferencesPath)['max_fps'] -ceq '120') 'The explicit frame rate was not persisted canonically.'
    foreach ($arguments in @(@('low','1','1'),@('medium','0','0','telecom'),@('high','1','1','unicom','vulkan_amd','720p'),@('high','1','1','unicom','vulkan_amd','720p','native',$device))) {
        Write-ArtemisPreferences @arguments
        $saved = Get-ArtemisPreferences
        Assert ($saved.MaxFps -eq 120 -and $saved.GraphicsDevice -ceq $device -and $saved.Frontend -ceq 'native') 'A legacy positional writer reset FPS, selected GPU or frontend.'
    }
    & (Join-Path $fixture 'configure.ps1') -NoGui -SetGraphics vulkan_amd -SetGraphicsDevice $device -SetMaxFps '144'
    & (Join-Path $fixture 'configure.ps1') -NoGui -SetProfile medium
    $saved = Get-ArtemisPreferences
    Assert ($saved.MaxFps -eq 144 -and $saved.Graphics -ceq 'vulkan_amd' -and $saved.GraphicsDevice -ceq $device -and $saved.Frontend -ceq 'native' -and $saved.Profile -ceq 'medium') 'NoGui FPS configuration changed unrelated settings or failed to persist.'
    $values = Read-ArtemisKeyValues $script:ArtemisPreferencesPath
    Assert ($values['future_key'] -ceq 'keep=all' -and $values['Future.Key2'] -ceq '保留中文') 'FPS configuration lost unknown preference keys.'
    foreach ($value in $invalid) {
        $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:ArtemisPreferencesPath))
        Reject { Write-ArtemisPreferences 'high' '1' '1' 'unicom' 'vulkan_amd' '720p' 'native' $device $value } 'A writer accepted an invalid explicit frame rate.'
        Reject { & (Join-Path $fixture 'configure.ps1') -NoGui -SetMaxFps $value } 'NoGui accepted an invalid explicit frame rate.'
        Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($script:ArtemisPreferencesPath)) -ceq $before) 'Rejected configuration changed preferences.'
    }
    foreach ($value in @('1','20','30','60','90','120','144','240')) {
        & (Join-Path $fixture 'configure.ps1') -NoGui -SetMaxFps $value
        Assert ((Get-ArtemisPreferences).MaxFps -eq [int]$value) 'A valid custom frame rate failed NoGui roundtrip.'
    }
    Write-Output "PASS: $checks strict FPS validation, defaults, legacy writes, isolated NoGui and preference preservation checks. No running instance touched."
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture).TrimEnd('\')
    $allowed = [IO.Path]::GetFullPath($fixtureParent).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe FPS fixture cleanup.' }
    if (Test-Path -LiteralPath $resolved) {
        if ((Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unexpected FPS fixture reparse point.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
