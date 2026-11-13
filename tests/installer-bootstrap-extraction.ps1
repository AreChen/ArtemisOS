param([string]$Compiler = (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'))
$ErrorActionPreference = 'Stop'
$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$work = Join-Path $parent ('artemisos-bootstrap-extraction-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
try {
    $inner = @'
[Setup]
AppName=Fixture nested fresh installer
AppVersion=1.0
DefaultDirName={tmp}\fixture-fresh
DisableWelcomePage=yes
DisableDirPage=yes
DisableReadyPage=yes
DisableFinishedPage=yes
PrivilegesRequired=lowest
Uninstallable=no
CreateUninstallRegKey=no
Compression=none
OutputBaseFilename=fixture-fresh
[Code]
procedure CurStepChanged(Step: TSetupStep);
begin
  if Step = ssPostInstall then SaveStringToFile(ExpandConstant('{app}\ran.txt'), 'fresh ran', False);
end;
'@
    $outer = @'
#define PayloadPath GetEnv('ARTEMIS_FIXTURE_PAYLOAD')
[Setup]
AppName=Fixture OTA bootstrap
AppVersion=1.0
DefaultDirName={tmp}\fixture-bootstrap
DisableWelcomePage=yes
DisableDirPage=yes
DisableReadyPage=yes
DisableFinishedPage=yes
PrivilegesRequired=lowest
Uninstallable=no
CreateUninstallRegKey=no
Compression=none
OutputBaseFilename=fixture-bootstrap
[Files]
Source: "{#PayloadPath}"; Flags: dontcopy
[Code]
procedure ExitProcess(ExitCode: Cardinal); external 'ExitProcess@kernel32.dll stdcall';
function IsFresh: Boolean;
var I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do if CompareText(ParamStr(I), '/FIXTUREMODE=FRESH') = 0 then Result := True;
end;
procedure CurStepChanged(Step: TSetupStep);
var Code: Integer; ChildDir: String;
begin
  if Step <> ssInstall then Exit;
  if IsFresh then begin
    ExtractTemporaryFile('fixture-fresh.exe');
    Log('FIXTURE_FRESH_EXTRACTED');
    ChildDir := ExpandConstant('{tmp}\nested-installed');
    if not Exec(ExpandConstant('{tmp}\fixture-fresh.exe'), '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR="' + ChildDir + '"', '', SW_HIDE, ewWaitUntilTerminated, Code) then ExitProcess(5);
    if (Code <> 0) or not FileExists(ChildDir + '\ran.txt') then ExitProcess(6);
    Log('FIXTURE_FRESH_COMPLETED');
  end else begin
    if FileExists(ExpandConstant('{tmp}\fixture-fresh.exe')) then ExitProcess(7);
    Log('FIXTURE_UPGRADE_SKIPPED_FRESH_EXTRACTION');
  end;
end;
'@
    [IO.File]::WriteAllText((Join-Path $work 'inner.iss'), $inner, [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $work 'outer.iss'), $outer, [Text.Encoding]::ASCII)
    & rtk proxy $Compiler ("/O$work") (Join-Path $work 'inner.iss') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Nested fixture compiler failed.' }
    $env:ARTEMIS_FIXTURE_PAYLOAD = Join-Path $work 'fixture-fresh.exe'
    & rtk proxy $Compiler ("/O$work") (Join-Path $work 'outer.iss') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Bootstrap fixture compiler failed.' }
    $setup = Join-Path $work 'fixture-bootstrap.exe'
    foreach ($mode in @('fresh','upgrade')) {
        $log = Join-Path $work ($mode + '.log')
        & rtk proxy $setup /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ("/FIXTUREMODE=$mode") ("/LOG=$log")
        if ($LASTEXITCODE -ne 0) { throw "Fixture bootstrap failed: $mode." }
        $text = [IO.File]::ReadAllText($log)
        if ($mode -eq 'fresh' -and $text -notmatch 'FIXTURE_FRESH_COMPLETED') { throw 'Nested fresh installer did not execute.' }
        if ($mode -eq 'upgrade' -and ($text -notmatch 'FIXTURE_UPGRADE_SKIPPED_FRESH_EXTRACTION' -or $text -match 'Extracting temporary file: .*fixture-fresh\.exe')) {
            throw 'Upgrade unexpectedly extracted the nested installer.'
        }
        Write-Host "PASS: $mode bootstrap follows the correct nested extraction branch"
    }
} finally {
    Remove-Item Env:ARTEMIS_FIXTURE_PAYLOAD -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $work) {
        $item = Get-Item -LiteralPath $work -Force
        if ($item.Parent.FullName.TrimEnd('\') -ine $parent -or $item.Name -cnotmatch '^artemisos-bootstrap-extraction-[0-9a-f]{32}$' -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe fixture cleanup.' }
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
