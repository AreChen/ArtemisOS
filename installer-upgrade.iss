#define AppName "ArtemisOS 15"
#ifdef OpenListServerFile
  #error OpenListServerFile is retired. Use the checked-in stage/update/server.txt default.
#endif
; EXPERIMENTAL PROTOTYPE ONLY. A registered installation is never upgraded by
; this script until uninstall-log and registry updates have transactional recovery.
#ifdef RuntimeReuseInclude
  #error Runtime reuse is not yet supported by the upgrade prototype.
#endif
#ifndef VersionSource
  #define VersionSource AddBackslash(SourcePath) + "stage\version.ini"
#endif
#define VersionSourceValue ReadIni(VersionSource, "ArtemisOS", "Version", "")
#ifndef AppVersion
  #define AppVersion VersionSourceValue
#endif
#ifndef SdkSource
  #define SdkSource "stage\sdk"
#endif
#ifndef PackageCompression
  #define PackageCompression "lzma2/max"
#endif
#ifndef ReleaseAppId
  #define ReleaseAppId "{{E49344F1-069E-4DA4-A5B7-232C0BE325A8}"
#endif
#ifndef ReleaseShortcutName
  #define ReleaseShortcutName AppName
#endif
#ifndef ReleaseDefaultDirName
  #define ReleaseDefaultDirName "ArtemisOS15"
#endif
#if AppVersion == ""
  #error Missing ArtemisOS version in VersionSource
#endif
#if AppVersion != VersionSourceValue
  #error AppVersion does not match the version.ini selected by VersionSource
#endif
#ifdef SparseImageSha256
  #if Len(SparseImageSha256) != 64
    #error SparseImageSha256 must contain the complete image SHA-256.
  #endif
#endif

