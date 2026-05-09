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
    Transport: string;
    Protocol: string;
    Port: string;
    Baud: Integer;
    DataBits: Integer;
    Parity: Char;
    StopBits: Integer;
    Rs485: TRs485BusConfig;
  end;

  TBusMeta = record
    Id: string;
    Transport: string;
    Protocol: string;
    ProtocolConfig: TJSONObject; { shallow reference while loading; not stored long-term }
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
  TBusMetaDyn = array of TBusMeta;
  TEvdevInputDyn = array of TEvdevInputConfig;

  TDevicesConfig = record
    EvdevEnabled: Boolean;
    EvdevInputs: TEvdevInputDyn;
    { Serial VISCA buses only (transport=serial, protocol=visca). }
    Buses: TSerialBusDyn;
    { Metadata for all buses under hambridge.yaml buses.* (serial/udp/none). }
    BusMeta: TBusMetaDyn;
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
  I, OutCount: Integer;
  Name: string;
  Row, Rs485Obj, Tc: TJSONObject;
  Transport, Protocol: string;
begin
  SetLength(Buses, 0);
  BObj := ObjGetObjectCI(Root, 'buses');
  if BObj = nil then
    Exit;
  SetLength(Buses, BObj.Count); { maximum; shrink after filtering }
  OutCount := 0;
  for I := 0 to BObj.Count - 1 do
  begin
    Name := BObj.Names[I];
    if not (BObj.Items[I] is TJSONObject) then
      raise Exception.Create('hambridge.yaml: buses.' + Name + ' must be an object');
    Row := TJSONObject(BObj.Items[I]);
    Transport := Trim(JsonGetString(Row, 'transport', ''));
    Protocol := Trim(JsonGetString(Row, 'protocol', ''));
    if Transport = '' then
      raise Exception.Create('hambridge.yaml: bus "' + Name + '" must set transport (e.g. "serial")');
    if Protocol = '' then
      raise Exception.Create('hambridge.yaml: bus "' + Name + '" must set protocol (e.g. "visca")');

    Transport := LowerCase(Transport);
    Protocol := LowerCase(Protocol);
    if (ObjFindCI(Row, 'protocol_config') <> nil) and (not (ObjFindCI(Row, 'protocol_config') is TJSONObject)) then
      raise Exception.Create('hambridge.yaml: bus "' + Name + '" protocol_config must be an object when present');

    { Only serial/visca buses are turned into TSerialBusConfig entries for the current VISCA router.
      Other buses (udp/visca, none/evdev, future) are validated and stored in BusMeta. }
    if SameText(Transport, 'serial') and SameText(Protocol, 'visca') then
    begin
      Buses[OutCount].Id := Name;
      Buses[OutCount].Transport := Transport;
      Buses[OutCount].Protocol := Protocol;

      Tc := ObjGetObjectCI(Row, 'transport_configuration');
      if Tc <> nil then
      begin
        Buses[OutCount].Port := JsonGetString(Tc, 'port', '');
        Buses[OutCount].Baud := JsonGetInt(Tc, 'baud', 9600);
        Buses[OutCount].DataBits := JsonGetInt(Tc, 'dataBits', 8);
        Buses[OutCount].Parity := JsonGetChar(Tc, 'parity', 'N');
        Buses[OutCount].StopBits := JsonGetInt(Tc, 'stopBits', 1);
        FillChar(Buses[OutCount].Rs485, SizeOf(Buses[OutCount].Rs485), 0);
        Rs485Obj := ObjGetObjectCI(Tc, 'rs485');
      end
      else
      begin
        Buses[OutCount].Port := JsonGetString(Row, 'port', '');
        Buses[OutCount].Baud := JsonGetInt(Row, 'baud', 9600);
        Buses[OutCount].DataBits := JsonGetInt(Row, 'dataBits', 8);
        Buses[OutCount].Parity := JsonGetChar(Row, 'parity', 'N');
        Buses[OutCount].StopBits := JsonGetInt(Row, 'stopBits', 1);
        FillChar(Buses[OutCount].Rs485, SizeOf(Buses[OutCount].Rs485), 0);
        Rs485Obj := ObjGetObjectCI(Row, 'rs485');
      end;
      if Rs485Obj <> nil then
      begin
        Buses[OutCount].Rs485.Enabled := JsonGetBool(Rs485Obj, 'enabled', False);
        Buses[OutCount].Rs485.RtsOnSend := JsonGetBool(Rs485Obj, 'rtsOnSend', True);
        Buses[OutCount].Rs485.RtsAfterSend := JsonGetBool(Rs485Obj, 'rtsAfterSend', False);
        Buses[OutCount].Rs485.DelayRtsBeforeSend := Cardinal(Max(0, JsonGetInt(Rs485Obj, 'delayRtsBeforeSend', 0)));
        Buses[OutCount].Rs485.DelayRtsAfterSend := Cardinal(Max(0, JsonGetInt(Rs485Obj, 'delayRtsAfterSend', 0)));
      end;
      if Buses[OutCount].Port = '' then
        raise Exception.Create('hambridge.yaml: bus "' + Name + '" needs transport_configuration.port (or legacy port)');
      Inc(OutCount);
    end;
  end;
  SetLength(Buses, OutCount);
