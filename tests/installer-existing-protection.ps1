<#
Behavioral regression for the actual installer guard and version preprocessor.
It builds a small disposable installer using the [Code] from installer.iss,
then runs it only against synthetic directories under build/. It never invokes
the real installer or touches a registered ArtemisOS installation.
#>
param(
    [string]$Iscc = (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$project = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath $Iscc -PathType Leaf)) { throw 'Inno Setup 6 ISCC.exe was not found.' }
$token = [Guid]::NewGuid().ToString('N')
$fixture = Join-Path $project ('build\installer-guard-tests-' + $token)
$fixtureAppId = 'ArtemisExistingGuard-' + $token
$stage = Join-Path $fixture 'stage'
$output = Join-Path $fixture 'out'
[void][IO.Directory]::CreateDirectory($stage)
[void][IO.Directory]::CreateDirectory($output)
$source = [IO.File]::ReadAllText((Join-Path $project 'installer.iss'), [Text.Encoding]::UTF8)
$source = $source.Replace('#include "tools\InstallerOtaConfig.iss"', [IO.File]::ReadAllText((Join-Path $project 'tools\InstallerOtaConfig.iss')))
# Never show production message boxes from an expected-failure test fixture.
$source = [regex]::Replace($source, '(?<!Suppressible)MsgBox\(([^\r\n]*?), (mbError|mbCriticalError), MB_OK\)', 'SuppressibleMsgBox($1, $2, MB_OK, IDOK)')
$parts = [regex]::Match($source, '(?s)\A(?<header>.*?)\r?\n\[Setup\].*?\r?\n\[Code\]\r?\n(?<code>.*)\z')
if (-not $parts.Success) { throw 'Could not extract the installer preprocessor and code sections.' }
$version = Join-Path $stage 'version.ini'
[IO.File]::WriteAllText($version, "[ArtemisOS]`r`nVersion=0.3.5`r`n", [Text.Encoding]::ASCII)
$newVersion = Join-Path $fixture 'new-version.ini'
[IO.File]::WriteAllText($newVersion, "[ArtemisOS]`r`nVersion=0.3.6`r`n", [Text.Encoding]::ASCII)
$payload = Join-Path $fixture 'payload.txt'
[IO.File]::WriteAllText($payload, 'synthetic payload', [Text.Encoding]::ASCII)
$fixtureIss = Join-Path $fixture 'fixture.iss'
$setup = @'
[Setup]
AppId={#ReleaseAppId}
AppName=Artemis Installer Guard Fixture
AppVersion={#AppVersion}
DefaultDirName={tmp}\ArtemisInstallerGuardFixture
UsePreviousAppDir=no
DisableProgramGroupPage=yes
DisableWelcomePage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
Uninstallable=no
OutputDir={#SourcePath}out
OutputBaseFilename=guard-fixture
Compression=none
WizardStyle=modern

[Files]
Source: "{#SourcePath}payload.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#VersionSource}"; DestDir: "{app}"; DestName: "version.ini"; Flags: ignoreversion

[Code]
'@
[IO.File]::WriteAllText($fixtureIss, ($parts.Groups['header'].Value + "`r`n" + $setup + "`r`n" + $parts.Groups['code'].Value), [Text.UTF8Encoding]::new($true))
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host "PASS: $Message"
}
function Compile-Fixture([string[]]$Arguments) {
    & rtk proxy $Iscc '/Qp' ("/DReleaseAppId=$fixtureAppId") @Arguments $fixtureIss | Out-Host
    return $LASTEXITCODE
}
$mismatch = Compile-Fixture @('/DAppVersion=0.3.6')
Assert ($mismatch -ne 0) 'mismatched AppVersion and version.ini fail compilation'
$matching = Compile-Fixture @('/DAppVersion=0.3.6', ("/DVersionSource=$newVersion"))
Assert ($matching -eq 0) 'a matching independent version source compiles'
$installer = Join-Path $output 'guard-fixture.exe'
Assert (Test-Path -LiteralPath $installer -PathType Leaf) 'fixture installer was generated'
function Invoke-Fixture([string]$Target, [string]$Name) {
    $log = Join-Path $fixture ($Name + '.log')
    $rtkPath = (Get-Command rtk.exe -ErrorAction Stop).Source
    $arguments = @('proxy', ('"' + $installer + '"'), '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', ('"/DIR=' + $Target + '"'), ('"/LOG=' + $log + '"'))
    $process = Start-Process -FilePath $rtkPath -ArgumentList $arguments -PassThru -Wait -WindowStyle Hidden
    return $process.ExitCode
}
foreach ($case in @('sdk','avd','legacy')) {
    $target = Join-Path $fixture ('existing-' + $case)
    switch ($case) {
        'sdk' { $item = Join-Path $target 'sdk\emulator\emulator.exe' }
        'avd' { $item = Join-Path $target 'data\avd\Phone.avd\userdata-qemu.img' }
        'legacy' { $item = Join-Path $target 'launch.ps1' }
    }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $item))
    [IO.File]::WriteAllText($item, 'existing data must survive', [Text.Encoding]::ASCII)
    if ($case -eq 'legacy') { [IO.File]::WriteAllText((Join-Path $target 'version.ini'), 'old version', [Text.Encoding]::ASCII) }
    $oldHash = (Get-FileHash -LiteralPath $item -Algorithm SHA256).Hash
    $status = Invoke-Fixture $target $case
    Assert ($status -ne 0) "${case}: silent setup rejects an existing install"
    Assert ((Get-FileHash -LiteralPath $item -Algorithm SHA256).Hash -eq $oldHash) "${case}: existing data is unchanged"
    Assert (-not (Test-Path -LiteralPath (Join-Path $target 'payload.txt'))) "${case}: no new files were installed"
    $logText = [IO.File]::ReadAllText((Join-Path $fixture ($case + '.log')))
    $rejected = [string]::Concat([char]0x5B89, [char]0x88C5, [char]0x88AB, [char]0x963B, [char]0x6B62)
    Assert ($logText.Contains($rejected)) "${case}: rejection is recorded in the setup log"
}
foreach ($case in @('new','empty')) {
    $target = Join-Path $fixture ('fresh-' + $case)
    if ($case -ne 'new') { [void][IO.Directory]::CreateDirectory($target) }
    $status = Invoke-Fixture $target $case
    Assert ($status -eq 0) "${case}: silent fresh setup succeeds"
    Assert (Test-Path -LiteralPath (Join-Path $target 'payload.txt')) "${case}: fixture payload is installed"
    Assert ([IO.File]::ReadAllText((Join-Path $target 'version.ini')).Contains('Version=0.3.6')) "${case}: selected version file is installed"
    $preferences = [IO.File]::ReadAllText((Join-Path $target 'data\preferences.ini'))
    Assert ($preferences -match '(?m)^graphics=host\r?$') "${case}: fresh setup retains the hardware-first default"
}

