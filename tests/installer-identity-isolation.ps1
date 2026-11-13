<#
Compiles the production [Setup], [Tasks], [Icons], and [Code] sections with a
tiny synthetic payload. A unique identity and unique shortcut names ensure the
test can never target the real ArtemisOS installation. It checks both a fake
old registration and the real old registration/shortcuts before and after.
#>
param([string]$Iscc = (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'))
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$project = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath $Iscc -PathType Leaf)) { throw 'Inno Setup 6 ISCC.exe was not found.' }
$token = [Guid]::NewGuid().ToString('N')
$fixture = Join-Path $project ('build\installer-identity-tests-' + $token)
[void][IO.Directory]::CreateDirectory($fixture)
$out = Join-Path $fixture 'out'
[void][IO.Directory]::CreateDirectory($out)
$newId = 'ArtemisGuardNew-' + $token
$oldId = 'ArtemisGuardOld-' + $token
$lateId = 'ArtemisGuardLate-' + $token
$guidId = [Guid]::NewGuid().ToString('B').ToUpperInvariant()
$guidCompilerId = '{' + $guidId
$newShortcut = 'Artemis Guard New ' + $token
$oldShortcut = 'Artemis Guard Old ' + $token
$uninstallRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
$oldKey = Join-Path $uninstallRoot ($oldId + '_is1')
$newKey = Join-Path $uninstallRoot ($newId + '_is1')
$lateKey = Join-Path $uninstallRoot ($lateId + '_is1')
$guidKey = Join-Path $uninstallRoot ($guidId + '_is1')
$actualOldKey = Join-Path $uninstallRoot '{E49344F1-069E-4DA4-A5B7-232C0BE325A8}_is1'
$desktop = [Environment]::GetFolderPath('Desktop')
$programs = [Environment]::GetFolderPath('Programs')
$oldDesktop = Join-Path $desktop ($oldShortcut + '.lnk')
$oldGroup = Join-Path $programs $oldShortcut
$newGroup = Join-Path $programs $newShortcut
$oldStartLink = Join-Path $oldGroup ($oldShortcut + '.lnk')
$source = [IO.File]::ReadAllText((Join-Path $project 'installer.iss'), [Text.Encoding]::UTF8)
$source = $source.Replace('#include "tools\InstallerOtaConfig.iss"', [IO.File]::ReadAllText((Join-Path $project 'tools\InstallerOtaConfig.iss')))
# Expected installer failures must never display the production message boxes.
# Keep production prompts unchanged; suppress only the fixture's copied code.
$source = [regex]::Replace($source, '(?<!Suppressible)MsgBox\(([^\r\n]*?), (mbError|mbCriticalError), MB_OK\)', 'SuppressibleMsgBox($1, $2, MB_OK, IDOK)')
function Get-Section([string]$Name, [string]$Next) {
    $match = [regex]::Match($source, '(?ms)^\[' + $Name + '\]\r?\n(?<section>.*?)(?=^\[' + $Next + '\])')
    if (-not $match.Success) { throw "Cannot extract [$Name] from installer.iss" }
    return $match.Groups['section'].Value
}
$header = [regex]::Match($source, '(?s)\A(?<header>.*?)\r?\n\[Setup\]').Groups['header'].Value
$setup = Get-Section 'Setup' 'Languages'
$tasks = Get-Section 'Tasks' 'Files'
$icons = Get-Section 'Icons' 'Run'
$code = [regex]::Match($source, '(?s)\r?\n\[Code\]\r?\n(?<code>.*)\z').Groups['code'].Value
if (-not $header -or -not $code) { throw 'Cannot extract the production definitions or Pascal code.' }
$setup = [regex]::Replace($setup, '(?m)^OutputDir=.*$', 'OutputDir={#SourcePath}out')
$setup = [regex]::Replace($setup, '(?m)^OutputBaseFilename=.*$', 'OutputBaseFilename=identity-fixture')
$setup = [regex]::Replace($setup, '(?m)^(SetupIconFile|WizardSmallImageFile|WizardImageFile)=.*\r?\n', '')
$version = Join-Path $fixture 'version.ini'
[IO.File]::WriteAllText($version, "[ArtemisOS]`r`nVersion=0.3.6`r`n", [Text.Encoding]::ASCII)
[IO.File]::Copy((Join-Path $project 'stage\ArtemisOS15.ico'), (Join-Path $fixture 'fixture.ico'))
$files = @'
Source: "{#VersionSource}"; DestDir: "{app}"; DestName: "version.ini"; Flags: ignoreversion
Source: "{#SourcePath}fixture.ico"; DestDir: "{app}"; DestName: "ArtemisOS15.ico"; Flags: ignoreversion
'@
$iss = Join-Path $fixture 'fixture.iss'
$text = $header + "`r`n[Setup]`r`n" + $setup + "`r`n[Tasks]`r`n" + $tasks + "`r`n[Files]`r`n" + $files + "`r`n[Icons]`r`n" + $icons + "`r`n[Code]`r`n" + $code
[IO.File]::WriteAllText($iss, $text, [Text.UTF8Encoding]::new($true))
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host "PASS: $Message"
}
function Export-Registry([string]$Key, [string]$Path) {
    & rtk proxy reg.exe export $Key $Path /y | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Could not export $Key" }
}
function Get-FixtureProcessFamily([int]$RootId) {
    $all = @(Get-CimInstance Win32_Process)
    $ids = [System.Collections.Generic.HashSet[int]]::new()
    [void]$ids.Add($RootId)
    do {
        $changed = $false
        foreach ($process in $all) {
            if ($ids.Contains([int]$process.ParentProcessId) -and $ids.Add([int]$process.ProcessId)) { $changed = $true }
        }
    } while ($changed)
    return [int[]]@($ids)
}
function Stop-FixtureProcessFamily([int]$RootId) {
    $ids = @(Get-FixtureProcessFamily $RootId)
    foreach ($id in $ids) { if ($id -ne $RootId) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } }
    Stop-Process -Id $RootId -Force -ErrorAction SilentlyContinue
}
function Start-Fixture([string[]]$Arguments) {
    $rtkPath = (Get-Command rtk.exe -ErrorAction Stop).Source
    $silentArguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') + $Arguments
    $quoted = @('proxy', ('"' + $exe + '"')) + @($silentArguments | ForEach-Object { '"' + $_ + '"' })
    return Start-Process -FilePath $rtkPath -ArgumentList $quoted -PassThru -WindowStyle Hidden
}
function Wait-Fixture([System.Diagnostics.Process]$Process, [int]$Seconds) {
    if (-not $Process.WaitForExit($Seconds * 1000)) {
        Stop-FixtureProcessFamily $Process.Id
        throw 'Fixture setup did not terminate in time.'
    }
    return $Process.ExitCode
}
if ((Test-Path -LiteralPath $oldKey) -or (Test-Path -LiteralPath $newKey) -or
    (Test-Path -LiteralPath $lateKey) -or (Test-Path -LiteralPath $guidKey) -or
    (Test-Path -LiteralPath $oldDesktop) -or (Test-Path -LiteralPath $oldGroup) -or (Test-Path -LiteralPath $newGroup)) {
    throw 'A unique identity fixture path already exists.'
}
$realLinks = @()
$realStart = Join-Path $programs 'ArtemisOS 15'
if (Test-Path -LiteralPath $realStart) { $realLinks += @(Get-ChildItem -LiteralPath $realStart -File -Filter '*.lnk' | Select-Object -ExpandProperty FullName) }
$realLinks += @(Get-ChildItem -LiteralPath $desktop -File -Filter 'ArtemisOS 15*.lnk' | Select-Object -ExpandProperty FullName)
$realLinkHashes = @{}
foreach ($link in $realLinks) { $realLinkHashes[$link] = (Get-FileHash -LiteralPath $link -Algorithm SHA256).Hash }
$realKeyPresent = Test-Path -LiteralPath $actualOldKey
if ($realKeyPresent) { Export-Registry 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\{E49344F1-069E-4DA4-A5B7-232C0BE325A8}_is1' (Join-Path $fixture 'real-before.reg') }
try {
    New-Item -Path $oldKey -Force | Out-Null
    New-ItemProperty -LiteralPath $oldKey -Name DisplayName -Value 'Synthetic old registration' -PropertyType String | Out-Null
    New-ItemProperty -LiteralPath $oldKey -Name InstallLocation -Value $fixture -PropertyType String | Out-Null
    [void][IO.Directory]::CreateDirectory($oldGroup)
    $shell = New-Object -ComObject WScript.Shell
    foreach ($link in @($oldDesktop, $oldStartLink)) {
        $shortcut = $shell.CreateShortcut($link)
        $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
        $shortcut.Arguments = 'synthetic-old'
        $shortcut.Save()
    }
    $oldDesktopHash = (Get-FileHash -LiteralPath $oldDesktop -Algorithm SHA256).Hash
    $oldStartHash = (Get-FileHash -LiteralPath $oldStartLink -Algorithm SHA256).Hash
    Export-Registry ('HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $oldId + '_is1') (Join-Path $fixture 'old-before.reg')
    & rtk proxy $Iscc '/Qp' '/DAppVersion=0.3.6' ("/DVersionSource=$version") ("/DReleaseAppId=$newId") ("/DReleaseShortcutName=$newShortcut") ("/DReleaseDefaultDirName=$newId") $iss | Out-Host
    Assert ($LASTEXITCODE -eq 0) 'isolated identity installer compiles from production sections'
    $exe = Join-Path $out 'identity-fixture.exe'
    $install = Join-Path $fixture 'installed'
    $initialRun = Start-Fixture @('/SP-', '/TASKS=desktopicon', ("/DIR=$install"), ("/LOG=$(Join-Path $fixture 'setup.log')"))
    Assert ((Wait-Fixture $initialRun 60) -eq 0) 'isolated new identity installs successfully'
    Assert (Test-Path -LiteralPath $newKey) 'a distinct new uninstall registration is created'
    Assert ((Get-ItemProperty -LiteralPath $newKey -Name DisplayName).DisplayName -eq $newShortcut) 'new uninstall display name is distinct'
    Assert (Test-Path -LiteralPath (Join-Path $desktop ($newShortcut + '.lnk'))) 'new desktop shortcut is created under the new name'
    Assert (Test-Path -LiteralPath (Join-Path $newGroup ($newShortcut + '.lnk'))) 'new Start menu folder and shortcut are distinct'
    Assert (@(Get-ChildItem -LiteralPath $desktop -File -Filter ($newShortcut + '*.lnk')).Count -eq 3) 'all three new desktop shortcut names are distinct'
    Assert (@(Get-ChildItem -LiteralPath $newGroup -File -Filter '*.lnk').Count -eq 4) 'all new Start menu shortcuts are in the distinct folder'
    $newLinks = @((Get-ChildItem -LiteralPath $desktop -File -Filter ($newShortcut + '*.lnk')).FullName) + @((Get-ChildItem -LiteralPath $newGroup -File -Filter '*.lnk').FullName)
    $newLinkHashes = @{}
    foreach ($link in $newLinks) { $newLinkHashes[$link] = (Get-FileHash -LiteralPath $link -Algorithm SHA256).Hash }
    Export-Registry ('HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $newId + '_is1') (Join-Path $fixture 'new-before-duplicate.reg')
    $duplicateTarget = Join-Path $fixture 'second-install'
    $silent = Start-Fixture @('/VERYSILENT', '/NORESTART', '/SP-', ("/DIR=$duplicateTarget"), ("/LOG=$(Join-Path $fixture 'duplicate-silent.log')"))
    Assert ((Wait-Fixture $silent 30) -ne 0) 'silent duplicate exits without a prompt and with a failure status'
    Assert (-not (Test-Path -LiteralPath $duplicateTarget)) 'silent duplicate does not create a second installation'
    $expectedMessage = [regex]::Match($code, "(?s)function SameAppIdMessage: String;.*?Result := '([^']+)';").Groups[1].Value
    Assert ($expectedMessage.Length -gt 0) 'duplicate-install user message is present in the production code'
    Assert ([IO.File]::ReadAllText((Join-Path $fixture 'duplicate-silent.log')).Contains($expectedMessage)) 'silent failure explains the existing installation in the log'
    $suppressedTarget = Join-Path $fixture 'second-suppressed'
    $suppressed = Start-Fixture @('/SP-', ("/DIR=$suppressedTarget"), ("/LOG=$(Join-Path $fixture 'duplicate-suppressed.log')"))
    Assert ((Wait-Fixture $suppressed 30) -ne 0) 'suppressed duplicate exits without displaying a message box'
    Assert (-not (Test-Path -LiteralPath $suppressedTarget)) 'suppressed duplicate does not create a second installation'
    Assert ([IO.File]::ReadAllText((Join-Path $fixture 'duplicate-suppressed.log')).Contains($expectedMessage)) 'suppressed duplicate records the uninstall-first reason in its log'
    Export-Registry ('HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $newId + '_is1') (Join-Path $fixture 'new-after-duplicate.reg')
    Assert ((Get-FileHash (Join-Path $fixture 'new-before-duplicate.reg')).Hash -eq (Get-FileHash (Join-Path $fixture 'new-after-duplicate.reg')).Hash) 'duplicate attempts preserve the existing uninstall registration'
    foreach ($link in $newLinks) {
        Assert ((Test-Path -LiteralPath $link) -and ((Get-FileHash -LiteralPath $link -Algorithm SHA256).Hash -eq $newLinkHashes[$link])) 'duplicate attempts preserve an existing shortcut'
    }
    # Inno escapes a literal leading brace in a GUID AppId with a second brace.
    # Check the production guard against the actual uninstall-key spelling.
    New-Item -Path $guidKey -Force | Out-Null
    New-ItemProperty -LiteralPath $guidKey -Name FixtureToken -Value $token -PropertyType String | Out-Null
    & rtk proxy $Iscc '/Qp' '/DAppVersion=0.3.6' ("/DVersionSource=$version") ("/DReleaseAppId=$guidCompilerId") ("/DReleaseShortcutName=$newShortcut") ("/DReleaseDefaultDirName=$newId") $iss | Out-Host
    Assert ($LASTEXITCODE -eq 0) 'escaped-brace AppId fixture compiles from production sections'
    $guidTarget = Join-Path $fixture 'guid-duplicate'
    $guidRun = Start-Fixture @('/VERYSILENT', '/NORESTART', '/SP-', ("/DIR=$guidTarget"), ("/LOG=$(Join-Path $fixture 'guid-duplicate.log')"))
    Assert ((Wait-Fixture $guidRun 30) -ne 0) 'escaped-brace AppId detects its existing registration'
    Assert (-not (Test-Path -LiteralPath $guidTarget)) 'escaped-brace duplicate does not install'
    Assert ([IO.File]::ReadAllText((Join-Path $fixture 'guid-duplicate.log')).Contains($expectedMessage)) 'escaped-brace duplicate records the intended reason'
    # Seed a unique registration after InitializeSetup but before the main
    # PrepareToInstall callback to exercise the second check against a race.
    $lateEvent = @'
<event('PrepareToInstall')>
function SeedFixtureRegistration(var NeedsRestart: Boolean): String;
var Key: String;
begin
  Key := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\' + ExpandConstant('{#ReleaseAppId}') + '_is1';
  if RegWriteStringValue(HKCU64, Key, 'FixtureToken', '{#FixtureToken}') then Result := ''
  else Result := 'Failed to create synthetic fixture registration.';
end;
'@
    $lateIss = Join-Path $fixture 'late-fixture.iss'
    [IO.File]::WriteAllText($lateIss, $text + "`r`n" + $lateEvent, [Text.UTF8Encoding]::new($true))
    & rtk proxy $Iscc '/Qp' '/DAppVersion=0.3.6' ("/DVersionSource=$version") ("/DReleaseAppId=$lateId") ("/DReleaseShortcutName=$newShortcut") ("/DReleaseDefaultDirName=$lateId") ("/DFixtureToken=$token") $lateIss | Out-Host
    Assert ($LASTEXITCODE -eq 0) 'late-registration fixture compiles with the production guard'
    $lateTarget = Join-Path $fixture 'late-duplicate'
    $lateRun = Start-Fixture @('/VERYSILENT', '/NORESTART', '/SP-', ("/DIR=$lateTarget"), ("/LOG=$(Join-Path $fixture 'late-duplicate.log')"))
    Assert ((Wait-Fixture $lateRun 30) -ne 0) 'registration appearing after startup is rejected before installation'
    Assert ((Test-Path -LiteralPath $lateKey) -and ((Get-ItemProperty -LiteralPath $lateKey -Name FixtureToken).FixtureToken -eq $token)) 'late test created only its unique synthetic registration'
    Assert (-not (Test-Path -LiteralPath $lateTarget)) 'late duplicate does not install files'
    Assert ([IO.File]::ReadAllText((Join-Path $fixture 'late-duplicate.log')).Contains($expectedMessage)) 'late duplicate records the intended reason'
    Assert ((Get-FileHash -LiteralPath $oldDesktop -Algorithm SHA256).Hash -eq $oldDesktopHash) 'synthetic old desktop shortcut is unchanged'
    Assert ((Get-FileHash -LiteralPath $oldStartLink -Algorithm SHA256).Hash -eq $oldStartHash) 'synthetic old Start menu shortcut is unchanged'
    Export-Registry ('HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $oldId + '_is1') (Join-Path $fixture 'old-after.reg')
    Assert ((Get-FileHash (Join-Path $fixture 'old-before.reg')).Hash -eq (Get-FileHash (Join-Path $fixture 'old-after.reg')).Hash) 'synthetic old uninstall registration is unchanged'
    foreach ($link in $realLinks) {
        Assert ((Test-Path -LiteralPath $link) -and ((Get-FileHash -LiteralPath $link -Algorithm SHA256).Hash -eq $realLinkHashes[$link])) 'an existing real ArtemisOS shortcut is unchanged'
    }
    if ($realKeyPresent) {
        Export-Registry 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\{E49344F1-069E-4DA4-A5B7-232C0BE325A8}_is1' (Join-Path $fixture 'real-after.reg')
        Assert ((Get-FileHash (Join-Path $fixture 'real-before.reg')).Hash -eq (Get-FileHash (Join-Path $fixture 'real-after.reg')).Hash) 'existing real ArtemisOS registration is unchanged'
    }
} finally {
    # These exact GUID-qualified objects were created only by this fixture.
    foreach ($key in @($lateKey, $guidKey)) {
        if ((Split-Path -Parent $key) -ne $uninstallRoot) { throw 'Unexpected synthetic registry cleanup path.' }
        if (Test-Path -LiteralPath $key) {
            if ((Get-ItemProperty -LiteralPath $key -Name FixtureToken).FixtureToken -ne $token) { throw 'Synthetic registry ownership marker is missing.' }
            Remove-Item -LiteralPath $key -Force
        }
    }
    foreach ($key in @($oldKey, $newKey)) {
        if ((Split-Path -Parent $key) -ne $uninstallRoot -or (Split-Path -Leaf $key) -notmatch ('^ArtemisGuard(Old|New)-' + $token + '_is1$')) { throw 'Unexpected registry cleanup path.' }
        if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force }
    }
    foreach ($prefix in @($oldShortcut, $newShortcut)) {
        if ($prefix -notmatch ('^Artemis Guard (Old|New) ' + $token + '$')) { throw 'Unexpected shortcut cleanup name.' }
        foreach ($link in @(Get-ChildItem -LiteralPath $desktop -File -Filter ($prefix + '*.lnk') -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $link.FullName -Force }
        $group = Join-Path $programs $prefix
        if (Test-Path -LiteralPath $group) {
            foreach ($link in @(Get-ChildItem -LiteralPath $group -File -Filter '*.lnk')) { Remove-Item -LiteralPath $link.FullName -Force }
            Remove-Item -LiteralPath $group -Force
        }
    }
}
Write-Host "Identity fixture evidence: $fixture"
