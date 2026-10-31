#define AppName "ArtemisOS 15"
#define AppVersion ReadIni(AddBackslash(SourcePath) + "stage\version.ini", "ArtemisOS", "Version", "")
#if AppVersion == ""
  #error Missing ArtemisOS version in stage\version.ini
#endif

[Setup]
AppId={{E49344F1-069E-4DA4-A5B7-232C0BE325A8}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=内部测试
DefaultDirName={localappdata}\ArtemisOS15
DefaultGroupName=ArtemisOS 15
UsePreviousGroup=no
DisableProgramGroupPage=yes
DisableWelcomePage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.17134
SetupIconFile=stage\ArtemisOS15.ico
UninstallDisplayIcon={app}\ArtemisOS15.ico
WizardSmallImageFile=stage\ArtemisOS15-wizard.png
WizardImageFile=stage\ArtemisOS15-banner.bmp
OutputDir=dist
OutputBaseFilename=ArtemisOS15-Offline-Installer-{#AppVersion}
Compression=lzma2/fast
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
RestartApplications=no

[Languages]
Name: "chinesesimp"; MessagesFile: "ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "其他选项："

[Files]
; The previous release includes the same SDK. Avoid replacing files in a running installation.
Source: "stage\sdk\*"; DestDir: "{app}\sdk"; Flags: onlyifdoesntexist recursesubdirs createallsubdirs
Source: "stage\launch.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "stage\settings.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "stage\version.ini"; DestDir: "{app}"; Flags: ignoreversion
Source: "stage\initialize.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "stage\configure.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "stage\configure.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "stage\ArtemisOS15.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "stage\start-auto.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "stage\start-software.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "stage\update\*"; DestDir: "{app}\update"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "stage\使用说明.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "stage\licenses\*.txt"; DestDir: "{app}\licenses"; Flags: ignoreversion

[Icons]
Name: "{group}\ArtemisOS 15"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\start-auto.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\ArtemisOS15.ico"
Name: "{group}\ArtemisOS 15（软件渲染）"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\start-software.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\ArtemisOS15.ico"
Name: "{group}\ArtemisOS 15（配置）"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\configure.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\ArtemisOS15.ico"
Name: "{group}\使用说明"; Filename: "{app}\使用说明.txt"
Name: "{userdesktop}\ArtemisOS 15"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\start-auto.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\ArtemisOS15.ico"; Tasks: desktopicon
Name: "{userdesktop}\ArtemisOS 15（软件渲染）"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\start-software.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\ArtemisOS15.ico"; Tasks: desktopicon
Name: "{userdesktop}\ArtemisOS 15（配置）"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\configure.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\ArtemisOS15.ico"; Tasks: desktopicon

[Run]
Filename: "{sys}\wscript.exe"; Parameters: """{app}\start-auto.vbs"""; Description: "启动 ArtemisOS 15"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent

[Code]
var
  ProfilePage: TInputOptionWizardPage;
  LastProfileDir: String;

procedure InitializeWizard;
begin
  ProfilePage := CreateInputOptionPage(wpSelectDir, '选择模拟器配置',
    '请根据电脑性能选择配置',
    '安装完成后，可以通过桌面的“ArtemisOS 15（配置）”随时调整；修改后重新启动模拟器生效。', True, False);
  ProfilePage.Add('低：2 核 / 2.5 GB；建议电脑内存至少 8 GB');
  ProfilePage.Add('中：4 核 / 4 GB；建议电脑内存至少 16 GB');
  ProfilePage.Add('高：6 核 / 8 GB；建议电脑内存至少 16 GB');
  ProfilePage.Values[0] := True;
  LastProfileDir := '';
end;

procedure CurPageChanged(CurPageID: Integer);
var
  Lines: TArrayOfString;
  I: Integer;
begin
  if CurPageID = ProfilePage.ID then
  begin
    WizardForm.NextButton.Caption := '开始安装(&I)';
    if LastProfileDir <> WizardDirValue then
    begin
      ProfilePage.Values[0] := True;
      if LoadStringsFromFile(AddBackslash(WizardDirValue) + 'data\preferences.ini', Lines) then
        for I := 0 to GetArrayLength(Lines) - 1 do
        begin
          if Lines[I] = 'profile=medium' then ProfilePage.Values[1] := True;
          if Lines[I] = 'profile=high' then ProfilePage.Values[2] := True;
        end;
      LastProfileDir := WizardDirValue;
    end;
  end
  else if CurPageID = wpFinished then WizardForm.NextButton.Caption := SetupMessage(msgButtonFinish)
  else WizardForm.NextButton.Caption := SetupMessage(msgButtonNext);
end;

procedure RemoveOldShortcut(const ShortcutPath, ScriptName: String);
var
  Shell, Link: Variant;
  TargetPath, Arguments: String;
begin
  if not FileExists(ShortcutPath) then Exit;
  try
    Shell := CreateOleObject('WScript.Shell');
    Link := Shell.CreateShortcut(ShortcutPath);
    TargetPath := Link.TargetPath;
    Arguments := Link.Arguments;
    if (CompareText(TargetPath, ExpandConstant('{sys}\wscript.exe')) = 0) and
       (Pos(Lowercase(ExpandConstant('{app}\') + ScriptName), Lowercase(Arguments)) > 0) then
      DeleteFile(ShortcutPath);
  except
    Log('无法清理旧快捷方式：' + ShortcutPath);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Profile, Cleanup, Preferences: String;
  Lines: TArrayOfString;
  I: Integer;
begin
  if CurStep <> ssPostInstall then Exit;
  Profile := 'low';
  if ProfilePage.Values[1] then Profile := 'medium';
  if ProfilePage.Values[2] then Profile := 'high';
  Cleanup := '1';
  Preferences := ExpandConstant('{app}\data\preferences.ini');
  if LoadStringsFromFile(Preferences, Lines) then
    for I := 0 to GetArrayLength(Lines) - 1 do
    begin
      if Lines[I] = 'cleanup=0' then Cleanup := '0';
      if WizardSilent and (Lines[I] = 'profile=medium') then Profile := 'medium';
      if WizardSilent and (Lines[I] = 'profile=high') then Profile := 'high';
    end;
  ForceDirectories(ExpandConstant('{app}\data'));
  if not SaveStringToFile(Preferences, 'profile=' + Profile + #13#10 + 'cleanup=' + Cleanup + #13#10, False) then
    MsgBox('无法保存模拟器配置，请使用桌面的配置入口重新设置。', mbError, MB_OK);
  RemoveOldShortcut(ExpandConstant('{userdesktop}\安卓虚拟手机（内部测试）.lnk'), 'start-auto.vbs');
  RemoveOldShortcut(ExpandConstant('{userdesktop}\安卓虚拟手机（软件渲染）.lnk'), 'start-software.vbs');
  RemoveOldShortcut(ExpandConstant('{userprograms}\安卓虚拟手机（内部测试）\安卓虚拟手机.lnk'), 'start-auto.vbs');
  RemoveOldShortcut(ExpandConstant('{userprograms}\安卓虚拟手机（内部测试）\安卓虚拟手机（软件渲染）.lnk'), 'start-software.vbs');
end;

function CompatibleInstallPath(const Path: String): Boolean;
var
  I: Integer;
begin
  Result := True;
  for I := 1 to Length(Path) do
    if Ord(Path[I]) > 127 then
    begin
      Result := False;
      Exit;
    end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = wpSelectDir) and not CompatibleInstallPath(WizardDirValue) then
  begin
    MsgBox('安装路径不能包含中文或其他非英文字符。请选择只包含英文字母、数字和空格的路径。', mbError, MB_OK);
    Result := False;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not CompatibleInstallPath(ExpandConstant('{app}')) then
    Result := '安装路径不能包含中文或其他非英文字符。请选择英文路径后重试。';
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := PageID = wpSelectTasks;
end;
