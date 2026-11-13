#ifdef UpgradeTestFixture
  #if Pos("ArtemisNativeUpgrade-", ReleaseAppId) != 1
    #error Upgrade fault injection is restricted to unique test identities.
  #endif
#endif
#ifdef UpgradeLegacyTestId
  #ifndef UpgradeTestFixture
    #error Alternate test identities are restricted to fixture builds.
  #endif
#endif
{ Native same-identity upgrades. No discovery scripts, data reset or SDK mixing.
  Native Inno owns uninstall-log append; our journal retains overwritten bytes
  because native rollback alone does not restore an old installation. }
var
  UpgradeRoot, UpgradeIdentity, UpgradeKey, UpgradeError, UpgradeBackup, OriginalUninstallLog: String;
  UpgradeStarted, UpgradeCommitted, UpgradeFailed, PayloadPrepared: Boolean;
  PayloadHashes, UpgradeChanges: TStringList;
  LaunchLock, FrontendLock, OtaLock: THandle;

function UpgradeAttributes(const Path: String): LongWord;
  external 'GetFileAttributesW@kernel32.dll stdcall';
function UpgradeLastError: LongWord;
  external 'GetLastError@kernel32.dll stdcall';
function UpgradeCreateMutex(Security: Integer; Owner: Boolean; Name: String): THandle;
  external 'CreateMutexW@kernel32.dll stdcall';
function UpgradeWait(Handle: THandle; Timeout: LongWord): LongWord;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function UpgradeRelease(Handle: THandle): Boolean;
  external 'ReleaseMutex@kernel32.dll stdcall';