end;

procedure LoadBusMeta(Root: TJSONObject; var Meta: TBusMetaDyn);
var
  BObj: TJSONObject;
  I: Integer;
  Name: string;
  Row: TJSONObject;
begin
  SetLength(Meta, 0);
  BObj := ObjGetObjectCI(Root, 'buses');
  if BObj = nil then
    Exit;
  SetLength(Meta, BObj.Count);
  for I := 0 to BObj.Count - 1 do
  begin
    Name := BObj.Names[I];
    if not (BObj.Items[I] is TJSONObject) then
      raise Exception.Create('hambridge.yaml: buses.' + Name + ' must be an object');
    Row := TJSONObject(BObj.Items[I]);
    Meta[I].Id := Name;
    Meta[I].Transport := LowerCase(Trim(JsonGetString(Row, 'transport', '')));
    Meta[I].Protocol := LowerCase(Trim(JsonGetString(Row, 'protocol', '')));
    Meta[I].ProtocolConfig := nil;
    if ObjFindCI(Row, 'protocol_config') is TJSONObject then
      Meta[I].ProtocolConfig := TJSONObject(ObjFindCI(Row, 'protocol_config'));
  end;
end;

function FindBusMetaIndex(const Meta: TBusMetaDyn; const BusId: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Meta) do
    if SameText(Meta[I].Id, BusId) then
      Exit(I);
  Result := -1;
end;

function BusMetaBool(const M: TBusMeta; const Key: string; Default: Boolean): Boolean;
begin
  if M.ProtocolConfig = nil then
    Exit(Default);
  Result := JsonGetBool(M.ProtocolConfig, Key, Default);
end;

procedure LoadEndpoints(Root: TJSONObject; const Meta: TBusMetaDyn; out Devs: TViscaDeviceDyn; out Inputs: TEvdevInputDyn;
  out EvdevEnabled: Boolean);
var
  Arr, CoalArr: TJSONArray;
  I, J: Integer;
  Item, MatchObj, Sch: TJSONObject;
  Slug, EndpointType, Protocol, BusId, Model: string;
  BusIx: Integer;
  DeviceID: Integer;
  Inp: TEvdevInputConfig;