foreach ($case in @('unrelated','collision','hidden')) {
    $target = Join-Path $fixture ('nonempty-' + $case)
    [void][IO.Directory]::CreateDirectory($target)
    $name = if ($case -eq 'collision') { 'version.ini' } else { 'keep.txt' }
    $item = Join-Path $target $name
    [IO.File]::WriteAllText($item, 'user file must survive', [Text.Encoding]::ASCII)
    if ($case -eq 'hidden') { (Get-Item -LiteralPath $item -Force).Attributes = [IO.FileAttributes]::Hidden }
    $oldHash = (Get-FileHash -LiteralPath $item -Algorithm SHA256).Hash
    $status = Invoke-Fixture $target ('nonempty-' + $case)
    Assert ($status -ne 0) "${case}: a nonempty target is rejected"
    Assert ((Get-FileHash -LiteralPath $item -Algorithm SHA256).Hash -eq $oldHash) "${case}: user file is unchanged"
    Assert (-not (Test-Path -LiteralPath (Join-Path $target 'payload.txt'))) "${case}: no files were installed"
}

$outside = Join-Path $fixture 'link-target'
[void][IO.Directory]::CreateDirectory($outside)
[IO.File]::WriteAllText((Join-Path $outside 'keep.txt'), 'junction target must survive', [Text.Encoding]::ASCII)
$link = Join-Path $fixture 'junction'
New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
$status = Invoke-Fixture (Join-Path $link 'new-child') 'junction-parent'
Assert ($status -ne 0) 'a junction in an installation path is rejected'
Assert ([IO.File]::ReadAllText((Join-Path $outside 'keep.txt')) -eq 'junction target must survive') 'junction target is unchanged'
Assert (-not (Test-Path -LiteralPath (Join-Path $outside 'new-child'))) 'nothing was created through the junction'

# Seed synthetic preferences after the installation guard and before the
# production ssPostInstall callback. This tests its legacy parsing without
# permitting a real installation to overlay a directory with existing data.
$preseedEvent = @'
<event('CurStepChanged')>
procedure SeedFixturePreferences(CurStep: TSetupStep);
var PreferenceLine: String;
begin
  if CurStep = ssPostInstall then
  begin
    PreferenceLine := GetEnv('ARTEMIS_FIXTURE_PREFERENCE');
    if PreferenceLine <> '' then
    begin
      ForceDirectories(ExpandConstant('{app}\data'));
      SaveStringToFile(ExpandConstant('{app}\data\preferences.ini'), PreferenceLine + #13#10, False);
    end;
  end;
end;
'@
$preseedIss = Join-Path $fixture 'preseed-fixture.iss'
[IO.File]::WriteAllText($preseedIss, ($parts.Groups['header'].Value + "`r`n" + $setup + "`r`n" + $parts.Groups['code'].Value + "`r`n" + $preseedEvent), [Text.UTF8Encoding]::new($true))
& rtk proxy $Iscc '/Qp' ("/DReleaseAppId=$fixtureAppId") '/DAppVersion=0.3.6' ("/DVersionSource=$newVersion") $preseedIss | Out-Host
Assert ($LASTEXITCODE -eq 0) 'installer preference-preservation fixture compiles'
$priorPreference = [Environment]::GetEnvironmentVariable('ARTEMIS_FIXTURE_PREFERENCE', 'Process')
try {
    foreach ($renderer in @('auto','host','software','swiftshader','swangle','lavapipe','missing')) {
        $env:ARTEMIS_FIXTURE_PREFERENCE = if ($renderer -eq 'missing') { 'profile=medium' } else { "graphics=$renderer" }
        $expected = if ($renderer -eq 'missing') { 'host' } else { $renderer }
        $target = Join-Path $fixture ('preferences-' + $renderer)
        $status = Invoke-Fixture $target ('preferences-' + $renderer)
        Assert ($status -eq 0) "${renderer}: preseeded fixture installs successfully"
        $preferences = [IO.File]::ReadAllText((Join-Path $target 'data\preferences.ini'))
        Assert ($preferences -match ('(?m)^graphics=' + [regex]::Escape($expected) + '\r?$')) "${renderer}: installer retains the expected graphics preference"
    }
} finally {
    [Environment]::SetEnvironmentVariable('ARTEMIS_FIXTURE_PREFERENCE', $priorPreference, 'Process')
}
Write-Host "Fixture evidence: $fixture"
