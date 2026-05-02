unit config;

{
  Loads process-wide settings from bridge.json (plan §3.0): MQTT broker, optional LWT/birth,
  logging. Applies BRIDGE_* environment overrides before reading values.
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils, Classes, fpjson, jsonparser, logger;

type
  { MQTT Last Will and Testament: broker publishes this if the client disconnects uncleanly.
    Populated from bridge.json "mqtt.lwt" (topic, payload, retain, qos). }
  TBridgeMqttLwt = record
    Topic: string;    { MQTT topic for the LWT message }
    Payload: string;  { Payload the broker should send on unexpected disconnect }
    Retain: Boolean;  { Whether the LWT message is retained }
    Qos: Byte;        { MQTT QoS (0..2) for LWT }
  end;

  { Optional "birth" message published when the client connects successfully.
    Populated from bridge.json "mqtt.birth". }
  TBridgeMqttBirth = record
    Topic: string;    { MQTT topic to publish on connect }
    Payload: string;  { Payload (often "online") }
    Retain: Boolean;
    Qos: Byte;
  end;

  { Broker connection and MQTT session fields from bridge.json "mqtt" object. }
  TBridgeMqtt = record
    Host: string;         { Broker hostname or IP (required) }
    Port: Word;            { Broker TCP port (default 1883) }
    Tls: Boolean;          { Use TLS when connecting (v0.1: OS default trust) }
    Username: string;      { MQTT user; empty if anonymous }
    Password: string;      { MQTT password; empty if none }
    ClientId: string;      { Unique client id on the broker }
    KeepaliveSec: Word;    { MQTT keepalive interval in seconds }
    Lwt: TBridgeMqttLwt;   { Last Will; all-zero/empty if mqtt.lwt omitted }
    Birth: TBridgeMqttBirth; { Connect announcement; empty if mqtt.birth omitted }
  end;

  { Full bridge.json runtime view after parse + env overrides. }
  TBridgeConfig = record
    Mqtt: TBridgeMqtt;      { From "mqtt" }
    LogLevel: TLogLevel;     { From "log.level" or default info }
    LogFormat: string;       { From "log.format" (e.g. text); reserved for future json logs }
  end;

{ See implementation: discovery order for bridge.json. }
function FindBridgeConfigPath(const CliPath: string): string;
{ Parses file, merges BRIDGE_* env, validates; frees JSON tree before return. }
function LoadBridgeConfig(const Path: string): TBridgeConfig;

implementation

uses
  StrUtils, jsonutil;

{ True if Path is non-empty and names an existing file (used for config discovery). }
function FileExistsReadable(const Path: string): Boolean;
begin
  Result := (Path <> '') and FileExists(Path);
end;

{ Resolves bridge.json path: CLI wins, then BRIDGE_CONFIG, ./bridge.json, /etc/hambridge/bridge.json.
  Returns '' if none exist so the caller can print a helpful error. }
function FindBridgeConfigPath(const CliPath: string): string;
begin
  if FileExistsReadable(CliPath) then
    Exit(CliPath);
  if FileExistsReadable(GetEnvironmentVariable('BRIDGE_CONFIG')) then
    Exit(GetEnvironmentVariable('BRIDGE_CONFIG'));
  if FileExistsReadable('bridge.json') then
    Exit('bridge.json');
  if FileExistsReadable('/etc/hambridge/bridge.json') then
    Exit('/etc/hambridge/bridge.json');
  Result := '';
end;

{ Splits BRIDGE_MQTT_HOST style names on '_' for mapping to dotted JSON paths (mqtt.host). }
function SplitUnderscore(const S: string): TStringList;
begin
  Result := TStringList.Create;
  Result.StrictDelimiter := True;
  Result.Delimiter := '_';
  Result.DelimitedText := S;
end;

{ Reads a JSON object field by case-insensitive key; coerces numbers/bools to string for flexibility. }
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
  if Data is TJSONNumber then
    Exit(FloatToStr(TJSONNumber(Data).AsFloat));
  if Data is TJSONBoolean then
    Exit(BoolToStr(TJSONBoolean(Data).AsBoolean, 'true', 'false'));
  Result := Default;
end;

{ Reads boolean from JSON (explicit bool, or string true/false, or number nonzero). }
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
  if Data is TJSONNumber then
    Exit(TJSONNumber(Data).AsInteger <> 0);
  Result := Default;
end;

{ Reads integer from JSON number or numeric string. }
function JsonGetInt(Obj: TJSONObject; const Key: string; Default: Integer): Integer;
var
  Data: TJSONData;
begin
  Data := ObjFindCI(Obj, Key);
  if Data = nil then
    Exit(Default);
  if Data.JSONType = jtNull then
    Exit(Default);
  if Data is TJSONNumber then
    Exit(TJSONNumber(Data).AsInteger);
  if Data is TJSONString then
    Exit(StrToIntDef(TJSONString(Data).AsString, Default));
  Result := Default;
end;

{ Like JsonGetInt but clamps to Word range (ports, keepalive). }
function JsonGetWord(Obj: TJSONObject; const Key: string; Default: Word): Word;
var
  V: Integer;
begin
  V := JsonGetInt(Obj, Key, Default);
  if V < 0 then
    V := 0;
  if V > High(Word) then
    V := High(Word);
  Result := Word(V);
end;

{ Like JsonGetInt but clamps to 0..255 (MQTT QoS). }
function JsonGetByte(Obj: TJSONObject; const Key: string; Default: Byte): Byte;
var
  V: Integer;
begin
  V := JsonGetInt(Obj, Key, Default);
  if V < 0 then
    V := 0;
  if V > 255 then
    V := 255;
  Result := Byte(V);
end;

{ Parses BRIDGE_* boolean env values (1/0, true/false, yes/no); Ok=False if string is not a known form. }
procedure ParseEnvBool(const S: string; out B: Boolean; out Ok: Boolean);
var
  L: string;
begin
  Ok := True;
  L := LowerCase(Trim(S));
  if L = '' then
  begin
    Ok := False;
    Exit;
  end;
  B := (L = '1') or (L = 'true') or (L = 'yes');
  if (not B) and (L <> '0') and (L <> 'false') and (L <> 'no') then
    Ok := False;
end;

{ Parses base-10 integer from env string; Ok from TryStrToInt. }
procedure ParseEnvInt(const S: string; out V: Integer; out Ok: Boolean);
begin
  Ok := TryStrToInt(Trim(S), V);
end;

{ Sets or removes a nested key on Root using dotted Path (e.g. mqtt.host). RawValue '' deletes the key;
  used to merge BRIDGE_* overrides into the parsed JSON before validation. }
procedure SetJsonPath(Root: TJSONObject; const Path: string; const RawValue: string);
var
  SL: TStringList;
  I: Integer;
  Cur: TJSONObject;
  Key: string;
  Vi: Integer;
  B: Boolean;
  Ok: Boolean;
  LastKey: string;
begin
  SL := TStringList.Create;
  try
    SL.StrictDelimiter := True;
    SL.Delimiter := '.';
    SL.DelimitedText := Path;
    if SL.Count = 0 then
      Exit;

    if RawValue = '' then
    begin
      Cur := Root;
      for I := 0 to SL.Count - 2 do
      begin
        Key := SL[I];
        if ObjGetObjectCI(Cur, Key) = nil then
          Exit;
        Cur := ObjGetObjectCI(Cur, Key);
      end;
      LastKey := SL[SL.Count - 1];
      ObjDeleteCI(Cur, LastKey);
      Exit;
    end;

    Cur := Root;
    for I := 0 to SL.Count - 2 do
    begin
      Key := SL[I];
      if ObjGetObjectCI(Cur, Key) = nil then
        Cur.Add(Key, TJSONObject.Create);
      Cur := ObjGetObjectCI(Cur, Key);
    end;
    LastKey := SL[SL.Count - 1];
    ObjDeleteCI(Cur, LastKey);

    if SameText(RawValue, 'null') then
    begin
      Cur.Add(LastKey, TJSONNull.Create);
      Exit;
    end;

    ParseEnvBool(RawValue, B, Ok);
    if Ok then
    begin
      Cur.Add(LastKey, TJSONBoolean.Create(B));
      Exit;
    end;

    ParseEnvInt(RawValue, Vi, Ok);
    if Ok then
    begin
      Cur.Add(LastKey, TJSONInt64Number.Create(Vi));
      Exit;
    end;

    Cur.Add(LastKey, TJSONString.Create(RawValue));
  finally
    SL.Free;
  end;
end;

{ Walks the process environment and applies every BRIDGE_* variable onto Root via SetJsonPath. }
procedure ApplyBridgeEnvOverrides(Root: TJSONObject);
var
  I: Integer;
  Line, N, V, Path: string;
  P: SizeInt;
  SL: TStringList;
  J: Integer;
begin
  for I := 1 to GetEnvironmentVariableCount do
  begin
    Line := GetEnvironmentString(I);
    P := Pos('=', Line);
    if P <= 0 then
      Continue;
    N := Copy(Line, 1, P - 1);
    V := Copy(Line, P + 1, MaxInt);
    if not StartsText('BRIDGE_', N) then
      Continue;
    Delete(N, 1, Length('BRIDGE_'));
    SL := SplitUnderscore(N);
    try
      Path := '';
      for J := 0 to SL.Count - 1 do
      begin
        if J > 0 then
          Path += '.';
        Path += LowerCase(SL[J]);
      end;
      SetJsonPath(Root, Path, V);
    finally
      SL.Free;
    end;
  end;
end;

{ Fills TBridgeMqtt from the root object's "mqtt" child; raises if mqtt is missing. }
function LoadMqttSection(Obj: TJSONObject): TBridgeMqtt;
var
  M: TJSONObject;
  Lwt, Birth: TJSONObject;
begin
  FillChar(Result, SizeOf(Result), 0);
  M := ObjGetObjectCI(Obj, 'mqtt');
  if M = nil then
    raise Exception.Create('bridge.json: missing "mqtt" object');
  Result.Host := JsonGetString(M, 'host', '');
  Result.Port := JsonGetWord(M, 'port', 1883);
  Result.Tls := JsonGetBool(M, 'tls', False);
  Result.Username := JsonGetString(M, 'username', '');
  Result.Password := JsonGetString(M, 'password', '');
  Result.ClientId := JsonGetString(M, 'clientId', 'hambridge');
  Result.KeepaliveSec := JsonGetWord(M, 'keepaliveSec', 30);

  Lwt := ObjGetObjectCI(M, 'lwt');
  if Lwt <> nil then
  begin
    Result.Lwt.Topic := JsonGetString(Lwt, 'topic', '');
    Result.Lwt.Payload := JsonGetString(Lwt, 'payload', '');
    Result.Lwt.Retain := JsonGetBool(Lwt, 'retain', True);
    Result.Lwt.Qos := JsonGetByte(Lwt, 'qos', 1);
  end;

  Birth := ObjGetObjectCI(M, 'birth');
  if Birth <> nil then
  begin
    Result.Birth.Topic := JsonGetString(Birth, 'topic', '');
    Result.Birth.Payload := JsonGetString(Birth, 'payload', '');
    Result.Birth.Retain := JsonGetBool(Birth, 'retain', True);
    Result.Birth.Qos := JsonGetByte(Birth, 'qos', 1);
  end;
end;

{ Reads bridge.json from disk, applies env overrides, validates required fields, returns TBridgeConfig.
  Root JSON object is freed before return. }
function LoadBridgeConfig(const Path: string): TBridgeConfig;
var
  Parser: TJSONParser;
  Stream: TFileStream;
  Data: TJSONData;
  Root, LogObj: TJSONObject;
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
    raise Exception.Create('bridge.json: root must be an object');
  end;
  Root := TJSONObject(Data);
  try
    ApplyBridgeEnvOverrides(Root);
    Result.Mqtt := LoadMqttSection(Root);
    if Result.Mqtt.Host = '' then
      raise Exception.Create('bridge.json: mqtt.host is required');

    LogObj := ObjGetObjectCI(Root, 'log');
    if LogObj <> nil then
    begin
      Result.LogLevel := LogLevelFromString(JsonGetString(LogObj, 'level', 'info'));
      Result.LogFormat := JsonGetString(LogObj, 'format', 'text');
    end
    else
    begin
      Result.LogLevel := llInfo;
      Result.LogFormat := 'text';
    end;
  finally
    Root.Free;
  end;
end;

end.
