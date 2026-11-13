param(
    [string]$Compiler = (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    [string]$FixtureParent = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build')
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Compiler -PathType Leaf)) { throw 'Inno Setup compiler not found.' }
$parent = (Resolve-Path -LiteralPath $FixtureParent).Path.TrimEnd('\')
$fixture = Join-Path $parent ('installer-inno-' + [Guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $fixture) { throw 'Fixture path unexpectedly exists.' }
[void][IO.Directory]::CreateDirectory($fixture)
$fixtureId = 'ArtemisFixture' + [Guid]::NewGuid().ToString('N')
function Assert([bool]$Ok, [string]$Message) {
    if (-not $Ok) { throw $Message }
    Write-Host "PASS: $Message"
}
function Write-Fixture([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, [Text.Encoding]::ASCII) }
function Run-Setup([string]$Exe, [string]$Dir, [string]$Log) {
    & rtk proxy $Exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- ("/DIR=$Dir") ("/LOG=$Log")
    if ($LASTEXITCODE -ne 0) {
        $details = if (Test-Path -LiteralPath $Log) { [IO.File]::ReadAllText($Log) } else { '' }
        throw "Fixture setup failed: $details"
    }
}
try {
    $payload = Join-Path $fixture 'payload.txt'
    Write-Fixture $payload 'fixture payload'
    $source = @'
[Setup]
AppId=__APP_ID__
AppName=Artemis Fixture
AppVersion=1.0.0
DefaultDirName={tmp}\fixture-default
DisableDirPage=no
DisableWelcomePage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
UsePreviousAppDir=no
PrivilegesRequired=lowest
Uninstallable=UseFixtureUninstaller
CreateUninstallRegKey=UseFixtureRegistry
OutputBaseFilename=branch-test
Compression=lzma2/fast

[Files]
Source: "__PAYLOAD__"; DestDir: "{code:FixtureDestination}"; Flags: ignoreversion

[Code]
var UpgradeChosen: Boolean;

function FixtureBool(Value: Boolean): String;
begin
  if Value then Result := 'True' else Result := 'False';
end;

function UseFixtureUninstaller: Boolean;
begin
  Log('FIXTURE_UNINSTALL_EVAL=' + FixtureBool(UpgradeChosen));
  Result := not UpgradeChosen;
end;

function UseFixtureRegistry: Boolean;
begin
  Log('FIXTURE_REGISTRY_EVAL=' + FixtureBool(UpgradeChosen));
  { A deliberately false fixture guard prevents registry writes in both modes. }
  Result := (not UpgradeChosen) and False;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = wpSelectDir then begin
    UpgradeChosen := Pos('upgrade', Lowercase(WizardDirValue)) > 0;
    Log('FIXTURE_CHOICE=' + FixtureBool(UpgradeChosen));
  end;
end;

function FixtureDestination(Param: String): String;
begin
  if UpgradeChosen then Result := ExpandConstant('{tmp}\fixture-payload')
  else Result := ExpandConstant('{app}');
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and UpgradeChosen then begin
    if not FileExists(ExpandConstant('{tmp}\fixture-payload\payload.txt')) then
      RaiseException('Staged payload missing');
    Log('FIXTURE_TRANSACTION_WOULD_RUN');
  end;
end;
'@.Replace('__APP_ID__',$fixtureId).Replace('__PAYLOAD__',$payload)
    $script = Join-Path $fixture 'branch.iss'
    Write-Fixture $script $source
    & rtk proxy $Compiler ("/O$fixture") $script
    if ($LASTEXITCODE -ne 0) { throw 'Fixture installer compilation failed.' }
    $setup = Join-Path $fixture 'branch-test.exe'
    $upgrade = Join-Path $fixture 'upgrade'
    [void][IO.Directory]::CreateDirectory($upgrade)
    Write-Fixture (Join-Path $upgrade 'old-marker.txt') 'untouched fixture'
    $upgradeLog = Join-Path $fixture 'upgrade.log'
    Run-Setup $setup $upgrade $upgradeLog
    $uLog = [IO.File]::ReadAllText($upgradeLog)
    Assert (($uLog.LastIndexOf('FIXTURE_UNINSTALL_EVAL=True') -gt $uLog.IndexOf('FIXTURE_CHOICE=True')) -and $uLog.Contains('FIXTURE_TRANSACTION_WOULD_RUN')) 'upgrade mode is selected before uninstall decision, with payload staged separately'
    Assert ([IO.File]::ReadAllText((Join-Path $upgrade 'old-marker.txt')) -eq 'untouched fixture' -and @(Get-ChildItem -LiteralPath $upgrade -Force).Count -eq 1) 'upgrade mode never changes the existing fixture directory'

    $fresh = Join-Path $fixture 'fresh-handled'
    $freshLog = Join-Path $fixture 'fresh.log'
    Run-Setup $setup $fresh $freshLog
    $fLog = [IO.File]::ReadAllText($freshLog)
    Assert (($fLog.LastIndexOf('FIXTURE_UNINSTALL_EVAL=False') -gt $fLog.IndexOf('FIXTURE_CHOICE=False')) -and (Test-Path -LiteralPath (Join-Path $fresh 'unins000.dat'))) 'fresh mode creates an uninstaller after the directory choice'
    Assert ($fLog.LastIndexOf('FIXTURE_REGISTRY_EVAL=False') -gt $fLog.IndexOf('FIXTURE_CHOICE=False')) 'the registration decision is evaluated after the directory choice'

    $withoutHelper = Join-Path $fixture 'fresh-unhandled'
    Run-Setup $setup $withoutHelper (Join-Path $fixture 'unhandled.log')
    Write-Fixture (Join-Path $withoutHelper 'new-managed.txt') 'added after initial setup'
    & rtk proxy (Join-Path $withoutHelper 'unins000.exe') /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
    if ($LASTEXITCODE -ne 0) { throw 'Fixture baseline uninstaller failed.' }
    Assert (Test-Path -LiteralPath (Join-Path $withoutHelper 'new-managed.txt')) 'the old uninstall log does not remove a file added later'

    Write-Fixture (Join-Path $fresh 'new-managed.txt') 'added after initial setup'
    [void][IO.Directory]::CreateDirectory((Join-Path $fresh 'data'))
    Write-Fixture (Join-Path $fresh 'data\userdata.txt') 'fixture user data'
    $helperSource = @'
[Setup]
AppId=__APP_ID__
AppName=Artemis Fixture
AppVersion=1.0.0
DefaultDirName={tmp}\fixture-helper-default
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
OutputBaseFilename=append-test
Compression=lzma2/fast

[UninstallDelete]
Type: files; Name: "{app}\new-managed.txt"
'@.Replace('__APP_ID__',$fixtureId)
    $helperScript = Join-Path $fixture 'append.iss'
    Write-Fixture $helperScript $helperSource
    & rtk proxy $Compiler ("/O$fixture") $helperScript
    if ($LASTEXITCODE -ne 0) { throw 'Fixture helper compilation failed.' }
    $dat = Join-Path $fresh 'unins000.dat'
    $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($dat))
    Run-Setup (Join-Path $fixture 'append-test.exe') $fresh (Join-Path $fixture 'append.log')
    Assert (([Convert]::ToBase64String([IO.File]::ReadAllBytes($dat)) -cne $before) -and @(Get-ChildItem -LiteralPath $fresh -Filter 'unins*.dat').Count -eq 1) 'a same-AppId helper appends one cleanup entry to the existing uninstall log'
    & rtk proxy (Join-Path $fresh 'unins000.exe') /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
    if ($LASTEXITCODE -ne 0) { throw 'Fixture appended uninstaller failed.' }
    Assert (-not (Test-Path -LiteralPath (Join-Path $fresh 'new-managed.txt')) -and (Test-Path -LiteralPath (Join-Path $fresh 'data\userdata.txt'))) 'the appended entry cleans the managed file and retains user data'
} finally {
    # Only delete this test's exact freshly created fixture under its resolved parent.
    if (Test-Path -LiteralPath $fixture) {
        $item = Get-Item -LiteralPath $fixture -Force
        if ($item.FullName -ine $fixture -or $item.Parent.FullName.TrimEnd('\') -ine $parent -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe fixture cleanup path.' }
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}
