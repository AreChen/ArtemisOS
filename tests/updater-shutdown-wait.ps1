# Tests only the process-wait function with synthetic metadata; no emulator is stopped.
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'stage\update\apply.ps1'), [ref]$tokens, [ref]$errors)
if ($errors) { throw 'Updater script has syntax errors.' }
$function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-ArtemisRuntimeExit' }, $false)
if ($null -eq $function) { throw 'Process wait function was not found.' }
Invoke-Expression $function.Extent.Text

$sdk = Join-Path $project 'build\test-emulator-sdk'
$otherSdk = Join-Path $project 'build\other-emulator-sdk'
$filter = "Name='emulator.exe' OR Name='qemu-system-x86_64.exe'"
$helper = [pscustomobject]@{Name='emulator.exe';ExecutablePath=(Join-Path $sdk 'emulator.exe');ProcessId=11;CommandLine='emulator -kill 17 -sleep 20'}
$second = [pscustomobject]@{Name='emulator.exe';ExecutablePath=(Join-Path $sdk 'emulator.exe');ProcessId=12;CommandLine='emulator -kill 17 -sleep 20'}
$other = [pscustomobject]@{Name='emulator.exe';ExecutablePath=(Join-Path $otherSdk 'emulator.exe');ProcessId=13;CommandLine='emulator -port 5556'}
$qemu = [pscustomobject]@{Name='qemu-system-x86_64.exe';ExecutablePath=(Join-Path $sdk 'qemu\qemu-system-x86_64.exe');ProcessId=14;CommandLine='qemu -port 5554'}
$unknown = [pscustomobject]@{Name='emulator.exe';ExecutablePath=$null;ProcessId=15;CommandLine=''}
$invalid = [pscustomobject]@{Name='emulator.exe';ExecutablePath="bad`0path";ProcessId=16;CommandLine=''}
$script:snapshots = @()
$script:queries = 0
$script:sleeps = 0
$script:sleepDelay = 0
$script:queryFailure = $false
function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName,[string]$Filter)
    if ($script:queryFailure) { throw 'Synthetic CIM query failure.' }
    $position = [Math]::Min($script:queries, $script:snapshots.Count - 1)
    $script:queries++
    foreach ($item in @($script:snapshots[$position])) { if ($null -ne $item) { $item } }
}
function Start-Sleep {
    param([int]$Milliseconds)
    if ($Milliseconds -ne 500) { throw 'The existing 500 ms shutdown polling interval changed.' }
    $script:sleeps++
    if ($script:sleepDelay -gt 0) { [Threading.Thread]::Sleep($script:sleepDelay) }
}
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Rejected([scriptblock]$Action,[string]$Message) {
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    Assert $rejected $Message
}

$script:snapshots = @(@($helper,$second), @($helper), @())
$script:queries = 0; $script:sleeps = 0
Wait-ArtemisRuntimeExit $sdk $filter
Assert ($script:queries -eq 3 -and $script:sleeps -eq 2) 'Did not wait for both shutdown watchdogs to exit'

$script:snapshots = @(@($other))
$script:queries = 0; $script:sleeps = 0
Wait-ArtemisRuntimeExit $sdk $filter 0
Assert ($script:queries -eq 1 -and $script:sleeps -eq 0) 'Unrelated installation blocked the update'

$script:snapshots = @(@($qemu))
$script:queries = 0
Assert-Rejected { Wait-ArtemisRuntimeExit $sdk $filter 0 } 'Active QEMU was not rejected at timeout'

$script:snapshots = @(@($unknown))
$script:queries = 0
Assert-Rejected { Wait-ArtemisRuntimeExit $sdk $filter 0 } 'Unknown executable path was not rejected'

foreach ($unresolved in @($unknown,$invalid)) {
    $script:snapshots = @(@($unresolved), @())
    $script:queries = 0; $script:sleeps = 0
    Wait-ArtemisRuntimeExit $sdk $filter
    Assert ($script:queries -eq 2 -and $script:sleeps -eq 1) 'A terminating process with unavailable path metadata was not allowed to disappear'
}

$script:snapshots = @(@($unknown), @($helper), @())
$script:queries = 0; $script:sleeps = 0
Wait-ArtemisRuntimeExit $sdk $filter
Assert ($script:queries -eq 3 -and $script:sleeps -eq 2) 'A temporarily unknown process was not rechecked after its path became available'

foreach ($unresolved in @($unknown,$invalid)) {
    $script:snapshots = @(@($unresolved))
    $script:queries = 0; $script:sleeps = 0; $script:sleepDelay = 500
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $failure = $null
    try { Wait-ArtemisRuntimeExit $sdk $filter 1 }
    catch { $failure = $_.Exception.Message }
    finally { $timer.Stop(); $script:sleepDelay = 0 }
    Assert ($null -ne $failure) 'Persistent unavailable process metadata was accepted at timeout'
    Assert ($timer.ElapsedMilliseconds -ge 900 -and $script:queries -ge 3 -and $script:sleeps -ge 2) 'Unavailable metadata failed immediately instead of waiting until the deadline'
    Assert ($failure -match '超时' -and $failure -match '安装路径') 'Persistent unavailable metadata did not report the timeout and unresolved installation path'
}
$script:queryFailure = $true
try { Assert-Rejected { Wait-ArtemisRuntimeExit $sdk $filter } 'CIM query failure was allowed to approve replacement' }
finally { $script:queryFailure = $false }

$coreAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'stage\update\core.ps1'), [ref]$tokens, [ref]$errors)
if ($errors) { throw 'Updater core script has syntax errors.' }
$verification = $coreAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-VerifiedUpdateEmulator' }, $false)
if ($null -eq $verification) { throw 'Initial process verification function was not found.' }
Invoke-Expression $verification.Extent.Text
foreach ($unresolved in @($unknown,$invalid)) {
    Assert-Rejected { Get-VerifiedUpdateEmulator @($unresolved) $sdk 'emulator-5554' } 'Initial process ownership verification stopped rejecting unknown paths'
}
Write-Host 'PASS: updater waits through transient null/invalid paths and shutdown helpers, ignores verified other installs, and refuses active or unresolved processes at timeout.'
