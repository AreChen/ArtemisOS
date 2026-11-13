; Experimental version-pinned bootstrap template. The fresh installer is embedded as
; an opaque payload and is extracted only for a fresh installation.
#ifndef ArtemisBootstrapExperimental
  #error Experimental template only. Define ArtemisBootstrapExperimental for isolated fixture tests.
#endif
#ifndef FreshInstaller
  #error FreshInstaller must name the completed target installer.
#endif
#ifndef BaselineInventory
  #error BaselineInventory must name the verified source inventory.
#endif
#ifndef TargetInventory
  #error TargetInventory must name the verified target inventory.
#endif
#ifndef BootstrapFromVersion
  #error BootstrapFromVersion must name the only supported source version.
#endif
#ifndef BootstrapToVersion
  #error BootstrapToVersion must name the target version.
#endif
#ifndef DiscoverySource
  #define DiscoverySource "tools\Find-ArtemisInstallations.ps1"
#endif
#ifndef DiscoveryModule
  #define DiscoveryModule "tools\ArtemisInstallDiscovery.psm1"
#endif
#ifndef BootstrapSource
  #define BootstrapSource "tools\Invoke-OtaBootstrap.ps1"
#endif
#define FreshInstallerName ExtractFileName(FreshInstaller)

[Setup]
AppId=ArtemisOS15-Bootstrap
SetupMutex=ArtemisOS.Bootstrap.{#BootstrapToVersion}
AppName=ArtemisOS 15 安装与升级
AppVersion={#BootstrapToVersion}
AppPublisher=ArtemisOS
DefaultDirName={tmp}\artemis-bootstrap
DisableProgramGroupPage=yes
DisableDirPage=yes
DisableWelcomePage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.17134
Uninstallable=no
CreateUninstallRegKey=no
CloseApplications=no
RestartApplications=no
SetupIconFile=stage\ArtemisOS15.ico
Compression=none
SolidCompression=no
WizardStyle=modern
OutputDir=build\ota-bootstrap-experimental
OutputBaseFilename=EXPERIMENTAL-ONLY-ArtemisOS15-{#BootstrapToVersion}

[Languages]
Name: "chinesesimp"; MessagesFile: "ChineseSimplified.isl"

[Files]
Source: "{#DiscoveryModule}"; Flags: dontcopy
Source: "{#DiscoverySource}"; Flags: dontcopy
Source: "{#BootstrapSource}"; Flags: dontcopy
Source: "{#BaselineInventory}"; Flags: dontcopy
Source: "{#TargetInventory}"; Flags: dontcopy
Source: "{#FreshInstaller}"; Flags: dontcopy nocompression

[Code]
var
  ChoicePage: TInputOptionWizardPage;
  DiscoveryStatus: String;
  CandidatePaths, CandidateVersions: TArrayOfString;
  DiscoveryOk: Boolean;

procedure ExitProcess(ExitCode: Cardinal);
  external 'ExitProcess@kernel32.dll stdcall';

function SetupFailure(const Message: String): String;
begin
  Log('安装或升级未完成：' + Message);
  { PrepareToInstall errors can display a modal dialog even with /SILENT.
    This wrapper has made no changes itself; return failure without prompting. }
  if WizardSilent then ExitProcess(2);
  Result := Message;
end;

function ValueFromLines(const Lines: TArrayOfString; const Key: String): String;
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

function Discover(const ExplicitPath: String): Boolean;
var Args, Path, CountText: String; ExitCode, Count, I: Integer; Lines: TArrayOfString;
begin
  Result := False;
  DiscoveryStatus := 'failed';
  SetArrayLength(CandidatePaths, 0);
  SetArrayLength(CandidateVersions, 0);
  Path := ExpandConstant('{tmp}\discovery-result.ini');
  DeleteFile(Path);
  Args := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
    ExpandConstant('{tmp}\Find-ArtemisInstallations.ps1') + '" -Format Inno -OutputFile "' +
    Path + '" -TargetVersion "{#BootstrapToVersion}"';
  if ExplicitPath <> '' then begin
    if Pos('"', ExplicitPath) > 0 then Exit;
    Args := Args + ' -ExplicitPath "' + RemoveBackslashUnlessRoot(ExplicitPath) + '"';
  end;
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Args, '', SW_HIDE, ewWaitUntilTerminated, ExitCode) or (ExitCode <> 0) then Exit;
  if not LoadStringsFromFile(Path, Lines) or (ValueFromLines(Lines, 'schema') <> '1') then Exit;
  DiscoveryStatus := ValueFromLines(Lines, 'status');
  CountText := ValueFromLines(Lines, 'count');
  Count := StrToIntDef(CountText, -1);
  if (Count < 0) or (Count > 16) then Exit;
  SetArrayLength(CandidatePaths, Count);
  SetArrayLength(CandidateVersions, Count);
  for I := 0 to Count - 1 do begin
    CandidatePaths[I] := ValueFromLines(Lines, 'path' + IntToStr(I));
    CandidateVersions[I] := ValueFromLines(Lines, 'version' + IntToStr(I));
    if (CandidatePaths[I] = '') or (CandidateVersions[I] = '') then Exit;
  end;
  Result := True;
end;

function HasExplicitDir: Boolean;
var I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do if Pos('/DIR=', Uppercase(ParamStr(I))) = 1 then begin Result := True; Exit; end;
end;

procedure InitializeWizard;
var I: Integer;
begin
  ExtractTemporaryFile('ArtemisInstallDiscovery.psm1');
  ExtractTemporaryFile('Find-ArtemisInstallations.ps1');
  ExtractTemporaryFile('Invoke-OtaBootstrap.ps1');
  ExtractTemporaryFile('baseline.json');
  ExtractTemporaryFile('target.json');
  DiscoveryOk := Discover('');
  ChoicePage := CreateInputOptionPage(wpWelcome, '选择安装方式', '安装或升级 ArtemisOS 15',
    '升级需要联网并校验已有安装；多个安装时请明确选择。', True, False);
  ChoicePage.Add('请选择操作');
  ChoicePage.Add('新安装');
  for I := 0 to GetArrayLength(CandidatePaths) - 1 do
    ChoicePage.Add('升级已有安装 ' + CandidateVersions[I] + '：' + CandidatePaths[I]);
  ChoicePage.Values[0] := True;
  if GetArrayLength(CandidatePaths) = 0 then ChoicePage.Values[1] := True;
  if GetArrayLength(CandidatePaths) = 1 then ChoicePage.Values[2] := True;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  { Never open a modal message while setup is running silently. PrepareToInstall
    performs the same checks and returns a non-zero result without prompting. }
  if WizardSilent then Exit;
  if CurPageID = ChoicePage.ID then begin
    if not DiscoveryOk then begin MsgBox('无法检查已有安装，已停止。', mbError, MB_OK); Result := False; Exit; end;
    if (DiscoveryStatus = 'registration_uncertain') or (DiscoveryStatus = 'registration_ambiguous') then begin
      MsgBox('已有安装登记无法核验，已停止。', mbError, MB_OK); Result := False; Exit;
    end;
    if ChoicePage.Values[0] then begin MsgBox('请选择新安装或需要升级的已有安装。', mbInformation, MB_OK); Result := False; end;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var Selected, Args, Details, ResultFile: String; I, ExitCode: Integer; Fresh: Boolean; ResultLines: TArrayOfString;
begin
  Result := '';
  if not DiscoveryOk then begin Result := SetupFailure('无法检查已有安装，已停止。'); Exit; end;
  if (DiscoveryStatus = 'registration_uncertain') or (DiscoveryStatus = 'registration_ambiguous') then begin
    Result := SetupFailure('已有安装登记无法核验，已停止。'); Exit;
  end;
  Selected := '';
  Fresh := False;
  if WizardSilent then begin
    if HasExplicitDir and (GetArrayLength(CandidatePaths) > 0) then begin
      Selected := ExpandConstant('{app}');
      if not Discover(Selected) or (DiscoveryStatus <> 'selected') then begin Result := SetupFailure('指定目录不是可升级的已登记安装。'); Exit; end;
    end else if GetArrayLength(CandidatePaths) > 1 then begin
      Result := SetupFailure('检测到多个安装；静默运行时必须用 /DIR 指定已有安装。'); Exit;
    end else if GetArrayLength(CandidatePaths) = 1 then Selected := CandidatePaths[0]
    else Fresh := True;
  end else begin
    if ChoicePage.Values[0] then begin Result := SetupFailure('请选择安装方式。'); Exit; end;
    if ChoicePage.Values[1] then Fresh := True;
    for I := 0 to GetArrayLength(CandidatePaths) - 1 do
      if ChoicePage.Values[I + 2] then Selected := CandidatePaths[I];
  end;
  if Fresh then begin
    ExtractTemporaryFile('{#FreshInstallerName}');
    Args := '';
    if WizardSilent then Args := '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-';
    if WizardSilent and HasExplicitDir then Args := Args + ' /DIR="' + ExpandConstant('{app}') + '"';
    Log('正在运行全新安装程序。');
    if not Exec(ExpandConstant('{tmp}\{#FreshInstallerName}'), Args, '', SW_SHOWNORMAL, ewWaitUntilTerminated, ExitCode) then begin
      Result := SetupFailure('无法启动全新安装程序。'); Exit;
    end;
    if ExitCode <> 0 then Result := SetupFailure('全新安装未完成，退出代码：' + IntToStr(ExitCode));
    Exit;
  end;
  if Selected = '' then begin Result := SetupFailure('未选择可升级的安装。'); Exit; end;
  if not Discover(Selected) or (DiscoveryStatus <> 'selected') then begin Result := SetupFailure('选择的安装不支持升级或登记已变化。'); Exit; end;
  ResultFile := ExpandConstant('{tmp}\upgrade-result.txt');
  DeleteFile(ResultFile);
  Args := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ExpandConstant('{tmp}\Invoke-OtaBootstrap.ps1') +
    '" -Target "' + Selected + '" -BaselineInventory "' + ExpandConstant('{tmp}\baseline.json') +
    '" -TargetInventory "' + ExpandConstant('{tmp}\target.json') + '" -FromVersion "{#BootstrapFromVersion}" -ToVersion "{#BootstrapToVersion}" -ResultFile "' + ResultFile + '"';
  WizardForm.StatusLabel.Caption := '正在校验已有安装和签名更新，请勿关闭安装程序…';
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Args, '', SW_HIDE, ewWaitUntilTerminated, ExitCode) then begin
    Result := SetupFailure('无法启动升级检查。'); Exit;
  end;
  if ExitCode <> 0 then begin
    Details := '';
    if LoadStringsFromFile(ResultFile, ResultLines) and (GetArrayLength(ResultLines) > 0) then Details := ResultLines[0];
    Result := SetupFailure('升级未完成。原模拟器数据已保留。' + #13#10 + Details);
  end;
end;
