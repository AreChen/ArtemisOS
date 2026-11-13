param([string]$Compiler = (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'))
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Compiler -PathType Leaf)) { throw 'Inno compiler not found.' }
$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$roots = New-Object 'System.Collections.Generic.List[string]'
$fixtureScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\Upgrade-UninstallFixture.ps1'
$oldId = '{E49344F1-069E-4DA4-A5B7-232C0BE325A8}'
function Assert([bool]$Ok, [string]$Message) { if (-not $Ok) { throw $Message }; Write-Host "PASS: $Message" }
function Hash([string]$Path) {
    $h = [Security.Cryptography.SHA256]::Create(); $s = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($h.ComputeHash($s))).Replace('-','') } finally { $s.Dispose(); $h.Dispose() }
}
function New-Root {
    $path = Join-Path $parent ('artemisos-uninstall-fixture-' + [Guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $path) { throw 'Fixture already exists.' }
    [void][IO.Directory]::CreateDirectory($path)
    [IO.File]::WriteAllText((Join-Path $path '.fixture-only'),'fixture')
    $roots.Add($path)
    return $path
}
function Write-Text([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path,$Text,[Text.Encoding]::ASCII)
}
function Run-Setup([string]$Exe, [string]$Directory) {
    & rtk proxy $Exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- ("/DIR=$Directory")
    if ($LASTEXITCODE -ne 0) { throw 'Fixture installer failed.' }
}
function Run-Fixture([string]$Root, [string]$Action, [string]$Crash = '') {
    if ($Crash) { & rtk proxy powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fixtureScript -Action $Action -FixtureRoot $Root -CrashAt $Crash | Out-Host }
    else { & rtk proxy powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fixtureScript -Action $Action -FixtureRoot $Root | Out-Host }
    return $LASTEXITCODE
}
function Make-Target([string]$Baseline, [string]$Helper, [string]$RegistrationId = $oldId) {
    $root = New-Root
    $target = Join-Path $root 'target'
    Run-Setup $Baseline $target
    Write-Text (Join-Path $target 'sdk\new-managed.txt') 'new sdk fixture'
    Write-Text (Join-Path $target 'data\preferences.ini') "profile=high`r`nunknown=preserve`r`n"
    Write-Text (Join-Path $target 'data\avd\disk.img') 'fixture user disk'
    [IO.File]::Copy($Helper, (Join-Path $root 'helper.exe'))
    Write-Text (Join-Path $root 'helper.sha256') (Hash (Join-Path $root 'helper.exe'))
    Write-Text (Join-Path $root 'managed.txt') "sdk\new-managed.txt`r`n"
    $reg = [pscustomobject]@{
        AppId = $RegistrationId; Hive = 'CurrentUser'; View = 'Registry64'; InstallPath = $target
        UninstallString = '"' + (Join-Path $target 'unins000.exe') + '"'; DisplayVersion = '0.3.5'
    }
    [IO.File]::WriteAllText((Join-Path $root 'registry.json'), ($reg | ConvertTo-Json), [Text.Encoding]::UTF8)
    return $root
}
try {
    $build = New-Root
    $baselineFile = Join-Path $build 'baseline.txt'
    Write-Text $baselineFile 'fixture baseline'
    $baseSource = @'
[Setup]
AppId={{E49344F1-069E-4DA4-A5B7-232C0BE325A8}
AppName=Fixture
AppVersion=0.3.5
DefaultDirName={tmp}\fixture-default
DisableDirPage=no
DisableWelcomePage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
UsePreviousAppDir=no
PrivilegesRequired=lowest
CreateUninstallRegKey=no
Uninstallable=yes
OutputBaseFilename=baseline
Compression=lzma2/fast
[Files]
Source: "__FILE__"; DestDir: "{app}"; Flags: ignoreversion
'@.Replace('__FILE__',$baselineFile)
    $baseIss = Join-Path $build 'baseline.iss'; Write-Text $baseIss $baseSource
    & rtk proxy $Compiler ("/O$build") $baseIss
    if ($LASTEXITCODE -ne 0) { throw 'Fixture baseline compilation failed.' }
    $modernBaseIss = Join-Path $build 'modern-baseline.iss'
    Write-Text $modernBaseIss ($baseSource.Replace('AppId={{E49344F1-069E-4DA4-A5B7-232C0BE325A8}', 'AppId=ArtemisOS15-Release').Replace('OutputBaseFilename=baseline', 'OutputBaseFilename=modern-baseline'))
    & rtk proxy $Compiler ("/O$build") $modernBaseIss
    if ($LASTEXITCODE -ne 0) { throw 'Fixture modern baseline compilation failed.' }
    $helperSource = @'
[Setup]
AppId=__APP_ID__
AppName=Fixture
AppVersion=1.0.0
DefaultDirName={tmp}\fixture-default
DisableDirPage=no
DisableWelcomePage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
UsePreviousAppDir=no
PrivilegesRequired=lowest
CreateUninstallRegKey=no
Uninstallable=yes
UninstallLogMode=append
UpdateUninstallLogAppName=no
OutputBaseFilename=__OUTPUT__
Compression=lzma2/fast
[UninstallDelete]
Type: files; Name: "{app}\sdk\new-managed.txt"
'@
    $helperIss = Join-Path $build 'helper.iss'
    Write-Text $helperIss ($helperSource.Replace('__APP_ID__','{{E49344F1-069E-4DA4-A5B7-232C0BE325A8}').Replace('__OUTPUT__','helper'))
    & rtk proxy $Compiler ("/O$build") $helperIss
    if ($LASTEXITCODE -ne 0) { throw 'Fixture helper compilation failed.' }
    $wrongIss = Join-Path $build 'wrong-helper.iss'
    Write-Text $wrongIss ($helperSource.Replace('__APP_ID__','ArtemisOS15-Release').Replace('__OUTPUT__','wrong-helper'))
    & rtk proxy $Compiler ("/O$build") $wrongIss
    if ($LASTEXITCODE -ne 0) { throw 'Fixture mismatch-helper compilation failed.' }
    $baseline = Join-Path $build 'baseline.exe'; $helper = Join-Path $build 'helper.exe'

    foreach ($point in @('AfterBackup','BeforeHelper','DuringHelper','AfterHelper','BeforeRegistry','AfterRegistry')) {
        $root = Make-Target $baseline $helper
        $target = Join-Path $root 'target'
        $exe = Join-Path $target 'unins000.exe'; $dat = Join-Path $target 'unins000.dat'
        $registry = Join-Path $root 'registry.json'; $prefs = Join-Path $target 'data\preferences.ini'; $disk = Join-Path $target 'data\avd\disk.img'
        $before = @((Hash $exe),(Hash $dat),(Hash $registry),(Hash $prefs),(Hash $disk))
        $code = Run-Fixture $root 'Apply' $point
        Assert ($code -ne 0) "fault is surfaced: $point"
        if ($point -eq 'AfterRegistry') {
            $code = Run-Fixture $root 'Recover' 'RecoveryTempCreated'
            Assert ($code -ne 0) 'an interrupted restore keeps a verifiable temporary file'
            $code = Run-Fixture $root 'Recover' 'DuringRecovery'
            Assert ($code -ne 0) 'a second interruption during recovery is surfaced'
        }
        $code = Run-Fixture $root 'Recover'
        Assert ($code -eq 0 -and (Hash $exe) -ceq $before[0] -and (Hash $dat) -ceq $before[1] -and
            (Hash $registry) -ceq $before[2] -and (Hash $prefs) -ceq $before[3] -and (Hash $disk) -ceq $before[4]) "restore is byte-identical: $point"
        $code = Run-Fixture $root 'Apply'
        $newReg = [IO.File]::ReadAllText($registry) | ConvertFrom-Json
        Assert ($code -eq 0 -and $newReg.DisplayVersion -eq '1.0.0' -and (Hash $dat) -cne $before[1] -and
            (Hash $prefs) -ceq $before[3] -and (Hash $disk) -ceq $before[4]) "retry completes without changing fixture data: $point"
    }
    & rtk proxy (Join-Path $target 'unins000.exe') /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
    if ($LASTEXITCODE -ne 0) { throw 'Fixture uninstallation failed.' }
    Assert (-not (Test-Path -LiteralPath (Join-Path $target 'sdk\new-managed.txt')) -and
        (Test-Path -LiteralPath (Join-Path $target 'data\avd\disk.img'))) 'the appended exact cleanup removes managed files and preserves data'

    $mismatch = Make-Target $baseline (Join-Path $build 'wrong-helper.exe')
    $mismatchCode = Run-Fixture $mismatch 'Apply'
    $mismatchReg = [IO.File]::ReadAllText((Join-Path $mismatch 'registry.json')) | ConvertFrom-Json
    Assert ($mismatchCode -ne 0 -and $mismatchReg.DisplayVersion -eq '0.3.5' -and
        (Test-Path -LiteralPath (Join-Path $mismatch 'target\unins001.dat'))) 'a different helper AppId is detected without updating the version'
    $mismatchRecovery = Run-Fixture $mismatch 'Recover'
    Assert ($mismatchRecovery -ne 0 -and (Test-Path -LiteralPath (Join-Path $mismatch 'target\unins001.dat'))) 'ambiguous new uninstall files are retained for inspection'

    $modern = Make-Target (Join-Path $build 'modern-baseline.exe') (Join-Path $build 'wrong-helper.exe') 'ArtemisOS15-Release'
    $modernCode = Run-Fixture $modern 'Apply'
    $modernReg = [IO.File]::ReadAllText((Join-Path $modern 'registry.json')) | ConvertFrom-Json
    Assert ($modernCode -eq 0 -and $modernReg.DisplayVersion -eq '1.0.0' -and
        -not (Test-Path -LiteralPath (Join-Path $modern 'target\unins001.dat'))) 'the second known AppId appends to its matching log'

    $bad = Make-Target $baseline $helper
    $regPath = Join-Path $bad 'registry.json'; $reg = [IO.File]::ReadAllText($regPath) | ConvertFrom-Json
    $reg.InstallPath = Join-Path $bad 'other'
    [IO.File]::WriteAllText($regPath, ($reg | ConvertTo-Json), [Text.Encoding]::UTF8)
    $badCode = Run-Fixture $bad 'Apply'
    Assert ($badCode -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $bad 'metadata-transaction'))) 'a registration for a different directory is rejected before mutation'

    $badData = Make-Target $baseline $helper
    Write-Text (Join-Path $badData 'managed.txt') "data\avd\disk.img`r`n"
    $badDataCode = Run-Fixture $badData 'Apply'
    Assert ($badDataCode -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $badData 'metadata-transaction')) -and
        [IO.File]::ReadAllText((Join-Path $badData 'target\data\avd\disk.img')) -eq 'fixture user disk') 'user data cannot be designated as a managed cleanup path'
} finally {
    foreach ($fixture in $roots) {
        if (-not (Test-Path -LiteralPath $fixture)) { continue }
        $item = Get-Item -LiteralPath $fixture -Force
        if ($item.FullName -ine $fixture -or $item.Parent.FullName.TrimEnd('\') -ine $parent -or
            $item.Name -notmatch '^artemisos-uninstall-fixture-[0-9a-f]{32}$' -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe fixture cleanup path.' }
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}