begin
  SetLength(Devs, 0);
  SetLength(Inputs, 0);
  EvdevEnabled := False;
  if not (ObjFindCI(Root, 'endpoints') is TJSONArray) then
    Exit;
  Arr := TJSONArray(ObjFindCI(Root, 'endpoints'));
  for I := 0 to Arr.Count - 1 do
  begin
    if not (Arr.Items[I] is TJSONObject) then
      raise Exception.Create('hambridge.yaml: endpoints[' + IntToStr(I) + '] must be an object');
    Item := TJSONObject(Arr.Items[I]);
    Slug := JsonGetRequiredSlug(Item, 'endpoint[' + IntToStr(I) + ']');
    if not (ObjFindCI(Item, 'match') is TJSONObject) then
      raise Exception.Create('hambridge.yaml: endpoint "' + Slug + '" needs match object');
    MatchObj := TJSONObject(ObjFindCI(Item, 'match'));
    EndpointType := LowerCase(Trim(JsonGetString(MatchObj, 'endpoint_type', '')));
    BusId := Trim(JsonGetString(MatchObj, 'bus', ''));
    if EndpointType = '' then
      raise Exception.Create('hambridge.yaml: endpoint "' + Slug + '" needs match.endpoint_type');
    if BusId = '' then
      raise Exception.Create('hambridge.yaml: endpoint "' + Slug + '" needs match.bus');
    BusIx := FindBusMetaIndex(Meta, BusId);
    if BusIx < 0 then
      raise Exception.Create('hambridge.yaml: endpoint "' + Slug + '" references unknown bus "' + BusId + '"');

    if EndpointType = 'device' then
    begin
      if not SameText(Meta[BusIx].Protocol, 'visca') then
        raise Exception.Create('hambridge.yaml: endpoint "' + Slug + '" endpoint_type device requires a visca bus');
      DeviceID := JsonGetInt(MatchObj, 'deviceID', -1);
      if (DeviceID < 1) or (DeviceID > 7) then
        raise Exception.Create('hambridge.yaml: device endpoint "' + Slug + '" needs integer match.deviceID in 1..7');
      Model := Trim(JsonGetString(Item, 'model', ''));
      if Model = '' then
        raise Exception.Create('hambridge.yaml: device endpoint "' + Slug + '" needs model');

      SetLength(Devs, Length(Devs) + 1);
      Devs[High(Devs)].Slug := Slug;
      Devs[High(Devs)].Model := Model;
      Devs[High(Devs)].BusId := BusId;
      Devs[High(Devs)].ViscaAddress := Byte(DeviceID);
      Devs[High(Devs)].MinInterCommandMs := 40;
      Devs[High(Devs)].MaxQueueDepth := 50;
      Devs[High(Devs)].AckTimeoutMs := 800;
      Devs[High(Devs)].CommandRetryMax := 2;
      Devs[High(Devs)].RetryBackoffMs := 50;
      SetLength(Devs[High(Devs)].CoalescePaths, 0);
      Sch := ObjGetObjectCI(Item, 'scheduler');
      if Sch <> nil then
      begin
        Devs[High(Devs)].MinInterCommandMs := Cardinal(Max(1, JsonGetInt(Sch, 'minInterCommandMs', 40)));
        Devs[High(Devs)].MaxQueueDepth := Cardinal(Max(1, JsonGetInt(Sch, 'maxQueueDepth', 50)));
        Devs[High(Devs)].AckTimeoutMs := Cardinal(Max(0, JsonGetInt(Sch, 'ackTimeoutMs', 800)));
        Devs[High(Devs)].CommandRetryMax := Cardinal(Max(0, JsonGetInt(Sch, 'commandRetryMax', 2)));
        Devs[High(Devs)].RetryBackoffMs := Cardinal(Max(0, JsonGetInt(Sch, 'retryBackoffMs', 50)));
        if ObjFindCI(Sch, 'coalesce') is TJSONArray then
        begin
          CoalArr := TJSONArray(ObjFindCI(Sch, 'coalesce'));
          SetLength(Devs[High(Devs)].CoalescePaths, CoalArr.Count);
          for J := 0 to CoalArr.Count - 1 do
          begin
            Devs[High(Devs)].CoalescePaths[J] := '';
            if CoalArr.Items[J] is TJSONString then
              Devs[High(Devs)].CoalescePaths[J] := Trim(TJSONString(CoalArr.Items[J]).AsString);
          end;
        end;
      end;
    end
    else if EndpointType = 'controller' then
    begin
      Protocol := LowerCase(Trim(JsonGetString(MatchObj, 'protocol', '')));
      if Protocol = '' then
        raise Exception.Create('hambridge.yaml: controller endpoint "' + Slug + '" needs match.protocol');
      if Protocol = 'evdev' then
      begin
        if not SameText(Meta[BusIx].Protocol, 'evdev') then
          raise Exception.Create('hambridge.yaml: controller endpoint "' + Slug + '" protocol evdev requires an evdev bus');
        if not BusMetaBool(Meta[BusIx], 'enabled', True) then
          raise Exception.Create('hambridge.yaml: controller endpoint "' + Slug + '" references evdev bus "' + BusId + '" but protocol_config.enabled is false');
        FillChar(Inp, SizeOf(Inp), 0);
        Inp.Slug := Slug;
        Inp.DeviceNode := Trim(JsonGetString(MatchObj, 'deviceNode', ''));
        Inp.GrabExclusive := JsonGetBool(Item, 'grabExclusive', False);
        Inp.MqttTopic := Trim(JsonGetString(Item, 'mqttTopic', ''));
        if Inp.DeviceNode = '' then
          raise Exception.Create('hambridge.yaml: controller endpoint "' + Slug + '" needs match.deviceNode');
        if Inp.MqttTopic = '' then
          Inp.MqttTopic := 'controller/' + Slug + '/event';
        SetLength(Inputs, Length(Inputs) + 1);
        Inputs[High(Inputs)] := Inp;
        EvdevEnabled := True;
      end
      else if Protocol = 'visca' then
        raise Exception.Create('hambridge.yaml: controller endpoint "' + Slug + '" protocol visca not implemented yet')
      else
        raise Exception.Create('hambridge.yaml: controller endpoint "' + Slug + '" has unknown match.protocol "' + Protocol + '"');
    end
    else
      raise Exception.Create('hambridge.yaml: endpoint "' + Slug + '" has unknown match.endpoint_type "' + EndpointType + '"');
  end;
end;

function LoadDevicesConfig(const Path: string): TDevicesConfig;
var
  Data: TJSONData;
  Root, Dm: TJSONObject;
  TmpInputs: TEvdevInputDyn;
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
    LoadBusMeta(Root, Result.BusMeta);

    Result.ViscaMappingPath := '';
    Dm := ObjGetObjectCI(Root, 'device_mappings');
    if Dm <> nil then
      Result.ViscaMappingPath := JsonGetString(Dm, 'visca', '');
    if Result.ViscaMappingPath = '' then
      Result.ViscaMappingPath := JsonGetString(Root, 'viscaMapping', '');
    if Result.ViscaMappingPath = '' then
      Result.ViscaMappingPath := JsonGetString(Root, 'visca_mapping', '');
    LoadEndpoints(Root, Result.BusMeta, Result.ViscaDevices, TmpInputs, Result.EvdevEnabled);
    Result.EvdevInputs := TmpInputs;
  finally
    Root.Free;
  end;
end;

procedure ValidateDevicesConfig(const D: TDevicesConfig);
var
  I, J: Integer;
begin
  if (Length(D.ViscaDevices) > 0) and (Length(D.Buses) = 0) then
    raise Exception.Create('hambridge.yaml: VISCA devices require at least one bus in "buses"');
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
