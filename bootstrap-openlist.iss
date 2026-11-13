#ifndef OpenListServerFile
  #error Specify OpenListServerFile as the build-time path to the OpenList share configuration.
#endif

[Setup]
AppName=ArtemisOS 15 更新连接组件
AppVersion=0.3.5
AppPublisher=内部测试
DefaultDirName={code:GetExistingDirectory}
DisableProgramGroupPage=yes
DisableWelcomePage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.17134
SetupIconFile=stage\ArtemisOS15.ico
InfoBeforeFile=docs\openlist-connect-info.txt
OutputDir=dist
OutputBaseFilename=ArtemisOS15-OpenList-Connect-0.3.5
Compression=lzma2/fast
SolidCompression=yes
WizardStyle=modern
Uninstallable=no
CreateUninstallRegKey=no
CloseApplications=no

[Languages]
Name: "chinesesimp"; MessagesFile: "ChineseSimplified.isl"

[Files]
Source: "stage\update\trusted-key.xml"; Flags: dontcopy
Source: "stage\update\core.ps1"; DestDir: "{app}\update"; Flags: ignoreversion
Source: "{#OpenListServerFile}"; DestDir: "{app}\update"; DestName: "server.txt"; Flags: ignoreversion
Source: "{#OpenListServerFile}"; DestDir: "{app}\data\update"; DestName: "server.txt"; Flags: ignoreversion

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
  AppRoot, BackupDir, SourcePath, DestinationPath: String;
  Lines: TArrayOfString;
  I: Integer;
  ValidVersion: Boolean;
begin
  Result := '';
  AppRoot := ExpandConstant('{app}');
  ValidVersion := False;
  if LoadStringsFromFile(AddBackslash(AppRoot) + 'version.ini', Lines) then
    for I := 0 to GetArrayLength(Lines) - 1 do
      if Trim(Lines[I]) = 'Version=0.3.4' then ValidVersion := True;
  if not ValidVersion or
     not FileExists(AddBackslash(AppRoot) + 'update\core.ps1') or
     not FileExists(AddBackslash(AppRoot) + 'update\bridge.ps1') or
     not FileExists(AddBackslash(AppRoot) + 'update\trusted-key.xml') then
  begin
    Result := '请选择已安装的 ArtemisOS 15 v0.3.4 目录。此组件不修改模拟器数据或当前版本。';
    Exit;
  end;
  if FileExists(AddBackslash(AppRoot) + 'data\update\pending\applying.flag') then
  begin
    Result := '存在尚未完成的更新，请先启动模拟器完成恢复，再退出模拟器后重试。';
    Exit;
  end;
  ExtractTemporaryFile('trusted-key.xml');
  if CompareText(GetSHA256OfFile(AddBackslash(AppRoot) + 'update\trusted-key.xml'),
                 GetSHA256OfFile(ExpandConstant('{tmp}\trusted-key.xml'))) <> 0 then
  begin
    Result := '此安装使用不同的更新签名公钥，不能自动切换更新源。';
    Exit;
  end;
  BackupDir := AddBackslash(AppRoot) + 'data\update\before-openlist-' + GetDateTimeString('yyyymmdd-hhnnss', '-', ':');
  if DirExists(BackupDir) or not ForceDirectories(BackupDir) then
  begin
    Result := '无法创建原更新配置备份。请稍后重试。';
    Exit;
  end;
  SourcePath := AddBackslash(AppRoot) + 'update\core.ps1';
  if not CopyFile(SourcePath, AddBackslash(BackupDir) + 'core.ps1', True) then
  begin
    Result := '无法备份原更新组件，请确认安装目录可写。';
    Exit;
  end;
  for I := 0 to 1 do
  begin
    if I = 0 then
    begin
      SourcePath := AddBackslash(AppRoot) + 'update\server.txt';
      DestinationPath := AddBackslash(BackupDir) + 'default-server.txt';
    end
    else
    begin
      SourcePath := AddBackslash(AppRoot) + 'data\update\server.txt';
      DestinationPath := AddBackslash(BackupDir) + 'user-server.txt';
    end;
    if FileExists(SourcePath) and not CopyFile(SourcePath, DestinationPath, True) then
    begin
      Result := '无法备份原更新地址，请确认安装目录可写。';
      Exit;
    end;
  end;
end;
