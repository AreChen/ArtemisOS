{ Included from installer-upgrade.iss [Code]. Prototype only. }
var
  UpgradeMode: Boolean;
  ChoicePage: TInputOptionWizardPage;
  DiscoveryStatus: String;
  DiscoveryPaths, DiscoveryVersions: TArrayOfString;

function IsFreshInstall: Boolean;
begin
  Result := not UpgradeMode;
end;

function ShouldCreateIcons: Boolean;
begin
#ifdef ArtemisUpgradeFixture
  Result := False;
#else
  Result := IsFreshInstall;
#endif
end;

function InstallPayloadRoot(Param: String): String;
begin
  if UpgradeMode then Result := ExpandConstant('{tmp}\artemis-payload')
  else Result := ExpandConstant('{app}');
end;

function DiscoveryValue(const Lines: TArrayOfString; const Key: String): String;
var I: Integer; Prefix: String;
begin
  Result := '';
  Prefix := Key + '=';
  for I := 0 to GetArrayLength(Lines) - 1 do
    if Pos(Prefix, Lines[I]) = 1 then begin
      Result := Copy(Lines[I], Length(Prefix) + 1, Length(Lines[I]));
      Exit;
    end;
end;

function DiscoverInstallations(const ExplicitPath: String): Boolean;
var Args, OutputPath, CountText: String; ExitCode, Count, I: Integer; Lines: TArrayOfString;
begin
  Result := False;
  DiscoveryStatus := 'failed';
  SetArrayLength(DiscoveryPaths, 0);
  SetArrayLength(DiscoveryVersions, 0);
  OutputPath := ExpandConstant('{tmp}\artemis-discovery.txt');
  DeleteFile(OutputPath);
  Args := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
    ExpandConstant('{tmp}\Find-ArtemisInstallations.ps1') + '" -Format Inno -OutputFile "' +
    OutputPath + '" -TargetVersion "{#AppVersion}"';
  if ExplicitPath <> '' then begin
    if Pos('"', ExplicitPath) > 0 then Exit;
    Args := Args + ' -ExplicitPath "' + RemoveBackslashUnlessRoot(ExplicitPath) + '"';
  end;
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Args, '', SW_HIDE, ewWaitUntilTerminated, ExitCode) or (ExitCode <> 0) then Exit;
  if not LoadStringsFromFile(OutputPath, Lines) then Exit;
  if DiscoveryValue(Lines, 'schema') <> '1' then Exit;
  DiscoveryStatus := DiscoveryValue(Lines, 'status');
  CountText := DiscoveryValue(Lines, 'count');
  Count := StrToIntDef(CountText, -1);
  if (Count < 0) or (Count > 16) then Exit;
  SetArrayLength(DiscoveryPaths, Count);
  SetArrayLength(DiscoveryVersions, Count);
  for I := 0 to Count - 1 do begin
    DiscoveryPaths[I] := DiscoveryValue(Lines, 'path' + IntToStr(I));
    DiscoveryVersions[I] := DiscoveryValue(Lines, 'version' + IntToStr(I));
    if (DiscoveryPaths[I] = '') or (DiscoveryVersions[I] = '') then Exit;
  end;
  Result := True;
end;

function HasExplicitInstallDir: Boolean;
var I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if Pos('/DIR=', Uppercase(ParamStr(I))) = 1 then begin Result := True; Exit; end;
end;

procedure InitializePrototypeChoices;
var I: Integer;
begin
  ExtractTemporaryFile('ArtemisInstallDiscovery.psm1');
  ExtractTemporaryFile('Find-ArtemisInstallations.ps1');
  ExtractTemporaryFile('Upgrade-Transaction.ps1');
  DiscoverInstallations('');
  ChoicePage := CreateInputOptionPage(wpWelcome, '安装方式', '选择已有安装或新安装',
    '检测到多个安装时，请选择需要处理的安装目录。当前原型不会修改已注册安装。', True, False);
  ChoicePage.Add('新安装（选择新目录）');
  for I := 0 to GetArrayLength(DiscoveryPaths) - 1 do
    ChoicePage.Add('已有安装 ' + DiscoveryVersions[I] + '：' + DiscoveryPaths[I]);
  ChoicePage.Values[0] := True;
  if GetArrayLength(DiscoveryPaths) = 1 then ChoicePage.Values[1] := True;
end;

procedure ApplyChoice;
var I: Integer;
begin
  if (WizardSilent and HasExplicitInstallDir) then Exit;
  for I := 0 to GetArrayLength(DiscoveryPaths) - 1 do
    if ChoicePage.Values[I + 1] then begin WizardForm.DirEdit.Text := DiscoveryPaths[I]; Exit; end;
end;

#ifdef ArtemisUpgradeFixture
function IsIsolatedFixture(const Path: String): Boolean;
var Prefix: String;
begin
  Prefix := AddBackslash(GetEnv('TEMP')) + 'artemisos-fixture-';
  Result := (Pos(Lowercase(Prefix), Lowercase(Path)) = 1) and
    FileExists(AddBackslash(Path) + '.artemis-test-fixture');
end;
#endif

procedure ExitProcess(ExitCode: Cardinal);
  external 'ExitProcess@kernel32.dll stdcall';

procedure ApplyPrototypeTransaction;
var Args: String; ExitCode: Integer;
begin
  Args := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
    ExpandConstant('{tmp}\Upgrade-Transaction.ps1') + '" -Action Apply -Target "' +
    RemoveBackslashUnlessRoot(ExpandConstant('{app}')) + '" -Payload "' +
    ExpandConstant('{tmp}\artemis-payload') + '"';
  WizardForm.StatusLabel.Caption := '正在验证并应用升级，请勿关闭安装程序…';
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Args, '', SW_HIDE, ewWaitUntilTerminated, ExitCode) or (ExitCode <> 0) then begin
    Log('事务失败；请使用事务恢复工具检查。');
    ExitProcess(5);
  end;
end;
