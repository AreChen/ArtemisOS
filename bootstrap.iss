#define AppVersion ReadIni(AddBackslash(SourcePath) + "stage\version.ini", "ArtemisOS", "Version", "")

[Setup]
AppName=ArtemisOS 15 更新组件
AppVersion={#AppVersion}
AppPublisher=内部测试
DefaultDirName={code:GetExistingDirectory}
DisableProgramGroupPage=yes
DisableWelcomePage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.17134
SetupIconFile=stage\ArtemisOS15.ico
OutputDir=dist
OutputBaseFilename=ArtemisOS15-Update-Client-{#AppVersion}
Compression=lzma2/fast
SolidCompression=yes
WizardStyle=modern
Uninstallable=no
CreateUninstallRegKey=no
CloseApplications=no

[Languages]
Name: "chinesesimp"; MessagesFile: "ChineseSimplified.isl"

[Files]
Source: "stage\launch.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "stage\settings.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "stage\initialize.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "stage\configure.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "stage\configure.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "stage\start-auto.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "stage\start-software.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "stage\使用说明.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "stage\update\*"; DestDir: "{app}\update"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "stage\version.ini"; DestDir: "{app}"; Flags: ignoreversion

[Code]
const
  UninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{E49344F1-069E-4DA4-A5B7-232C0BE325A8}_is1';

function GetExistingDirectory(Param: String): String;
begin
  if not RegQueryStringValue(HKCU, UninstallKey, 'InstallLocation', Result) then
    Result := ExpandConstant('{localappdata}\ArtemisOS15');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Lines: TArrayOfString;
  I: Integer;
  Found: Boolean;
begin
  Result := '';
  Found := False;
  if LoadStringsFromFile(ExpandConstant('{app}\version.ini'), Lines) then
    for I := 0 to GetArrayLength(Lines) - 1 do
      if Trim(Lines[I]) = 'Version=0.2.3' then Found := True;
  if not Found then
    Result := '请选择已安装的 ArtemisOS 15 v0.2.3 目录。此组件不会清除模拟器数据。';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Existing: String;
begin
  if CurStep = ssPostInstall then
    if RegQueryStringValue(HKCU, UninstallKey, 'InstallLocation', Existing) then
      if CompareText(RemoveBackslashUnlessRoot(Existing), RemoveBackslashUnlessRoot(ExpandConstant('{app}'))) = 0 then
      begin
        RegWriteStringValue(HKCU, UninstallKey, 'DisplayVersion', '{#AppVersion}');
        RegWriteStringValue(HKCU, UninstallKey, 'DisplayName', 'ArtemisOS 15 版本 {#AppVersion}');
      end;
end;
