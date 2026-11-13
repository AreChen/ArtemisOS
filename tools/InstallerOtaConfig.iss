{ Product connection configuration only. Do not change preferences or AVD data.
  Call after payload installation, and only after a successful upgrade transaction. }
function IsRetiredOfficialOtaServer(const Path: String): Boolean;
var
  Contents: AnsiString;
  Value: String;
begin
  Result := False;
  if not FileExists(Path) then Exit;
  if not LoadStringFromFile(Path, Contents) then
    RaiseException('Cannot read the installed OTA server configuration.');
  Value := Trim(String(Contents));
  { Match only the retired official capability, including its previously used
    direct-read and trailing-slash forms. Explicit custom repositories survive. }
  Result := (Value = 'https://cloudx.playones.com/sd/YCsIY2UB/?d') or
     (Value = 'https://cloudx.playones.com/sd/YCsIY2UB?d') or
     (Value = 'https://cloudx.playones.com/sd/YCsIY2UB/') or
     (Value = 'https://cloudx.playones.com/sd/YCsIY2UB');
end;

procedure ReplaceRetiredOfficialOtaServer(const Path: String);
begin
  if not IsRetiredOfficialOtaServer(Path) then Exit;
  if not SaveStringToFile(Path,
    'https://cloudx.playones.com/d/CLOUD/Footage/EAPIL/Artemis/ota/' + #13#10, False) then
    RaiseException('Cannot replace the retired official OTA server configuration.');
  Log('Replaced the retired official OTA server configuration: ' + Path);
end;

procedure RepairInstalledOtaConfig(const Root: String);
begin
  ReplaceRetiredOfficialOtaServer(AddBackslash(Root) + 'update\server.txt');
  { This override takes priority over update\server.txt in the updater. }
  ReplaceRetiredOfficialOtaServer(AddBackslash(Root) + 'data\update\server.txt');
end;
