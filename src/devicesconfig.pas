unit devicesconfig;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils, Classes, fpjson, jsonparser;

type
  TEvdevInputConfig = record
    Id: string;
    DeviceNode: string;
    GrabExclusive: Boolean;
    MqttTopic: string;
  end;

  TDevicesConfig = record
    EvdevEnabled: Boolean;
    EvdevInputs: array of TEvdevInputConfig;
  end;

function FindDevicesConfigPath(const CliPath: string): string;
function LoadDevicesConfig(const Path: string): TDevicesConfig;

implementation

uses
  jsonutil;

function FileExistsReadable(const Path: string): Boolean;
begin
  Result := (Path <> '') and FileExists(Path);
end;

function FindDevicesConfigPath(const CliPath: string): string;
begin
  if FileExistsReadable(CliPath) then
    Exit(CliPath);
  if FileExistsReadable(GetEnvironmentVariable('BRIDGE_DEVICES')) then
    Exit(GetEnvironmentVariable('BRIDGE_DEVICES'));
  if FileExistsReadable('devices.json') then
    Exit('devices.json');
  if FileExistsReadable('/etc/hambridge/devices.json') then
    Exit('/etc/hambridge/devices.json');
  Result := '';
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

function LoadDevicesConfig(const Path: string): TDevicesConfig;
var
  Parser: TJSONParser;
  Stream: TFileStream;
  Data: TJSONData;
  Root, Ev: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
  Item: TJSONObject;
begin
  FillChar(Result, SizeOf(Result), 0);
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  try
    Parser := TJSONParser.Create(Stream);
    try
      Data := Parser.Parse;
    finally
      Parser.Free;
    end;
  finally
    Stream.Free;
  end;
  if not (Data is TJSONObject) then
  begin
    Data.Free;
    raise Exception.Create('devices.json: root must be an object');
  end;
  Root := TJSONObject(Data);
  try
    Ev := ObjGetObjectCI(Root, 'evdev');
    if Ev = nil then
      raise Exception.Create('devices.json: missing "evdev" object');
    Result.EvdevEnabled := JsonGetBool(Ev, 'enabled', False);
    if not (ObjFindCI(Ev, 'inputs') is TJSONArray) then
      raise Exception.Create('devices.json: evdev.inputs must be an array');
    Arr := TJSONArray(ObjFindCI(Ev, 'inputs'));
    SetLength(Result.EvdevInputs, Arr.Count);
    for I := 0 to Arr.Count - 1 do
    begin
      if not (Arr.Items[I] is TJSONObject) then
        raise Exception.Create('devices.json: evdev.inputs[' + IntToStr(I) + '] must be an object');
      Item := TJSONObject(Arr.Items[I]);
      Result.EvdevInputs[I].Id := JsonGetString(Item, 'id', '');
      Result.EvdevInputs[I].DeviceNode := JsonGetString(Item, 'deviceNode', '');
      Result.EvdevInputs[I].GrabExclusive := JsonGetBool(Item, 'grabExclusive', False);
      Result.EvdevInputs[I].MqttTopic := JsonGetString(Item, 'mqttTopic', '');
      if Result.EvdevInputs[I].Id = '' then
        raise Exception.Create('devices.json: each evdev input needs "id"');
      if Result.EvdevInputs[I].DeviceNode = '' then
        raise Exception.Create('devices.json: input "' + Result.EvdevInputs[I].Id + '" needs deviceNode');
      if Trim(Result.EvdevInputs[I].MqttTopic) = '' then
        Result.EvdevInputs[I].MqttTopic := 'evdev/' + Result.EvdevInputs[I].Id + '/event';
    end;
  finally
    Root.Free;
  end;
end;

end.
