unit devicesconfig;

{
  Loads buses, devices[], evdev, device_mappings from hambridge.yaml (plan §3.1).
  VISCA devices use slug + viscaAddress (1..7).
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils, Classes, fpjson;

type
  TEvdevInputConfig = record
    Slug: string;              { MQTT segment and logs, e.g. camera_stage }
    DeviceNode: string;
    GrabExclusive: Boolean;
    MqttTopic: string;
  end;

  TRs485BusConfig = record
    Enabled: Boolean;
    RtsOnSend: Boolean;
    RtsAfterSend: Boolean;
    DelayRtsBeforeSend: Cardinal;
    DelayRtsAfterSend: Cardinal;
  end;

  TSerialBusConfig = record
    Id: string;
    Port: string;
    Baud: Integer;
    DataBits: Integer;
    Parity: Char;
    StopBits: Integer;
    Rs485: TRs485BusConfig;
  end;

  TViscaDeviceConfig = record
    Slug: string;              { MQTT topic segment: device/<slug>/<command> }
    Model: string;
    BusId: string;
    ViscaAddress: Byte;        { VISCA peripheral address 1..7 from JSON "viscaAddress" }
    MinInterCommandMs: Cardinal;
    MaxQueueDepth: Cardinal;
    AckTimeoutMs: Cardinal;     { 0 = do not wait for VISCA reply before next command }
    CommandRetryMax: Cardinal; { extra attempts after first TX (0 = no retries) }
    RetryBackoffMs: Cardinal; { delay before each retry }
    CoalescePaths: array of string; { scheduler.coalesce: first path segment, e.g. pan / tilt / zoom }
  end;

  TSerialBusDyn = array of TSerialBusConfig;
  TViscaDeviceDyn = array of TViscaDeviceConfig;

  TDevicesConfig = record
    EvdevEnabled: Boolean;
    EvdevInputs: array of TEvdevInputConfig;
    Buses: TSerialBusDyn;
    ViscaDevices: TViscaDeviceDyn;
    ViscaMappingPath: string;
  end;

function LoadDevicesConfig(const Path: string): TDevicesConfig;
{ Raises if evdev or VISCA sections are internally inconsistent. }
procedure ValidateDevicesConfig(const D: TDevicesConfig);
{ Resolves VISCA mapping: BRIDGE_VISCA_MAPPING, device_mappings.visca (relative to main config dir), defaults. }
function DiscoverViscaMappingPath(const MainConfigPath: string; const D: TDevicesConfig): string;

implementation

uses
  jsonutil, Math, yamlmin;

function PathIsAbsolute(const P: string): Boolean;
begin
  Result := (P <> '') and (P[1] = '/');
end;

function FileExistsReadable(const Path: string): Boolean;
begin
  Result := (Path <> '') and FileExists(Path);
end;

function JsonGetString(Obj: TJSONObject; const Key: string; const Default: string = ''): string;
var
  Data: TJSONData;
begin
  Data := ObjFindCI(Obj, Key);
  if Data = nil then
    Exit(Default);
  if Data.JSONType = jtNull then
    Exit('');
  if Data is TJSONString then
    Exit(TJSONString(Data).AsString);
  if Data is TJSONBoolean then
    Exit(BoolToStr(TJSONBoolean(Data).AsBoolean, 'true', 'false'));
  if Data is TJSONNumber then
    Exit(IntToStr(TJSONNumber(Data).AsInteger));
  Result := Default;
end;

function JsonGetBool(Obj: TJSONObject; const Key: string; Default: Boolean): Boolean;
var
  Data: TJSONData;
begin
  Data := ObjFindCI(Obj, Key);
  if Data = nil then
    Exit(Default);
  if Data.JSONType = jtNull then
    Exit(Default);
  if Data is TJSONBoolean then
    Exit(TJSONBoolean(Data).AsBoolean);
  if Data is TJSONString then
    Exit(LowerCase(TJSONString(Data).AsString) = 'true');
  Result := Default;
end;

function JsonGetInt(Obj: TJSONObject; const Key: string; Default: Integer): Integer;
var
  Data: TJSONData;
begin
  Data := ObjFindCI(Obj, Key);
  if Data = nil then
    Exit(Default);
  if Data is TJSONNumber then
    Exit(Integer(TJSONNumber(Data).AsInteger));
  if Data is TJSONString then
    Exit(StrToIntDef(TJSONString(Data).AsString, Default));
  Result := Default;
end;

function JsonGetRequiredSlug(Obj: TJSONObject; const Context: string): string;
var
  c: Char;
  I: Integer;
begin
  Result := Trim(JsonGetString(Obj, 'slug', ''));
  if Result = '' then
    raise Exception.Create('hambridge.yaml: ' + Context + ' needs non-empty "slug"');
  if Pos('/', Result) > 0 then
    raise Exception.Create('hambridge.yaml: ' + Context + ' slug must not contain "/"');
  for I := 1 to Length(Result) do
  begin
    c := Result[I];
    if not (c in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-']) then
      raise Exception.Create('hambridge.yaml: ' + Context + ' slug may only use letters, digits, underscore, hyphen');
  end;
end;

function JsonGetChar(Obj: TJSONObject; const Key: string; Default: Char): Char;
var
  S: string;
begin
  S := Trim(JsonGetString(Obj, Key, ''));
  if S = '' then
    Exit(Default);
  Result := S[1];
end;

procedure LoadBuses(Root: TJSONObject; var Buses: TSerialBusDyn);
var
  BObj: TJSONObject;
  I: Integer;
  Name: string;
  Row, Rs485Obj, Tc: TJSONObject;
  Transport: string;
begin
  SetLength(Buses, 0);
  BObj := ObjGetObjectCI(Root, 'buses');
  if BObj = nil then
    Exit;
  SetLength(Buses, BObj.Count);
  for I := 0 to BObj.Count - 1 do
  begin
    Name := BObj.Names[I];
    Buses[I].Id := Name;
    if not (BObj.Items[I] is TJSONObject) then
      raise Exception.Create('hambridge.yaml: buses.' + Name + ' must be an object');
    Row := TJSONObject(BObj.Items[I]);
    Transport := LowerCase(Trim(JsonGetString(Row, 'transport', '')));
    if Transport = '' then
      Transport := 'serial';
    if SameText(Transport, 'udp') then
      raise Exception.Create('hambridge.yaml: bus "' + Name +
        '" uses UDP (not implemented in this build; use transport: serial or remove UDP buses)');
    if not SameText(Transport, 'serial') then
      raise Exception.Create('hambridge.yaml: bus "' + Name + '" has unsupported transport "' +
        JsonGetString(Row, 'transport', '') + '" (supported: serial)');

    Tc := ObjGetObjectCI(Row, 'transport_configuration');
    if Tc <> nil then
    begin
      Buses[I].Port := JsonGetString(Tc, 'port', '');
      Buses[I].Baud := JsonGetInt(Tc, 'baud', 9600);
      Buses[I].DataBits := JsonGetInt(Tc, 'dataBits', 8);
      Buses[I].Parity := JsonGetChar(Tc, 'parity', 'N');
      Buses[I].StopBits := JsonGetInt(Tc, 'stopBits', 1);
      FillChar(Buses[I].Rs485, SizeOf(Buses[I].Rs485), 0);
      Rs485Obj := ObjGetObjectCI(Tc, 'rs485');
    end
    else
    begin
      Buses[I].Port := JsonGetString(Row, 'port', '');
      Buses[I].Baud := JsonGetInt(Row, 'baud', 9600);
      Buses[I].DataBits := JsonGetInt(Row, 'dataBits', 8);
      Buses[I].Parity := JsonGetChar(Row, 'parity', 'N');
      Buses[I].StopBits := JsonGetInt(Row, 'stopBits', 1);
      FillChar(Buses[I].Rs485, SizeOf(Buses[I].Rs485), 0);
      Rs485Obj := ObjGetObjectCI(Row, 'rs485');
    end;
    if Rs485Obj <> nil then
    begin
      Buses[I].Rs485.Enabled := JsonGetBool(Rs485Obj, 'enabled', False);
      Buses[I].Rs485.RtsOnSend := JsonGetBool(Rs485Obj, 'rtsOnSend', True);
      Buses[I].Rs485.RtsAfterSend := JsonGetBool(Rs485Obj, 'rtsAfterSend', False);
      Buses[I].Rs485.DelayRtsBeforeSend := Cardinal(Max(0, JsonGetInt(Rs485Obj, 'delayRtsBeforeSend', 0)));
      Buses[I].Rs485.DelayRtsAfterSend := Cardinal(Max(0, JsonGetInt(Rs485Obj, 'delayRtsAfterSend', 0)));
    end;
    if Buses[I].Port = '' then
      raise Exception.Create('hambridge.yaml: bus "' + Name + '" needs transport_configuration.port (or legacy port)');
  end;
end;

procedure LoadViscaDevices(Root: TJSONObject; var Devs: TViscaDeviceDyn);
var
  Arr, CoalArr: TJSONArray;
  I, J: Integer;
  Item: TJSONObject;
  Sch: TJSONObject;
  addr: Integer;
begin
  SetLength(Devs, 0);
  if not (ObjFindCI(Root, 'devices') is TJSONArray) then
    Exit;
  Arr := TJSONArray(ObjFindCI(Root, 'devices'));
  SetLength(Devs, Arr.Count);
  for I := 0 to Arr.Count - 1 do
  begin
    if not (Arr.Items[I] is TJSONObject) then
      raise Exception.Create('hambridge.yaml: devices[' + IntToStr(I) + '] must be an object');
    Item := TJSONObject(Arr.Items[I]);
    Devs[I].Slug := JsonGetRequiredSlug(Item, 'VISCA device[' + IntToStr(I) + ']');
    Devs[I].Model := JsonGetString(Item, 'model', '');
    Devs[I].BusId := JsonGetString(Item, 'bus', '');
    addr := JsonGetInt(Item, 'viscaAddress', -1);
    if (addr < 1) or (addr > 7) then
      raise Exception.Create('hambridge.yaml: VISCA device slug "' + Devs[I].Slug + '" needs integer viscaAddress in 1..7');
    Devs[I].ViscaAddress := Byte(addr);
    Devs[I].MinInterCommandMs := 40;
    Devs[I].MaxQueueDepth := 50;
    Devs[I].AckTimeoutMs := 800;
    Devs[I].CommandRetryMax := 2;
    Devs[I].RetryBackoffMs := 50;
    Sch := ObjGetObjectCI(Item, 'scheduler');
    SetLength(Devs[I].CoalescePaths, 0);
    if Sch <> nil then
    begin
      Devs[I].MinInterCommandMs := Cardinal(Max(1, JsonGetInt(Sch, 'minInterCommandMs', 40)));
      Devs[I].MaxQueueDepth := Cardinal(Max(1, JsonGetInt(Sch, 'maxQueueDepth', 50)));
      Devs[I].AckTimeoutMs := Cardinal(Max(0, JsonGetInt(Sch, 'ackTimeoutMs', 800)));
      Devs[I].CommandRetryMax := Cardinal(Max(0, JsonGetInt(Sch, 'commandRetryMax', 2)));
      Devs[I].RetryBackoffMs := Cardinal(Max(0, JsonGetInt(Sch, 'retryBackoffMs', 50)));
      if ObjFindCI(Sch, 'coalesce') is TJSONArray then
      begin
        CoalArr := TJSONArray(ObjFindCI(Sch, 'coalesce'));
        SetLength(Devs[I].CoalescePaths, CoalArr.Count);
        for J := 0 to CoalArr.Count - 1 do
        begin
          Devs[I].CoalescePaths[J] := '';
          if CoalArr.Items[J] is TJSONString then
            Devs[I].CoalescePaths[J] := Trim(TJSONString(CoalArr.Items[J]).AsString);
        end;
      end;
    end;
    if Devs[I].Model = '' then
      raise Exception.Create('hambridge.yaml: VISCA device slug "' + Devs[I].Slug + '" needs model');
    if Devs[I].BusId = '' then
      raise Exception.Create('hambridge.yaml: VISCA device slug "' + Devs[I].Slug + '" needs bus');
  end;
end;

function LoadDevicesConfig(const Path: string): TDevicesConfig;
var
  Data: TJSONData;
  Root, Ev, Dm: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
  Item: TJSONObject;
begin
  FillChar(Result, SizeOf(Result), 0);
  Data := YamlFileToJsonData(Path);
  if not (Data is TJSONObject) then
  begin
    Data.Free;
    raise Exception.Create('hambridge.yaml: root must be an object');
  end;
  Root := TJSONObject(Data);
  try
    LoadBuses(Root, Result.Buses);
    LoadViscaDevices(Root, Result.ViscaDevices);
    Result.ViscaMappingPath := '';
    Dm := ObjGetObjectCI(Root, 'device_mappings');
    if Dm <> nil then
      Result.ViscaMappingPath := JsonGetString(Dm, 'visca', '');
    if Result.ViscaMappingPath = '' then
      Result.ViscaMappingPath := JsonGetString(Root, 'viscaMapping', '');
    if Result.ViscaMappingPath = '' then
      Result.ViscaMappingPath := JsonGetString(Root, 'visca_mapping', '');

    Ev := ObjGetObjectCI(Root, 'evdev');
    if Ev = nil then
    begin
      Result.EvdevEnabled := False;
      SetLength(Result.EvdevInputs, 0);
    end
    else
    begin
      Result.EvdevEnabled := JsonGetBool(Ev, 'enabled', False);
      if not (ObjFindCI(Ev, 'inputs') is TJSONArray) then
        raise Exception.Create('hambridge.yaml: evdev.inputs must be an array');
      Arr := TJSONArray(ObjFindCI(Ev, 'inputs'));
      SetLength(Result.EvdevInputs, Arr.Count);
      for I := 0 to Arr.Count - 1 do
      begin
        if not (Arr.Items[I] is TJSONObject) then
          raise Exception.Create('hambridge.yaml: evdev.inputs[' + IntToStr(I) + '] must be an object');
        Item := TJSONObject(Arr.Items[I]);
        Result.EvdevInputs[I].Slug := JsonGetRequiredSlug(Item, 'evdev.inputs[' + IntToStr(I) + ']');
        Result.EvdevInputs[I].DeviceNode := JsonGetString(Item, 'deviceNode', '');
        Result.EvdevInputs[I].GrabExclusive := JsonGetBool(Item, 'grabExclusive', False);
        Result.EvdevInputs[I].MqttTopic := JsonGetString(Item, 'mqttTopic', '');
        if Result.EvdevInputs[I].DeviceNode = '' then
          raise Exception.Create('hambridge.yaml: evdev input "' + Result.EvdevInputs[I].Slug + '" needs deviceNode');
        if Trim(Result.EvdevInputs[I].MqttTopic) = '' then
          Result.EvdevInputs[I].MqttTopic := 'evdev/' + Result.EvdevInputs[I].Slug + '/event';
      end;
    end;
  finally
    Root.Free;
  end;
end;

procedure ValidateDevicesConfig(const D: TDevicesConfig);
var
  I, J: Integer;
  BusFound: Boolean;
begin
  if D.EvdevEnabled and (Length(D.EvdevInputs) = 0) then
    raise Exception.Create('hambridge.yaml: evdev.enabled is true but evdev.inputs is empty');
  if (Length(D.ViscaDevices) > 0) and (Length(D.Buses) = 0) then
    raise Exception.Create('hambridge.yaml: VISCA devices require at least one bus in "buses"');
  for I := 0 to High(D.ViscaDevices) do
  begin
    BusFound := False;
    for J := 0 to High(D.Buses) do
      if SameText(D.Buses[J].Id, D.ViscaDevices[I].BusId) then
      begin
        BusFound := True;
        Break;
      end;
    if not BusFound then
      raise Exception.Create('hambridge.yaml: VISCA device slug "' + D.ViscaDevices[I].Slug +
        '" references unknown bus "' + D.ViscaDevices[I].BusId + '"');
  end;
  for I := 0 to High(D.ViscaDevices) do
    for J := I + 1 to High(D.ViscaDevices) do
      if SameText(D.ViscaDevices[I].Slug, D.ViscaDevices[J].Slug) then
        raise Exception.Create('hambridge.yaml: duplicate VISCA device slug "' + D.ViscaDevices[I].Slug + '"');
  for I := 0 to High(D.EvdevInputs) do
    for J := I + 1 to High(D.EvdevInputs) do
      if SameText(D.EvdevInputs[I].Slug, D.EvdevInputs[J].Slug) then
        raise Exception.Create('hambridge.yaml: duplicate evdev input slug "' + D.EvdevInputs[I].Slug + '"');
end;

function DiscoverViscaMappingPath(const MainConfigPath: string; const D: TDevicesConfig): string;
var
  e, cand, base: string;
begin
  Result := '';
  e := Trim(GetEnvironmentVariable('BRIDGE_VISCA_MAPPING'));
  if (e <> '') and FileExists(e) then
    Exit(e);
  if Trim(D.ViscaMappingPath) <> '' then
  begin
    cand := D.ViscaMappingPath;
    if not PathIsAbsolute(cand) then
    begin
      base := ExtractFileDir(MainConfigPath);
      if base <> '' then
        cand := IncludeTrailingPathDelimiter(base) + cand
      else
        cand := cand;
    end;
    if FileExists(cand) then
      Exit(cand);
  end;
  base := ExtractFileDir(MainConfigPath);
  if base <> '' then
  begin
    cand := IncludeTrailingPathDelimiter(base) + 'mappings/visca.yaml';
    if FileExists(cand) then
      Exit(cand);
    cand := IncludeTrailingPathDelimiter(base) + 'mappings/visca.yml';
    if FileExists(cand) then
      Exit(cand);
    cand := IncludeTrailingPathDelimiter(base) + 'visca.yaml';
    if FileExists(cand) then
      Exit(cand);
    cand := IncludeTrailingPathDelimiter(base) + 'visca-mapping.json';
    if FileExists(cand) then
      Exit(cand);
  end;
  if FileExists('visca.yaml') then
    Exit('visca.yaml');
  if FileExists('visca-mapping.json') then
    Exit('visca-mapping.json');
  cand := '/etc/hambridge/config/mappings/visca.yaml';
  if FileExists(cand) then
    Exit(cand);
  cand := '/etc/hambridge/visca-mapping.json';
  if FileExists(cand) then
    Exit(cand);
end;

end.