function UpgradeClose(Handle: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';
#ifdef UpgradeTestFixture
procedure UpgradeTestExitProcess(Code: LongWord);
  external 'ExitProcess@kernel32.dll stdcall';
#endif

function NormalInstallPath(const Path: String): String;
begin
  Result := RemoveBackslashUnlessRoot(ExpandFileName(Path));
end;

function UpgradePathSafe(const Path: String): Boolean;
var P, Parent: String; A, E: LongWord;
begin
  Result := False;
  P := NormalInstallPath(Path);
  while P <> '' do begin
    A := UpgradeAttributes(P);
    if A = $FFFFFFFF then begin
      E := UpgradeLastError;
      if (E <> 2) and (E <> 3) then Exit;
    end else if (A and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then Exit;
    Parent := NormalInstallPath(ExtractFileDir(P));
    if (Parent = '') or (CompareText(P, Parent) = 0) then Break;
    P := Parent;
  end;
  Result := True;
end;

function UpgradeRelativeSafe(const Relative: String): Boolean;
begin
  Result := (Relative <> '') and (Pos(':', Relative) = 0) and
    (Copy(Relative, 1, 1) <> '\') and (Pos('/', Relative) = 0) and
    (Pos('..', Relative) = 0) and
    ((Pos('data\', Lowercase(Relative)) <> 1) or
      (CompareText(Relative, 'data\update\server.txt') = 0));
end;

procedure UpgradeRequire(Condition: Boolean; const Message: String);
begin
  if not Condition then RaiseException(Message);
end;

function RegistryEncode(const Value: String): String;
var I, Number: Integer; Digits: String; Bytes: AnsiString;
begin
  Result := '';
  Digits := '0123456789ABCDEF';
  Bytes := Utf8Encode(Value);
  for I := 1 to Length(Bytes) do begin
    Number := Ord(Bytes[I]);
    Result := Result + Digits[(Number div 16) mod 16 + 1] + Digits[Number mod 16 + 1];
  end;
end;

function RegistryDecode(const Value: String): String;
var I, Number: Integer; Bytes: AnsiString;
begin
  UpgradeRequire((Length(Value) mod 2) = 0, '卸载注册信息备份编码无效。');
  Bytes := '';
  I := 1;
  while I <= Length(Value) do begin
    Number := StrToIntDef('$' + Copy(Value, I, 2), -1);
    UpgradeRequire((Number >= 0) and (Number <= 255), '卸载注册信息备份编码无效。');
    Bytes := Bytes + Chr(Number);
    I := I + 2;
  end;
  Result := Utf8Decode(Bytes);
end;

procedure ReleaseUpgradeLocks;
begin
  if OtaLock <> 0 then begin UpgradeRelease(OtaLock); UpgradeClose(OtaLock); OtaLock := 0; end;
  if FrontendLock <> 0 then begin UpgradeRelease(FrontendLock); UpgradeClose(FrontendLock); FrontendLock := 0; end;
  if LaunchLock <> 0 then begin UpgradeRelease(LaunchLock); UpgradeClose(LaunchLock); LaunchLock := 0; end;
end;

function AcquireUpgradeLock(const Name: String; var Handle: THandle): Boolean;
var Status: LongWord;
begin
  Result := False;
  Handle := UpgradeCreateMutex(0, False, Name);
  if Handle = 0 then Exit;
  Status := UpgradeWait(Handle, 0);
  Result := (Status = 0) or (Status = $80);
  if not Result then begin UpgradeClose(Handle); Handle := 0; end;
end;

procedure LockUpgrade;
var Hash: String;
begin
  if LaunchLock <> 0 then Exit;
  Hash := Uppercase(GetSHA256OfString(Uppercase(UpgradeRoot)));
  UpgradeRequire(AcquireUpgradeLock('Global\ArtemisOS-Launch-' + Hash, LaunchLock),
    'ArtemisOS 正在启动，请关闭后重试。');
  UpgradeRequire(AcquireUpgradeLock('Local\ArtemisOS-Frontend-' + Lowercase(Hash), FrontendLock),
    '请先关闭 ArtemisOS 模拟器窗口，再运行安装程序；应用和数据会保留。');
  Hash := Uppercase(GetSHA256OfString(Lowercase(UpgradeRoot)));
  UpgradeRequire(AcquireUpgradeLock('Local\ArtemisOS-Update-' + Copy(Hash, 1, 24), OtaLock),
    'ArtemisOS 正在更新，请等待更新完成后重试。');
end;

procedure RequireStoppedUpgrade;
var Locator, Service, Processes, Item: Variant; I: Integer; Path: String;
begin
  { Mutexes close the normal launch/OTA races. Inspect detached native backends
    too. Never kill another installation's processes or a shared ADB server. }
  Locator := CreateOleObject('WbemScripting.SWbemLocator');
  Service := Locator.ConnectServer('', 'root\CIMV2');
  Processes := Service.ExecQuery('SELECT ExecutablePath FROM Win32_Process WHERE ' +
    'Name="ArtemisFrontend.exe" OR Name="emulator.exe" OR ' +
    'Name="qemu-system-x86_64.exe" OR Name="qemu-system-i386.exe" OR ' +
    'Name="qemu-system-x86_64-headless.exe" OR Name="qemu-system-i386-headless.exe" OR Name="scrcpy.exe"');
  for I := 0 to Processes.Count - 1 do begin
    Item := Processes.ItemIndex(I);
    UpgradeRequire(not VarIsNull(Item.ExecutablePath), '无法确认模拟器进程路径，请关闭模拟器后重试。');
    Path := String(Item.ExecutablePath);
    UpgradeRequire(Path <> '', '无法确认模拟器进程路径，请关闭模拟器后重试。');
    UpgradeRequire(Pos(Lowercase(AddBackslash(UpgradeRoot)), Lowercase(Path)) <> 1,
      '请先关闭此目录的模拟器及显示窗口，再运行安装程序；无需卸载或清除数据。');
  end;
end;

procedure DiscoverUpgradeIdentity(const Identity: String);
var Key, Path: String;
begin
  Key := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\' + Identity + '_is1';
  UpgradeRequire(not RegKeyExists(HKLM32, Key) and not RegKeyExists(HKLM64, Key),
    '检测到机器级安装，当前每用户安装程序不能覆盖它。请保留原数据并联系管理员。');
  if not RegKeyExists(HKCU64, Key) then begin
    UpgradeRequire(not RegKeyExists(HKCU32, Key), '检测到不同位数的安装记录，请保留原数据并联系维护人员。');
    Exit;
  end;
  UpgradeRequire(RegQueryStringValue(HKCU64, Key, 'InstallLocation', Path) and (Path <> ''),
    '原安装记录缺少目录，请保留原数据并联系维护人员。');
  { Older identity changes could leave an uninstall record after its directory
    was removed. It must not hide another valid installation. Do not delete
    that registration or infer anything about an inaccessible existing path. }
  if UpgradeAttributes(NormalInstallPath(Path)) = $FFFFFFFF then
    if (UpgradeLastError = 2) or (UpgradeLastError = 3) then begin
      Log('忽略目录已不存在的历史安装记录：' + Identity); Exit;
    end;
  UpgradeRequire(UpgradeIdentity = '', '检测到多个有效 ArtemisOS 安装身份，请保留原安装并联系维护人员。');
  UpgradeIdentity := Identity;
  UpgradeKey := Key;
  UpgradeRoot := NormalInstallPath(Path);
end;

function SelectedInstallIdentity(Param: String): String;
begin
  if UpgradeIdentity <> '' then Result := UpgradeIdentity
  else Result := ExpandConstant('{#ReleaseAppId}');
end;

function SelectedInstallDirectory(Param: String): String;
begin
  if UpgradeRoot <> '' then Result := UpgradeRoot
  else Result := ExpandConstant('{localappdata}\{#ReleaseDefaultDirName}');
end;

function RecoveryRegistryKey(const Identity: String): String;
begin
  Result := 'Software\ArtemisOS\InstallerRecovery\' + Identity;
end;

procedure ClearRecoveryLocator(const Root, Identity: String);
var Marker: String;
begin
  Marker := AddBackslash(Root) + '.artemis-install-pending.ini';
  if FileExists(Marker) then UpgradeRequire(DeleteFile(Marker), '无法清除安装恢复标记。');
  if RegKeyExists(HKCU64, RecoveryRegistryKey(Identity)) then
    UpgradeRequire(RegDeleteKeyIncludingSubkeys(HKCU64, RecoveryRegistryKey(Identity)), '无法清除安装恢复定位记录。');
end;

procedure RestoreUpgrade(const Root, Backup, Identity: String);
var Journal, Section, Relative, Target, Source, Hash, Key, Name, Value: String;
  I, Count, Kind: Integer; Number: LongWord; Names: TArrayOfString;
  OriginalNames, OriginalFiles: TStringList; Entry: TFindRec;
begin
  Journal := AddBackslash(Backup) + 'journal.ini';
  UpgradeRequire(UpgradePathSafe(Backup) and UpgradePathSafe(Journal) and FileExists(Journal), '找不到安全的升级恢复记录。请保留原目录。');
  UpgradeRequire((CompareText(GetIniString('Transaction', 'Root', '', Journal), Root) = 0) and
    (GetIniString('Transaction', 'Identity', '', Journal) = Identity), '升级恢复记录与原安装不匹配。');
  Count := GetIniInt('Files', 'Count', -1, -1, 10000, Journal);
  UpgradeRequire(Count >= 0, '升级恢复记录不完整。');
  { Validate every backup before restoring even one destination. }
  for I := 0 to Count - 1 do begin
    Section := 'File' + IntToStr(I);
    Relative := RegistryDecode(GetIniString(Section, 'Relative', '', Journal));
    UpgradeRequire(UpgradeRelativeSafe(Relative), '升级恢复文件路径无效。');
    Target := AddBackslash(Root) + Relative;
    Source := AddBackslash(Backup) + 'files\' + Relative;
    UpgradeRequire(UpgradePathSafe(Target) and UpgradePathSafe(Source), '升级恢复路径包含链接或不可访问。');
    Hash := GetIniString(Section, 'Hash', '', Journal);
    if Hash <> '' then UpgradeRequire(FileExists(Source) and
      (CompareText(GetSHA256OfFile(Source), Hash) = 0), '升级备份校验失败，请保留现场。');
  end;
  for I := Count - 1 downto 0 do begin
    Section := 'File' + IntToStr(I);
    Relative := RegistryDecode(GetIniString(Section, 'Relative', '', Journal));
    Target := AddBackslash(Root) + Relative;
    Source := AddBackslash(Backup) + 'files\' + Relative;
    if GetIniString(Section, 'Hash', '', Journal) <> '' then begin
      UpgradeRequire(ForceDirectories(ExtractFileDir(Target)) and FileCopy(Source, Target, False),
        '无法恢复原程序文件，请关闭相关程序后重新运行安装包。');
    end else if FileExists(Target) then UpgradeRequire(DeleteFile(Target), '无法移除未完成的程序文件。');
  end;
  { Remove a newly-created uninstall pair if Inno could not append the old log.
    Existing uninstall metadata was explicitly captured in the journal. }
  OriginalFiles := TStringList.Create;
  try
    for I := 0 to Count - 1 do
      OriginalFiles.Add(Lowercase(RegistryDecode(GetIniString('File' + IntToStr(I), 'Relative', '', Journal))));
    if FindFirst(AddBackslash(Root) + 'unins*.*', Entry) then try
      repeat
        if (Entry.Attributes and FILE_ATTRIBUTE_DIRECTORY) = 0 then
          if (CompareText(ExtractFileExt(Entry.Name), '.exe') = 0) or
            (CompareText(ExtractFileExt(Entry.Name), '.dat') = 0) or
            (CompareText(ExtractFileExt(Entry.Name), '.msg') = 0) then
            if OriginalFiles.IndexOf(Lowercase(Entry.Name)) < 0 then
              UpgradeRequire(UpgradePathSafe(AddBackslash(Root) + Entry.Name) and
                DeleteFile(AddBackslash(Root) + Entry.Name), '无法恢复单一卸载入口。');
      until not FindNext(Entry);
    finally FindClose(Entry); end;
  finally OriginalFiles.Free; end;
  Key := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\' + Identity + '_is1';
  if RegKeyExists(HKCU64, Key) then
    UpgradeRequire(RegGetValueNames(HKCU64, Key, Names), '无法读取卸载记录以恢复。')
  else SetArrayLength(Names, 0);
  Count := GetIniInt('Registry', 'Count', -1, -1, 1000, Journal);
  UpgradeRequire(Count >= 0, '卸载记录备份不完整。');
  OriginalNames := TStringList.Create;
  try
    for I := 0 to Count - 1 do begin
      Section := 'Registry' + IntToStr(I);
      Name := RegistryDecode(GetIniString(Section, 'Name', '', Journal));
      OriginalNames.Add(Lowercase(Name));
      Kind := GetIniInt(Section, 'Kind', 0, 0, 2, Journal);
      Value := GetIniString(Section, 'Value', '', Journal);
      if Kind = 1 then UpgradeRequire(RegWriteStringValue(HKCU64, Key, Name, RegistryDecode(Value)), '无法恢复卸载记录。')
      else begin
        Number := StrToInt64(Value);
        UpgradeRequire((Kind = 2) and RegWriteDWordValue(HKCU64, Key, Name, Number), '无法恢复卸载记录。');
      end;
    end;
    { Never temporarily delete InstallLocation: a retry must still discover the
      registered root and its pending journal after interrupted recovery. }
    for I := 0 to GetArrayLength(Names) - 1 do
      if OriginalNames.IndexOf(Lowercase(Names[I])) < 0 then
        UpgradeRequire(RegDeleteValue(HKCU64, Key, Names[I]), '无法移除本次升级新增的卸载值。');
  finally OriginalNames.Free; end;
  UpgradeRequire(SetIniString('Transaction', 'State', 'restored', Journal), '无法保存已恢复的安装状态。');
  ClearRecoveryLocator(Root, Identity);
  Log('已恢复升级前的程序和卸载记录，Android 用户数据未参与恢复。');
end;

procedure RecoverKnownInstallation(const Identity: String);
var Root, Token, Key, Journal: String;
begin
  Key := RecoveryRegistryKey(Identity);
  if not RegKeyExists(HKCU64, Key) then Exit;
  { Root is published last, before payload mutation. An entry without Root is
    an interrupted locator creation, not an interrupted installation. }
  if not RegQueryStringValue(HKCU64, Key, 'Root', Root) or (Root = '') then begin
    UpgradeRequire(RegDeleteKeyIncludingSubkeys(HKCU64, Key), '无法清理未完成的恢复定位记录。'); Exit;
  end;
  UpgradeRequire(RegQueryStringValue(HKCU64, Key, 'Token', Token) and
    (ExtractFileName(Token) = Token) and (Length(Token) = 32), '安装恢复定位记录不完整。');
  UpgradeRoot := NormalInstallPath(Root);
  UpgradeRequire(UpgradePathSafe(UpgradeRoot) and DirExists(UpgradeRoot), '安装恢复目录不安全。');
  LockUpgrade;
  RequireStoppedUpgrade;
  Journal := AddBackslash(UpgradeRoot) + '.artemis-install-backups\' + Token + '\journal.ini';
  UpgradeRequire(UpgradePathSafe(Journal) and FileExists(Journal) and
    (CompareText(GetIniString('Transaction', 'Root', '', Journal), UpgradeRoot) = 0) and
    (GetIniString('Transaction', 'Identity', '', Journal) = Identity), '安装恢复定位与备份不匹配。');
  if GetIniString('Transaction', 'State', '', Journal) = 'committed' then
    ClearRecoveryLocator(UpgradeRoot, Identity)
  else RestoreUpgrade(UpgradeRoot, ExtractFileDir(Journal), Identity);
end;

procedure InitializeNativeUpgrade;
var Pending, Backup, Version, RegisteredVersion: String; Old, Target: Int64;
  Entry: TFindRec; UninstallCount: Integer;
begin
  RecoverKnownInstallation(ExpandConstant('{#ReleaseAppId}'));
#if ReleaseAppId == "ArtemisOS15-Release"
  RecoverKnownInstallation('{E49344F1-069E-4DA4-A5B7-232C0BE325A8}');
#endif
#ifdef UpgradeLegacyTestId
  RecoverKnownInstallation('{#UpgradeLegacyTestId}');
#endif
  DiscoverUpgradeIdentity(ExpandConstant('{#ReleaseAppId}'));
#if ReleaseAppId == "ArtemisOS15-Release"
  DiscoverUpgradeIdentity('{E49344F1-069E-4DA4-A5B7-232C0BE325A8}');
#endif
#ifdef UpgradeLegacyTestId
  DiscoverUpgradeIdentity('{#UpgradeLegacyTestId}');
#endif
  if UpgradeRoot = '' then Exit;
  UpgradeRequire(UpgradePathSafe(UpgradeRoot) and DirExists(UpgradeRoot), '原安装目录不安全或无法访问。');
  LockUpgrade;
  RequireStoppedUpgrade;
  Pending := AddBackslash(UpgradeRoot) + '.artemis-install-pending.ini';
  UpgradeRequire(UpgradePathSafe(Pending), '未完成安装的恢复标记路径不安全。');
  if FileExists(Pending) then begin
    Backup := GetIniString('Transaction', 'Backup', '', Pending);
    UpgradeRequire((ExtractFileName(Backup) = Backup) and (Length(Backup) = 32), '未完成安装的恢复标记无效。');
    RestoreUpgrade(UpgradeRoot, AddBackslash(UpgradeRoot) + '.artemis-install-backups\' + Backup, UpgradeIdentity);
  end;
  Version := GetIniString('ArtemisOS', 'Version', '', AddBackslash(UpgradeRoot) + 'version.ini');
  UpgradeRequire(RegQueryStringValue(HKCU64, UpgradeKey, 'DisplayVersion', RegisteredVersion) and
    (Version = RegisteredVersion) and StrToVersion(Version, Old) and StrToVersion('{#AppVersion}', Target),
    '原安装的版本记录不一致，请保留原数据并联系维护人员。');
  UpgradeRequire(ComparePackedVersion(Old, Target) <= 0, '安装包版本低于已安装版本，已阻止降级。');
  UpgradeRequire(FileExists(AddBackslash(UpgradeRoot) + 'launch.ps1') and
    FileExists(AddBackslash(UpgradeRoot) + 'settings.ps1') and
    FileExists(AddBackslash(UpgradeRoot) + 'sdk\emulator\emulator.exe'), '原安装不完整，请保留目录并联系维护人员。');
  UninstallCount := 0;
  if FindFirst(AddBackslash(UpgradeRoot) + 'unins*.dat', Entry) then try
    repeat
      if (Entry.Attributes and FILE_ATTRIBUTE_DIRECTORY) = 0 then begin
        UninstallCount := UninstallCount + 1;
        OriginalUninstallLog := Entry.Name;
        UpgradeRequire(UpgradePathSafe(AddBackslash(UpgradeRoot) + Entry.Name) and
          FileExists(ChangeFileExt(AddBackslash(UpgradeRoot) + Entry.Name, '.exe')), '原卸载程序不完整。');
      end;
    until not FindNext(Entry);
  finally FindClose(Entry); end;
  UpgradeRequire(UninstallCount = 1, '原安装的卸载日志不唯一或缺失，已停止覆盖以保护数据。');
  Log('保留原安装身份并原地升级：' + UpgradeIdentity + '；' + UpgradeRoot + '；' + Version + ' -> {#AppVersion}');
end;

function NeedsManagedFile: Boolean;
var Relative: String;
begin
  Result := True;
  if (UpgradeRoot = '') or (UpgradeChanges = nil) then Exit;
  Relative := Copy(ExpandConstant(CurrentFileName), Length(AddBackslash(UpgradeRoot)) + 1, MaxInt);
  Result := UpgradeChanges.IndexOf(Lowercase(Relative)) >= 0;
end;

function NeedsDefaultServer: Boolean;
begin
  Result := not FileExists(ExpandConstant('{app}\update\server.txt'));
end;

procedure AddUpgradeChange(const Relative: String);
begin
  if UpgradeChanges.IndexOf(Lowercase(Relative)) < 0 then UpgradeChanges.Add(Lowercase(Relative));
end;

function PayloadIndex(const Relative: String): Integer;
var I, Separator: Integer;
begin
  Result := -1;
  for I := 0 to PayloadHashes.Count - 1 do begin
    Separator := 1;
    while (Separator <= Length(PayloadHashes[I])) and (Copy(PayloadHashes[I], Separator, 1) <> '=') do
      Separator := Separator + 1;
    if CompareText(Copy(PayloadHashes[I], 1, Separator - 1), Relative) = 0 then begin
      Result := I; Exit;
    end;
  end;
end;

procedure PrepareNativeUpgrade;
var Lines: TArrayOfString; I, Separator: Integer; Relative, Hash, Target: String;
begin
  if UpgradeRoot = '' then Exit;
  UpgradeRequire(CompareText(NormalInstallPath(ExpandConstant('{app}')), UpgradeRoot) = 0,
    '覆盖升级必须使用原安装目录，不能通过 /DIR 改到其他位置。');
  RequireStoppedUpgrade;
  if PayloadPrepared then Exit;
  if PayloadHashes <> nil then PayloadHashes.Free;
  if UpgradeChanges <> nil then UpgradeChanges.Free;
  PayloadHashes := TStringList.Create;
  UpgradeChanges := TStringList.Create;
#ifdef PayloadManifest
  ExtractTemporaryFile(ExtractFileName('{#PayloadManifest}'));
  UpgradeRequire(LoadStringsFromFile(AddBackslash(ExpandConstant('{tmp}')) + ExtractFileName('{#PayloadManifest}'), Lines),
    '无法读取安装包的文件校验清单。');
  for I := 0 to GetArrayLength(Lines) - 1 do begin
    { Pos accepts AnsiString in the scripting API, while Copy indexes Unicode.
      Find the separator in Unicode characters so Chinese filenames survive. }
    Separator := 1;
    while (Separator <= Length(Lines[I])) and (Copy(Lines[I], Separator, 1) <> '=') do
      Separator := Separator + 1;
    if Separator <= Length(Lines[I]) then begin
      Relative := Lowercase(Copy(Lines[I], 1, Separator - 1));
      Hash := Copy(Lines[I], Separator + 1, MaxInt);
      UpgradeRequire(UpgradeRelativeSafe(Relative) and (Pos('data\', Relative) <> 1) and (Length(Hash) = 64),
        '安装包文件清单无效：' + Relative + '；hash length=' + IntToStr(Length(Hash)));
      UpgradeRequire(PayloadIndex(Relative) < 0, '安装包文件清单重复。');
      PayloadHashes.Add(Relative + '=' + Hash);
      Target := AddBackslash(UpgradeRoot) + Relative;
      UpgradeRequire(UpgradePathSafe(Target) and not DirExists(Target), '托管程序文件路径不安全。');
      if Relative <> 'update\server.txt' then begin
        if not FileExists(Target) then AddUpgradeChange(Relative)
        else if CompareText(GetSHA256OfFile(Target), Hash) <> 0 then AddUpgradeChange(Relative);
      end else if not FileExists(Target) then AddUpgradeChange(Relative);
    end;
  end;
  UpgradeRequire((PayloadHashes.Count > 0) and (PayloadIndex('version.ini') >= 0), '安装包文件清单缺少版本文件。');
#else
  RaiseException('本安装包没有覆盖升级校验清单，请使用最新完整安装包。');
#endif
  { The two official-address repairs are the only permitted data/config writes. }
  for I := 0 to 1 do begin
    if I = 0 then Relative := 'update\server.txt' else Relative := 'data\update\server.txt';
    Target := AddBackslash(UpgradeRoot) + Relative;
    UpgradeRequire(UpgradePathSafe(Target), 'OTA 配置路径不安全。');
    if FileExists(Target) then begin
      if IsRetiredOfficialOtaServer(Target) then AddUpgradeChange(Relative);
    end;
  end;
  PayloadPrepared := True;
end;

procedure SaveUpgradeBackup;
var I, Count: Integer; Relative, Target, CopyPath, Journal, Section, Value, Token: String;
  Names: TArrayOfString; Number: LongWord; Entry: TFindRec;
begin
  if UpgradeRoot = '' then Exit;
  RequireStoppedUpgrade;
  { Inno appends/replaces uninstall metadata even if all payload bytes match. }
  if FindFirst(AddBackslash(UpgradeRoot) + 'unins*.*', Entry) then try
    repeat
      if (Entry.Attributes and FILE_ATTRIBUTE_DIRECTORY) = 0 then
        if (CompareText(ExtractFileExt(Entry.Name), '.exe') = 0) or
          (CompareText(ExtractFileExt(Entry.Name), '.dat') = 0) or
          (CompareText(ExtractFileExt(Entry.Name), '.msg') = 0) then AddUpgradeChange(Entry.Name);
    until not FindNext(Entry);
  finally FindClose(Entry); end;
  Token := Copy(GetSHA256OfString(UpgradeRoot + GetDateTimeString('yyyymmddhhnnsszzz', '-', ':')), 1, 32);
  UpgradeBackup := AddBackslash(UpgradeRoot) + '.artemis-install-backups\' + Token;
  UpgradeRequire(UpgradePathSafe(UpgradeBackup) and not DirExists(UpgradeBackup) and ForceDirectories(UpgradeBackup), '无法建立升级备份目录。');
  Journal := AddBackslash(UpgradeBackup) + 'journal.ini';
  UpgradeRequire(SetIniString('Transaction', 'Root', UpgradeRoot, Journal) and
    SetIniString('Transaction', 'Identity', UpgradeIdentity, Journal), '无法保存升级恢复记录。');
  for I := 0 to UpgradeChanges.Count - 1 do begin
    Relative := UpgradeChanges[I];
    Target := AddBackslash(UpgradeRoot) + Relative;
    CopyPath := AddBackslash(UpgradeBackup) + 'files\' + Relative;
    UpgradeRequire(UpgradeRelativeSafe(Relative) and UpgradePathSafe(Target) and UpgradePathSafe(CopyPath), '升级备份路径不安全。');
    Section := 'File' + IntToStr(I);
    Value := '';
    if FileExists(Target) then begin
      Value := GetSHA256OfFile(Target);
      UpgradeRequire(ForceDirectories(ExtractFileDir(CopyPath)) and FileCopy(Target, CopyPath, True) and
        (CompareText(GetSHA256OfFile(CopyPath), Value) = 0), '无法校验原程序备份，请检查剩余磁盘空间。');
    end;
    UpgradeRequire(SetIniString(Section, 'Relative', RegistryEncode(Relative), Journal) and
      SetIniString(Section, 'Hash', Value, Journal), '无法保存升级文件记录。');
  end;
  UpgradeRequire(SetIniInt('Files', 'Count', UpgradeChanges.Count, Journal) and
    RegGetValueNames(HKCU64, UpgradeKey, Names), '无法备份卸载注册信息。');
  Count := GetArrayLength(Names);
  for I := 0 to Count - 1 do begin
    Section := 'Registry' + IntToStr(I);
    UpgradeRequire(SetIniString(Section, 'Name', RegistryEncode(Names[I]), Journal), '无法备份卸载注册信息。');
    if RegQueryStringValue(HKCU64, UpgradeKey, Names[I], Value) then
      UpgradeRequire(SetIniInt(Section, 'Kind', 1, Journal) and SetIniString(Section, 'Value', RegistryEncode(Value), Journal), '无法备份卸载注册信息。')
    else begin
      UpgradeRequire(RegQueryDWordValue(HKCU64, UpgradeKey, Names[I], Number), '卸载记录包含不支持的类型，已停止升级。');
      UpgradeRequire(SetIniInt(Section, 'Kind', 2, Journal) and SetIniString(Section, 'Value', IntToStr(Number), Journal), '无法备份卸载注册信息。');
    end;
  end;
  UpgradeRequire(SetIniInt('Registry', 'Count', Count, Journal) and SetIniString('Transaction', 'State', 'prepared', Journal), '无法完成升级备份记录。');
  UpgradeRequire(SetIniString('Transaction', 'Backup', Token, AddBackslash(UpgradeRoot) + '.artemis-install-pending.ini'), '无法保存升级恢复标记。');
  UpgradeRequire(RegWriteStringValue(HKCU64, RecoveryRegistryKey(UpgradeIdentity), 'Token', Token) and
    RegWriteStringValue(HKCU64, RecoveryRegistryKey(UpgradeIdentity), 'Root', UpgradeRoot), '无法保存独立的安装恢复定位记录。');
  UpgradeStarted := True;
end;

procedure CommitNativeUpgrade;
var I, Separator, UninstallCount: Integer; Relative, Target, Hash, RegisteredVersion, Location, UninstallCommand: String;
  Entry: TFindRec;
begin
  if UpgradeRoot = '' then Exit;
  try
    for I := 0 to PayloadHashes.Count - 1 do begin
      Separator := 1;
      while (Separator <= Length(PayloadHashes[I])) and (Copy(PayloadHashes[I], Separator, 1) <> '=') do
        Separator := Separator + 1;
      Relative := Copy(PayloadHashes[I], 1, Separator - 1);
      Hash := Copy(PayloadHashes[I], Separator + 1, MaxInt);
      if Relative <> 'update\server.txt' then begin
        Target := AddBackslash(UpgradeRoot) + Relative;
        UpgradeRequire(UpgradePathSafe(Target) and FileExists(Target) and
          (CompareText(GetSHA256OfFile(Target), Hash) = 0), '升级文件完整性检查失败：' + Relative);
      end;
    end;
    UpgradeRequire(RegQueryStringValue(HKCU64, UpgradeKey, 'DisplayVersion', RegisteredVersion) and
      (RegisteredVersion = '{#AppVersion}') and RegQueryStringValue(HKCU64, UpgradeKey, 'InstallLocation', Location) and
      (CompareText(NormalInstallPath(Location), UpgradeRoot) = 0), '升级后的卸载记录与原安装不一致。');
    UninstallCount := 0;
    if FindFirst(AddBackslash(UpgradeRoot) + 'unins*.dat', Entry) then try
      repeat
        if (Entry.Attributes and FILE_ATTRIBUTE_DIRECTORY) = 0 then begin
          UninstallCount := UninstallCount + 1;
          UpgradeRequire(CompareText(Entry.Name, OriginalUninstallLog) = 0, '安装器未能合并原卸载日志。');
        end;
      until not FindNext(Entry);
    finally FindClose(Entry); end;
    UpgradeRequire((UninstallCount = 1) and RegQueryStringValue(HKCU64, UpgradeKey, 'UninstallString', UninstallCommand) and
      (CompareText(RemoveQuotes(UninstallCommand), ChangeFileExt(AddBackslash(UpgradeRoot) + OriginalUninstallLog, '.exe')) = 0),
      '安装器未保留原卸载入口。');
#ifdef UpgradeTestFixture
    if ExpandConstant('{param:CRASHUPGRADE|0}') = '1' then UpgradeTestExitProcess(9);
    if ExpandConstant('{param:FAILUPGRADE|0}') = '1' then RaiseException('Injected pre-commit failure');
#endif
    UpgradeRequire(SetIniString('Transaction', 'State', 'committed', AddBackslash(UpgradeBackup) + 'journal.ini'), '无法提交升级恢复记录。');
    UpgradeCommitted := True;
    try ClearRecoveryLocator(UpgradeRoot, UpgradeIdentity);
    except Log('升级已完成，恢复定位记录将于下次安装清理：' + GetExceptionMessage); end;
    Log('原地升级完成，已校验托管文件，保留全部 Android 数据和偏好。');
    ReleaseUpgradeLocks;
  except
    UpgradeFailed := True;
    Log('原地升级校验失败，退出时恢复原安装：' + GetExceptionMessage);
    SuppressibleMsgBox('升级未完成，将恢复原程序；Android 数据会保留。请查看安装日志。', mbError, MB_OK, IDOK);
  end;
end;

function CanLaunchAfterInstall: Boolean;
begin
  Result := (UpgradeRoot = '') or UpgradeCommitted;
end;

function GetCustomSetupExitCode: Integer;
begin
  if UpgradeFailed then Result := 8 else Result := 0;
end;

procedure DeinitializeSetup;
begin
  try
    if UpgradeStarted and not UpgradeCommitted then
      RestoreUpgrade(UpgradeRoot, UpgradeBackup, UpgradeIdentity);
  except
    Log('自动恢复未完成，请保留原目录并重新运行安装包：' + GetExceptionMessage);
  end;
  ReleaseUpgradeLocks;
  if PayloadHashes <> nil then PayloadHashes.Free;
  if UpgradeChanges <> nil then UpgradeChanges.Free;
end;