[Setup]
AppId={#ReleaseAppId}
; Serialize installers for the same identity, including before registration.
SetupMutex=ArtemisOS.Setup.{#ReleaseAppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=ArtemisOS
Uninstallable=IsFreshInstall
#ifdef ArtemisUpgradeFixture
CreateUninstallRegKey=no
#else
CreateUninstallRegKey=IsFreshInstall
#endif
UsePreviousAppDir=no
DefaultDirName={localappdata}\{#ReleaseDefaultDirName}
DefaultGroupName={#ReleaseShortcutName}
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
#if ReleaseShortcutName != AppName
UninstallDisplayName={#ReleaseShortcutName}
#endif
WizardSmallImageFile=stage\ArtemisOS15-wizard.png
WizardImageFile=stage\ArtemisOS15-banner.bmp
OutputDir=dist
OutputBaseFilename=ArtemisOS15-Offline-Installer-{#AppVersion}
Compression={#PackageCompression}
SolidCompression=yes
MergeDuplicateFiles=yes
WizardStyle=modern
CloseApplications=no
RestartApplications=no

[Languages]
Name: "chinesesimp"; MessagesFile: "ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "其他选项："

[Files]
Source: "tools\ArtemisInstallDiscovery.psm1"; Flags: dontcopy
Source: "tools\Find-ArtemisInstallations.ps1"; Flags: dontcopy
Source: "tools\Upgrade-Transaction.ps1"; Flags: dontcopy
#ifdef SparseImageSha256
; Keep the helper at the start of the solid stream and extract it before the
; SDK. Extracting a later temporary file during AfterInstall would force Setup
; to replay the intervening compressed stream to resume the remaining files.
Source: "tools\Optimize-SparseFreshInstall.ps1"; Flags: dontcopy
#endif
; An optional lab-generated include can reuse verified identical runtime files.
; Its hashes and exact exclusions apply only to the selected immutable SDK.
; Without that explicit build option, preserve the normal SDK installation.
#ifdef RuntimeReuseInclude
#include RuntimeReuseInclude
#else
; Existing SDK/instance directories are rejected before installation below.
Source: "{#SdkSource}\*"; DestDir: "{code:InstallPayloadRoot}\sdk"; Flags: onlyifdoesntexist recursesubdirs createallsubdirs
#endif
Source: "stage\carrier-operators.xml"; DestDir: "{code:InstallPayloadRoot}\sdk\system-images\android-35\google_apis\x86_64\data\misc\modem_simulator\etc\modem_simulator\files"; DestName: "numeric_operator.xml"; Flags: ignoreversion
Source: "stage\launch.ps1"; DestDir: "{code:InstallPayloadRoot}"; Flags: ignoreversion
Source: "stage\settings.ps1"; DestDir: "{code:InstallPayloadRoot}"; Flags: ignoreversion
#ifdef SparseImageSha256
Source: "{#VersionSource}"; DestDir: "{code:InstallPayloadRoot}"; DestName: "version.ini"; Flags: ignoreversion; AfterInstall: OptimizeInstalledImage
#else
Source: "{#VersionSource}"; DestDir: "{code:InstallPayloadRoot}"; DestName: "version.ini"; Flags: ignoreversion
#endif
Source: "stage\initialize.ps1"; DestDir: "{code:InstallPayloadRoot}"; Flags: ignoreversion
Source: "stage\configure.ps1"; DestDir: "{code:InstallPayloadRoot}"; Flags: ignoreversion
Source: "stage\configure.vbs"; DestDir: "{code:InstallPayloadRoot}"; Flags: ignoreversion
Source: "stage\ArtemisOS15.ico"; DestDir: "{code:InstallPayloadRoot}"; Flags: ignoreversion
Source: "stage\start-auto.vbs"; DestDir: "{code:InstallPayloadRoot}"; Flags: ignoreversion
Source: "stage\start-software.vbs"; DestDir: "{code:InstallPayloadRoot}"; Flags: ignoreversion
Source: "stage\update\*"; DestDir: "{code:InstallPayloadRoot}\update"; Excludes: "test-marker.txt"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "stage\使用说明.txt"; DestDir: "{code:InstallPayloadRoot}"; Flags: ignoreversion
Source: "stage\licenses\*.txt"; DestDir: "{code:InstallPayloadRoot}\licenses"; Flags: ignoreversion

[Icons]
Name: "{group}\{#ReleaseShortcutName}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\start-auto.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\ArtemisOS15.ico"; Check: ShouldCreateIcons
Name: "{group}\{#ReleaseShortcutName}（软件渲染）"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\start-software.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\ArtemisOS15.ico"; Check: ShouldCreateIcons
Name: "{group}\{#ReleaseShortcutName}（配置）"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\configure.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\ArtemisOS15.ico"; Check: ShouldCreateIcons
Name: "{group}\使用说明"; Filename: "{app}\使用说明.txt"; Check: ShouldCreateIcons
Name: "{userdesktop}\{#ReleaseShortcutName}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\start-auto.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\ArtemisOS15.ico"; Tasks: desktopicon; Check: ShouldCreateIcons
Name: "{userdesktop}\{#ReleaseShortcutName}（软件渲染）"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\start-software.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\ArtemisOS15.ico"; Tasks: desktopicon; Check: ShouldCreateIcons
Name: "{userdesktop}\{#ReleaseShortcutName}（配置）"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\configure.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\ArtemisOS15.ico"; Tasks: desktopicon; Check: ShouldCreateIcons

[Run]
Filename: "{sys}\wscript.exe"; Parameters: """{app}\start-auto.vbs"""; Description: "启动 ArtemisOS 15"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent; Check: ShouldCreateIcons

[Code]
var
  ProfilePage: TInputOptionWizardPage;
  LastProfileDir: String;
#ifdef SparseImageSha256
  FreshInstallToken: String;
  OptimizeFreshImage: Boolean;
#endif

#include "tools\InnoUpgradePrototype.iss"
#include "tools\InstallerOtaConfig.iss"

function SameAppIdInstalled: Boolean;
var
  Key: String;
begin
  { AppId is a constant and may contain an escaped leading brace. Check both
    registry views as well as machine-wide registrations, but never other IDs. }
  Key := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\' +
    ExpandConstant('{#ReleaseAppId}') + '_is1';
  Result := RegKeyExists(HKCU32, Key) or RegKeyExists(HKCU64, Key) or
    RegKeyExists(HKLM32, Key) or RegKeyExists(HKLM64, Key);
end;

function SameAppIdMessage: String;
begin
  Result := '检测到相同的 ArtemisOS 已安装。请先在 Windows“已安装的应用”中卸载现有安装，再运行此安装程序。';
end;

function InitializeSetup: Boolean;
begin
  { Discovery and all existing-install checks run after the directory choice. }
  Result := True;
end;

procedure InitializeWizard;
begin
  InitializePrototypeChoices;
  ProfilePage := CreateInputOptionPage(wpSelectDir, '选择模拟器配置',
    '请根据电脑性能选择配置',
    '安装完成后，可以通过桌面的“{#ReleaseShortcutName}（配置）”随时调整；修改后重新启动模拟器生效。', True, False);
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
  if CurPageID = wpSelectDir then ApplyChoice;
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

#ifdef SparseImageSha256
procedure StopForImageIntegrity;
begin
  Log('系统镜像完整性未能确认；保留未完成安装标记并终止安装。');
  SuppressibleMsgBox('无法确认系统镜像的完整性。请保留当前目录用于检查，并选择新的空目录重新安装。', mbCriticalError, MB_OK, IDOK);
  { Inno ignores exceptions raised by AfterInstall; force a nonzero result and
    keep the pre-existing marker so this directory cannot silently be retried. }
  ExitProcess(4);
end;

procedure OptimizeInstalledImage;
var
  ImagePath, MarkerPath, Parameters: String;
  ExitCode: Integer;
  Executed: Boolean;
begin
  if OptimizeFreshImage then
  begin
    ImagePath := ExpandConstant('{app}\sdk\system-images\android-35\google_apis\x86_64\system.img');
    MarkerPath := ExpandConstant('{app}\.artemis-fresh-install');
    try
      WizardForm.StatusLabel.Caption := '正在优化镜像磁盘占用，可能需要几分钟，请稍候…';
      if not FileExists(ExpandConstant('{tmp}\Optimize-SparseFreshInstall.ps1')) then
        StopForImageIntegrity;
      Parameters := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
        ExpandConstant('{tmp}\Optimize-SparseFreshInstall.ps1') + '" -InstallRoot "' +
        ExpandConstant('{app}') + '" -ExpectedSha256 "{#SparseImageSha256}" -FreshInstallToken "' + FreshInstallToken + '"';
      Executed := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Parameters,
        '', SW_HIDE, ewWaitUntilTerminated, ExitCode);
      if not Executed or (ExitCode <> 0) then
      begin
        if CompareText(GetSHA256OfFile(ImagePath), '{#SparseImageSha256}') <> 0 then
        begin
          StopForImageIntegrity;
        end;
        Log('未能优化镜像的磁盘占用；镜像哈希已确认，继续安装。');
      end;
    except
      StopForImageIntegrity;
    end;
    if FileExists(MarkerPath) and not DeleteFile(MarkerPath) then
      Log('无法移除本次新安装标记。');
  end;
end;
#endif

procedure CurStepChanged(CurStep: TSetupStep);
var
  Profile, Cleanup, VideoCompat, Carrier, Graphics, Resolution, Preferences: String;
  Lines: TArrayOfString;
  I: Integer;
begin
#ifdef SparseImageSha256
  if (CurStep = ssInstall) and OptimizeFreshImage then
    try
      ExtractTemporaryFile('Optimize-SparseFreshInstall.ps1');
    except
      StopForImageIntegrity;
    end;
#endif
  if CurStep <> ssPostInstall then Exit;
  if UpgradeMode then begin
    ApplyPrototypeTransaction;
    RepairInstalledOtaConfig(ExpandConstant('{app}'));
    Exit;
  end;
  RepairInstalledOtaConfig(ExpandConstant('{app}'));
  Profile := 'low';
  if ProfilePage.Values[1] then Profile := 'medium';
  if ProfilePage.Values[2] then Profile := 'high';
  Cleanup := '1';
  VideoCompat := '1';
  Carrier := 'mobile';
  Graphics := 'host';
  Resolution := '720p';
  Preferences := ExpandConstant('{app}\data\preferences.ini');
  if LoadStringsFromFile(Preferences, Lines) then
    for I := 0 to GetArrayLength(Lines) - 1 do
    begin
      if Lines[I] = 'cleanup=0' then Cleanup := '0';
      if Lines[I] = 'video_compat=0' then VideoCompat := '0';
      if Lines[I] = 'carrier=telecom' then Carrier := 'telecom';
      if Lines[I] = 'carrier=unicom' then Carrier := 'unicom';
      if Lines[I] = 'graphics=auto' then Graphics := 'auto';
      if Lines[I] = 'graphics=host' then Graphics := 'host';
      if Lines[I] = 'graphics=software' then Graphics := 'software';
      if Lines[I] = 'graphics=swiftshader' then Graphics := 'swiftshader';
      if Lines[I] = 'graphics=swangle' then Graphics := 'swangle';
      if Lines[I] = 'graphics=lavapipe' then Graphics := 'lavapipe';
      if Lines[I] = 'resolution=900p' then Resolution := '900p';
      if Lines[I] = 'resolution=1080p' then Resolution := '1080p';
      if WizardSilent and (Lines[I] = 'profile=medium') then Profile := 'medium';
      if WizardSilent and (Lines[I] = 'profile=high') then Profile := 'high';
    end;
  ForceDirectories(ExpandConstant('{app}\data'));
  if not SaveStringToFile(Preferences, 'profile=' + Profile + #13#10 + 'cleanup=' + Cleanup + #13#10 + 'video_compat=' + VideoCompat + #13#10 + 'carrier=' + Carrier + #13#10 + 'graphics=' + Graphics + #13#10 + 'resolution=' + Resolution + #13#10, False) then
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

function ContainsExistingAndroidInstall(const Path: String): Boolean;
var
  Root: String;
begin
  Root := AddBackslash(Path);
  { Never overlay another SDK or ArtemisOS instance: retaining old files
    would mix runtime versions and could leave the old system image in place. }
  Result := DirExists(Root + 'sdk') or
    DirExists(Root + 'data\avd') or
    FileExists(Root + 'data\preferences.ini') or
    (FileExists(Root + 'version.ini') and FileExists(Root + 'launch.ps1')) or
    FileExists(Root + 'emulator\emulator.exe') or
    FileExists(Root + 'emulator.exe') or
    DirExists(Root + 'avd') or
    FileExists(Root + 'userdata-qemu.img');
end;

function ExistingInstallMessage: String;
begin
  Result := '检测到该目录已有安卓模拟器组件或实例。为避免混用新旧文件或影响现有数据，请选择新的空目录安装。';
end;

function ClassifyPrototypeTarget(const Path: String): String;
begin
  Result := '';
  UpgradeMode := False;
  if not CompatibleInstallPath(Path) then begin
    Result := '安装路径不能包含中文或其他非英文字符。请选择英文路径后重试。'; Exit;
  end;
  if not DiscoverInstallations(Path) then begin
    Result := '无法安全检查已有安装。请保留原目录并重试。'; Exit;
  end;
  if (DiscoveryStatus = 'selected') or (DiscoveryStatus = 'unregistered') then begin
#ifdef ArtemisUpgradeFixture
    if (DiscoveryStatus = 'unregistered') and IsIsolatedFixture(Path) then begin
      UpgradeMode := True; Exit;
    end;
#endif
    Result := '已发现旧版。自动升级仍在测试，暂不修改现有安装和数据。'; Exit;
  end;
  if (DiscoveryStatus = 'current') or (DiscoveryStatus = 'newer') then begin
    Result := '目标目录已安装相同或更新的版本，不能执行此安装。'; Exit;
  end;
  if DiscoveryStatus <> 'invalid_target' then begin
    Result := '已有安装的登记不明确，无法安全继续。'; Exit;
  end;
  if ContainsExistingAndroidInstall(Path) then begin Result := ExistingInstallMessage; Exit; end;
  if SameAppIdInstalled then begin Result := SameAppIdMessage; Exit; end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var MessageText: String;
begin
  Result := True;
  if CurPageID <> wpSelectDir then Exit;
  if WizardSilent and (GetArrayLength(DiscoveryPaths) > 1) and not HasExplicitInstallDir then
    MessageText := '发现多个安装，静默安装必须显式指定 /DIR。'
  else MessageText := ClassifyPrototypeTarget(WizardDirValue);
  if MessageText <> '' then begin
    Log('安装被阻止：' + MessageText);
    if not WizardSilent then MsgBox(MessageText, mbError, MB_OK);
    Result := False;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  { Recheck immediately before any payload extraction. }
  Result := ClassifyPrototypeTarget(ExpandConstant('{app}'));
  if (Result <> '') or UpgradeMode then Exit;
#ifdef SparseImageSha256
  OptimizeFreshImage := False;
  if (Result = '') and FileExists(ExpandConstant('{app}\.artemis-fresh-install')) then
    Result := '此目录存在未完成的安装。请保留该目录用于检查，并选择新的空目录重新安装。';
  if (Result = '') and not DirExists(ExpandConstant('{app}')) and not FileExists(ExpandConstant('{app}')) then
  begin
    if ForceDirectories(ExpandConstant('{app}')) then
    begin
      FreshInstallToken := Copy(GetSHA256OfString(ExpandConstant('{app}') +
        GetDateTimeString('yyyymmddhhnnsszzz', '-', ':')), 1, 32);
      OptimizeFreshImage := SaveStringToFile(ExpandConstant('{app}\.artemis-fresh-install'), FreshInstallToken, False);
    end;
  end;
#endif
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := PageID = wpSelectTasks;
end;
