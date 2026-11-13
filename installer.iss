#define AppName "ArtemisOS 15"
#ifdef OpenListServerFile
  #error OpenListServerFile is retired. Use the checked-in stage/update/server.txt default.
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
  #define ReleaseAppId "ArtemisOS15-Release"
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
AppId={code:SelectedInstallIdentity}
; Serialize installers for the same identity, including before registration.
SetupMutex=ArtemisOS.Setup.{#ReleaseAppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=ArtemisOS
DefaultDirName={code:SelectedInstallDirectory}
UninstallLogMode=append
DefaultGroupName={#ReleaseShortcutName}
UsePreviousGroup=no
UsePreviousLanguage=no
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
#ifdef InstallerRevision
OutputBaseFilename=ArtemisOS15-Offline-Installer-{#AppVersion}-{#InstallerRevision}
#else
OutputBaseFilename=ArtemisOS15-Offline-Installer-{#AppVersion}
#endif
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
#ifdef PayloadManifest
Source: "{#PayloadManifest}"; Flags: dontcopy
#endif
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
; Native upgrades replace changed files and reuse SHA-256-identical SDK files.
Source: "{#SdkSource}\*"; DestDir: "{app}\sdk"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: NeedsManagedFile
#endif
Source: "stage\carrier-operators.xml"; DestDir: "{app}\sdk\system-images\android-35\google_apis\x86_64\data\misc\modem_simulator\etc\modem_simulator\files"; DestName: "numeric_operator.xml"; Flags: ignoreversion; Check: NeedsManagedFile
Source: "stage\launch.ps1"; DestDir: "{app}"; Flags: ignoreversion; Check: NeedsManagedFile
Source: "stage\settings.ps1"; DestDir: "{app}"; Flags: ignoreversion; Check: NeedsManagedFile
Source: "stage\initialize.ps1"; DestDir: "{app}"; Flags: ignoreversion; Check: NeedsManagedFile
Source: "stage\configure.ps1"; DestDir: "{app}"; Flags: ignoreversion; Check: NeedsManagedFile
Source: "stage\configure.vbs"; DestDir: "{app}"; Flags: ignoreversion; Check: NeedsManagedFile
Source: "stage\ArtemisOS15.ico"; DestDir: "{app}"; Flags: ignoreversion; Check: NeedsManagedFile
Source: "stage\start-auto.vbs"; DestDir: "{app}"; Flags: ignoreversion; Check: NeedsManagedFile
Source: "stage\start-software.vbs"; DestDir: "{app}"; Flags: ignoreversion; Check: NeedsManagedFile
Source: "stage\update\*"; DestDir: "{app}\update"; Excludes: "test-marker.txt,server.txt"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: NeedsManagedFile
Source: "stage\update\server.txt"; DestDir: "{app}\update"; Flags: onlyifdoesntexist; Check: NeedsDefaultServer
Source: "stage\使用说明.txt"; DestDir: "{app}"; Flags: ignoreversion; Check: NeedsManagedFile
Source: "stage\licenses\*.txt"; DestDir: "{app}\licenses"; Flags: ignoreversion; Check: NeedsManagedFile
; Commit the product version after all program files, never before the SDK.
#ifdef SparseImageSha256
Source: "{#VersionSource}"; DestDir: "{app}"; DestName: "version.ini"; Flags: ignoreversion; Check: NeedsManagedFile; AfterInstall: OptimizeInstalledImage
#else
Source: "{#VersionSource}"; DestDir: "{app}"; DestName: "version.ini"; Flags: ignoreversion; Check: NeedsManagedFile
#endif

[Icons]
Name: "{group}\{#ReleaseShortcutName}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\start-auto.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\ArtemisOS15.ico"
Name: "{group}\{#ReleaseShortcutName}（软件渲染）"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\start-software.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\ArtemisOS15.ico"
Name: "{group}\{#ReleaseShortcutName}（配置）"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\configure.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\ArtemisOS15.ico"
Name: "{group}\使用说明"; Filename: "{app}\使用说明.txt"
Name: "{userdesktop}\{#ReleaseShortcutName}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\start-auto.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\ArtemisOS15.ico"; Tasks: desktopicon
Name: "{userdesktop}\{#ReleaseShortcutName}（软件渲染）"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\start-software.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\ArtemisOS15.ico"; Tasks: desktopicon
Name: "{userdesktop}\{#ReleaseShortcutName}（配置）"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\configure.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\ArtemisOS15.ico"; Tasks: desktopicon

[Run]
Filename: "{sys}\wscript.exe"; Parameters: """{app}\start-auto.vbs"""; Description: "启动 ArtemisOS 15"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent; Check: CanLaunchAfterInstall

[Code]
var
  ProfilePage: TInputOptionWizardPage;
  LastProfileDir: String;
#ifdef SparseImageSha256
  FreshInstallToken: String;
  OptimizeFreshImage: Boolean;
#endif

#include "tools\InstallerOtaConfig.iss"
#include "tools\InstallerUpgrade.iss"

function InitializeSetup: Boolean;
begin
  Result := True;
  try InitializeNativeUpgrade;
  except
    Result := False;
    UpgradeError := GetExceptionMessage;
    Log('安装被阻止：' + UpgradeError);
    if not WizardSilent then SuppressibleMsgBox(UpgradeError, mbError, MB_OK, IDOK);
    ReleaseUpgradeLocks;
  end;
end;

procedure InitializeWizard;
begin
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
procedure ExitProcess(ExitCode: Cardinal);
  external 'ExitProcess@kernel32.dll stdcall';

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
  if (CurStep = ssInstall) and (UpgradeRoot <> '') then SaveUpgradeBackup;
#ifdef SparseImageSha256
  if (CurStep = ssInstall) and OptimizeFreshImage then
    try
      ExtractTemporaryFile('Optimize-SparseFreshInstall.ps1');
    except
      StopForImageIntegrity;
    end;
#endif
  if CurStep <> ssPostInstall then Exit;
  if UpgradeRoot <> '' then begin
    try
      RepairInstalledOtaConfig(ExpandConstant('{app}'));
      CommitNativeUpgrade;
    except
      UpgradeFailed := True;
      Log('升级未提交，将恢复原安装：' + GetExceptionMessage);
    end;
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
      if Lines[I] = 'graphics=vulkan' then Graphics := 'vulkan';
      if Lines[I] = 'graphics=vulkan_intel' then Graphics := 'vulkan_intel';
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

function FreshPathAttributes(const Path: String): LongWord;
  external 'GetFileAttributesW@kernel32.dll stdcall';

function FreshPathLastError: LongWord;
  external 'GetLastError@kernel32.dll stdcall';

function SafeFreshInstallPath(const Path: String): Boolean;
var
  Current, Parent: String;
  Attributes, ErrorCode: LongWord;
  Entry: TFindRec;
begin
  Result := False;
  Current := RemoveBackslashUnlessRoot(ExpandFileName(Path));
  if Current = '' then Exit;
  { Check every existing ancestor as well as the destination itself. A
    junction or symlink would make the selected path refer elsewhere. }
  while Current <> '' do
  begin
    Attributes := FreshPathAttributes(Current);
    if Attributes = $FFFFFFFF then
    begin
      ErrorCode := FreshPathLastError;
      if (ErrorCode <> 2) and (ErrorCode <> 3) then Exit;
    end
    else if ((Attributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0) or
      ((Attributes and FILE_ATTRIBUTE_DIRECTORY) = 0) then Exit;
    Parent := RemoveBackslashUnlessRoot(ExtractFileDir(Current));
    if (Parent = '') or (CompareText(Parent, Current) = 0) then Break;
    Current := Parent;
  end;
  if DirExists(Path) then
  begin
    { FindFirst also sees hidden and system entries. Refuse an unreadable
      directory instead of assuming it is empty. }
    if not FindFirst(AddBackslash(Path) + '*', Entry) then Exit;
    try
      repeat
        if (Entry.Name <> '.') and (Entry.Name <> '..') then Exit;
      until not FindNext(Entry);
    finally
      FindClose(Entry);
    end;
  end
  else if FileExists(Path) then Exit;
  Result := True;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  { Silent setup also visits this callback; let PrepareToInstall return a
    failure instead of displaying an interactive error or trapping setup. }
  if WizardSilent then Exit;
  if (CurPageID = wpSelectDir) and not CompatibleInstallPath(WizardDirValue) then
  begin
    MsgBox('安装路径不能包含中文或其他非英文字符。请选择只包含英文字母、数字和空格的路径。', mbError, MB_OK);
    Result := False;
  end
  else if (UpgradeRoot = '') and (CurPageID = wpSelectDir) and ContainsExistingAndroidInstall(WizardDirValue) then
  begin
    MsgBox(ExistingInstallMessage, mbError, MB_OK);
    Result := False;
  end
  else if (UpgradeRoot = '') and (CurPageID = wpSelectDir) and not SafeFreshInstallPath(WizardDirValue) then
  begin
    MsgBox('请选择可访问的空目录，且路径中不能包含符号链接或目录联接。', mbError, MB_OK);
    Result := False;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if UpgradeRoot <> '' then begin
    try PrepareNativeUpgrade;
    except Result := GetExceptionMessage; Log('升级被阻止：' + Result); end;
    Exit;
  end;
  { A registration created since InitializeSetup must not become a fresh install. }
  if RegKeyExists(HKCU64, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\' +
    SelectedInstallIdentity('') + '_is1') then begin
    Result := '安装状态已改变，请关闭并重新运行安装包以识别原目录。'; Exit;
  end;
  if not CompatibleInstallPath(ExpandConstant('{app}')) then
    Result := '安装路径不能包含中文或其他非英文字符。请选择英文路径后重试。';
  if (Result = '') and ContainsExistingAndroidInstall(ExpandConstant('{app}')) then
  begin
    Result := ExistingInstallMessage;
    Log('安装被阻止：' + Result);
  end;
  if (Result = '') and not SafeFreshInstallPath(ExpandConstant('{app}')) then
  begin
    Result := '安装目录必须为空且可访问，路径不能包含符号链接或目录联接。';
    Log('安装被阻止：' + Result);
  end;
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
  Result := (PageID = wpSelectTasks) or ((UpgradeRoot <> '') and
    ((PageID = wpSelectDir) or (PageID = ProfilePage.ID)));
end;
