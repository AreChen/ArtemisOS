$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$project = Split-Path -Parent $PSScriptRoot
$makeSdCard = Join-Path $project 'stage\sdk\emulator\mksdcard.exe'
if (-not (Test-Path -LiteralPath $makeSdCard -PathType Leaf)) { throw 'Missing fixture mksdcard tool.' }
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'stage\launch.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Launch script has a PowerShell syntax error.' }
$definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ArtemisSdCard' }, $false)
if ($null -eq $definition) { throw 'SD card function was not found.' }
Invoke-Expression $definition.Extent.Text
$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$work = Join-Path $parent ('artemisos-sdcard-fixture-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
[IO.File]::WriteAllText((Join-Path $work '.fixture-only'), 'fixture')
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    Write-Host "PASS: $Message"
}
function New-Dir([string]$Name) {
    $dir = Join-Path $work $Name
    [void][IO.Directory]::CreateDirectory($dir)
    return $dir
}
function Assert-Blocked([scriptblock]$Action, [string]$Message) {
    $blocked = $false
    try { & $Action | Out-Null } catch { $blocked = $true }
    Assert $blocked $Message
}
try {
    # The helper receives 16 MiB only in this fixture. The launcher's real
    # call omits that test parameter, so its declared default remains 1 GiB.
    $avd = New-Dir 'avd with spaces'
    $sd = Get-ArtemisSdCard $avd @('sdcard.path=') $makeSdCard 16MB
    Assert ((Get-Item -LiteralPath $sd).Length -eq 16MB -and (Split-Path -Leaf $sd) -eq 'sdcard.img') 'new image is created at the AVD path'
    $hash = (Get-FileHash -LiteralPath $sd -Algorithm SHA256).Hash
    $again = Get-ArtemisSdCard $avd @('hw.sdCard.path=""') $makeSdCard 16MB
    Assert ($again -eq $sd -and (Get-FileHash -LiteralPath $sd -Algorithm SHA256).Hash -eq $hash) 'existing image is reused without rewriting'

    $customAvd = New-Dir 'custom'
    $relativeCard = Join-Path $customAvd 'custom card.img'
    [IO.File]::Copy($sd, $relativeCard)
    $configured = Get-ArtemisSdCard $customAvd @('sdcard.path=custom card.img', ('hw.sdCard.path=' + $relativeCard)) $makeSdCard 16MB
    Assert ($configured -eq $relativeCard -and (Get-FileHash -LiteralPath $configured -Algorithm SHA256).Hash -eq $hash -and
        -not (Test-Path -LiteralPath (Join-Path $customAvd 'sdcard.img'))) 'both custom path forms are retained'

    $missing = New-Dir 'missing-custom'
    Assert-Blocked { Get-ArtemisSdCard $missing @('sdcard.path=missing.img') $makeSdCard 16MB } 'missing custom image blocks creation'
    Assert (-not (Test-Path -LiteralPath (Join-Path $missing 'sdcard.img'))) 'missing custom image remains untouched'

    $conflicting = New-Dir 'conflicting'
    Assert-Blocked { Get-ArtemisSdCard $conflicting @('sdcard.path=first.img','hw.sdCard.path=second.img') $makeSdCard 16MB } 'conflicting custom paths are rejected'

    $damaged = New-Dir 'damaged'
    $damagedPath = Join-Path $damaged 'sdcard.img'
    [IO.File]::WriteAllText($damagedPath, 'keep this damaged card')
    Assert-Blocked { Get-ArtemisSdCard $damaged @() $makeSdCard 16MB } 'damaged existing image is rejected'
    Assert ([IO.File]::ReadAllText($damagedPath) -ceq 'keep this damaged card') 'damaged image is not recreated'

    $overlay = New-Dir 'orphan-overlay'
    [IO.File]::WriteAllText((Join-Path $overlay 'sdcard.img.qcow2'), 'keep overlay')
    Assert-Blocked { Get-ArtemisSdCard $overlay @() $makeSdCard 16MB } 'an orphan overlay blocks creation'
    Assert (-not (Test-Path -LiteralPath (Join-Path $overlay 'sdcard.img'))) 'orphan overlay does not cause a new base image'

    $partial = New-Dir 'incomplete'
    $partialFile = Join-Path $partial '.artemisos-sdcard-create-123.tmp'
    [IO.File]::WriteAllText($partialFile, 'keep incomplete')
    $partialError = ''
    try { Get-ArtemisSdCard $partial @() $makeSdCard 16MB | Out-Null } catch { $partialError = $_.Exception.Message }
    Assert ($partialError.Contains($partialFile) -and $partialError.Contains('关闭模拟器') -and $partialError.Contains('.qcow2')) 'unfinished image error includes its path and safe cleanup instructions'
    Assert (-not (Test-Path -LiteralPath (Join-Path $partial 'sdcard.img'))) 'unfinished temporary image is retained'

    $noTool = New-Dir 'missing-tool'
    Assert-Blocked { Get-ArtemisSdCard $noTool @() (Join-Path $work 'no-such-mksdcard.exe') 16MB } 'missing tool blocks creation'
    Assert (-not (Test-Path -LiteralPath (Join-Path $noTool 'sdcard.img'))) 'missing tool creates no image'

    $noSpace = New-Dir 'insufficient-space'
    $tooLarge = [long]::MaxValue - ([long]::MaxValue % 1MB)
    Assert-Blocked { Get-ArtemisSdCard $noSpace @() $makeSdCard $tooLarge } 'insufficient free space blocks creation'
    Assert (-not (Test-Path -LiteralPath (Join-Path $noSpace 'sdcard.img'))) 'insufficient space creates no image'

    $outside = New-Dir 'junction-target'
    $junction = Join-Path $work 'junction'
    [void](New-Item -ItemType Junction -Path $junction -Target $outside)
    try {
        Assert-Blocked { Get-ArtemisSdCard $junction @() $makeSdCard 16MB } 'a junction in the creation path is rejected'
        Assert (-not (Test-Path -LiteralPath (Join-Path $outside 'sdcard.img'))) 'junction target is unchanged'
    } finally {
        $link = Get-Item -LiteralPath $junction -Force
        if (-not ($link.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Expected fixture junction is not a reparse point.' }
        [IO.Directory]::Delete($junction)
    }

    $badTool = Join-Path $work 'failure.cmd'
    [IO.File]::WriteAllText($badTool, "@echo off`r`nexit /b 9`r`n", [Text.Encoding]::ASCII)
    $failed = New-Dir 'failed-creator'
    Assert-Blocked { Get-ArtemisSdCard $failed @() $badTool 16MB } 'a nonzero creator exit blocks creation'
    Assert (-not (Test-Path -LiteralPath (Join-Path $failed 'sdcard.img')) -and
        @(Get-ChildItem -LiteralPath $failed -Filter '.artemisos-sdcard-create-*.tmp' -Force).Count -eq 1) 'failed creator retains only the temporary file'

    $shortTool = Join-Path $work 'short.cmd'
    [IO.File]::WriteAllText($shortTool, "@echo off`r`nexit /b 0`r`n", [Text.Encoding]::ASCII)
    $short = New-Dir 'short-creator'
    Assert-Blocked { Get-ArtemisSdCard $short @() $shortTool 16MB } 'an incorrectly sized creator output is rejected'
    Assert (-not (Test-Path -LiteralPath (Join-Path $short 'sdcard.img')) -and
        @(Get-ChildItem -LiteralPath $short -Filter '.artemisos-sdcard-create-*.tmp' -Force).Count -eq 1) 'incorrect output remains temporary'

    # Use separate PowerShell processes and the actual launch-lock and card
    # helpers. Only small fixture cards are created; no installed AVD is used.
    $worker = Join-Path $work 'launch-worker.ps1'
    $workerSource = @'
param([string]$LaunchScript, [string]$Root, [string]$Tool, [string]$Signal, [string]$Release, [string]$ErrorFile)
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$tree = [Management.Automation.Language.Parser]::ParseFile($LaunchScript, [ref]$tokens, [ref]$errors)
if ($errors.Count) { exit 8 }
foreach ($name in @('Enter-ArtemisLaunchLock','Get-ArtemisSdCard')) {
    $definition = $tree.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $false)
    if ($null -eq $definition) { exit 9 }
    Invoke-Expression $definition.Extent.Text
}
$mutex = $null
try {
    $mutex = Enter-ArtemisLaunchLock $Root
    [IO.File]::WriteAllText($Signal, 'held')
    if ($Release -ne 'NoRelease') {
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while (-not (Test-Path -LiteralPath $Release)) {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Fixture release timed out.' }
            Start-Sleep -Milliseconds 50
        }
    }
    Get-ArtemisSdCard $Root @() $Tool 16MB | Out-Null
} catch {
    [IO.File]::WriteAllText($ErrorFile, $_.Exception.Message)
    exit 3
} finally {
    if ($null -ne $mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
}
'@
    [IO.File]::WriteAllText($worker, $workerSource, (New-Object Text.UTF8Encoding($true)))
    function Start-Worker([string]$Root, [string]$Signal, [string]$Release, [string]$ErrorFile) {
        $exe = Join-Path $PSHOME 'powershell.exe'
        $launch = Join-Path $project 'stage\launch.ps1'
        $args = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"' + $worker + '"'),
            '-LaunchScript',('"' + $launch + '"'),'-Root',('"' + $Root + '"'),'-Tool',('"' + $makeSdCard + '"'),
            '-Signal',('"' + $Signal + '"'),'-Release',('"' + $Release + '"'),'-ErrorFile',('"' + $ErrorFile + '"'))
        return Start-Process -FilePath $exe -ArgumentList $args -PassThru -WindowStyle Hidden
    }
    function Wait-Worker([Diagnostics.Process]$Process) {
        if (-not $Process.WaitForExit(15000)) { $Process.Kill(); throw 'Concurrent launcher fixture timed out.' }
        $Process.Refresh()
        return $Process.ExitCode
    }
    $same = New-Dir 'same-install'
    $other = New-Dir 'other-install'
    $firstSignal = Join-Path $work 'first-held'
    $release = Join-Path $work 'release-first'
    $first = Start-Worker $same $firstSignal $release (Join-Path $work 'first-error')
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while (-not (Test-Path -LiteralPath $firstSignal)) {
            if ($first.HasExited -or [DateTime]::UtcNow -gt $deadline) { throw 'First launcher did not acquire its fixture lock.' }
            Start-Sleep -Milliseconds 50
            $first.Refresh()
        }
        $secondSignal = Join-Path $work 'second-held'
        $second = Start-Worker ($same.ToLowerInvariant()) $secondSignal 'NoRelease' (Join-Path $work 'second-error')
        $secondExit = Wait-Worker $second
        if ($secondExit -ne 3) {
            $errorFile = Join-Path $work 'second-error'
            $reason = if (Test-Path -LiteralPath $errorFile) { [IO.File]::ReadAllText($errorFile) } else { 'no error file' }
            throw "Second launcher exited $secondExit ($reason)."
        }
        Assert (-not (Test-Path -LiteralPath $secondSignal) -and
            -not (Test-Path -LiteralPath (Join-Path $same 'sdcard.img'))) 'same-install concurrent launch stops before card creation'
        $thirdSignal = Join-Path $work 'third-held'
        $third = Start-Worker $other $thirdSignal 'NoRelease' (Join-Path $work 'third-error')
        Assert ((Wait-Worker $third) -eq 0 -and (Test-Path -LiteralPath (Join-Path $other 'sdcard.img'))) 'another installation is not blocked'
        [IO.File]::WriteAllText($release, 'release')
        Assert ((Wait-Worker $first) -eq 0 -and (Get-Item -LiteralPath (Join-Path $same 'sdcard.img')).Length -eq 16MB -and
            @(Get-ChildItem -LiteralPath $same -Filter '.artemisos-sdcard-create-*.tmp' -Force).Count -eq 0) 'first launcher creates one complete image'
    } finally {
        $first.Refresh()
        if (-not $first.HasExited) { $first.Kill(); [void]$first.WaitForExit(5000) }
    }
} finally {
    $item = Get-Item -LiteralPath $work -Force -ErrorAction Stop
    if ($item.Parent.FullName.TrimEnd('\') -ine $parent -or $item.Name -cnotmatch '^artemisos-sdcard-fixture-[0-9a-f]{32}$' -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not (Test-Path -LiteralPath (Join-Path $work '.fixture-only') -PathType Leaf)) {
        throw 'Unsafe fixture cleanup.'
    }
    [IO.Directory]::Delete($work, $true)
}
