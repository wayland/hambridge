unit viscamapping;

{
  Loads visca-mapping.json (plan §3.3): per-model topic → VISCA packets.
  v0.2.1: framed encoding (device byte + optional fixed middle hex + template slots + FF) with MQTT JSON
  and "variables" defaults; if template is absent/empty, bytes alone is the full middle (after device byte, before FF).
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils, Classes, fpjson, jsonparser;

type
  TViscaCommandMapping = class
  private
    FModelDefinitionsRoot: TJSONObject;
    function FindModelObjectByName(const ModelName: string): TJSONObject;
    function FindTopicDefinition(M: TJSONObject; const TopicPath: string): TJSONObject;
    function ParseHexSpaceSeparated(const Hex: string): TBytes;
    function EncodeFixedMiddleOnlyPacket(TopicDef: TJSONObject; ViscaAddress: Byte): TBytes;
    function EncodeFramedPacket(TopicDef: TJSONObject; ViscaAddress: Byte; const MqttPayloadJson: string): TBytes;
    function ResolveTemplateSlotByte(const SlotName: string; SlotDefaults, MqttPayload: TJSONObject): Integer;
    function JsonValueToByte(Data: TJSONData): Integer;
  public
    constructor Create(const MappingFilePath: string);
    destructor Destroy; override;
    function EncodeViscaCommand(const ModelName: string; ViscaAddress: Byte; const TopicPath: string;
      const MqttPayloadJson: string): TBytes;
  end;

  TViscaMapping = TViscaCommandMapping;

implementation

uses
  jsonutil, Math;

function JsonGetStringFromObject(Obj: TJSONObject; const Key: string; const Default: string = ''): string;
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
  Result := Default;
end;

function TViscaCommandMapping.ParseHexSpaceSeparated(const Hex: string): TBytes;
var
  S: string;
  tok: string;
  c: Char;
  code: Integer;
  nextLen: Integer;
begin
  SetLength(Result, 0);
  S := Trim(Hex);
  if S = '' then
    Exit;
  tok := '';
  for c in S + ' ' do
  begin
    if c in [' ', #9, #10, #13] then
    begin
      if tok <> '' then
      begin
        if tok[1] = '$' then
          code := StrToIntDef(tok, -1)
        else
          code := StrToIntDef('$' + tok, -1);
        if (code < 0) or (code > 255) then
        begin
          SetLength(Result, 0);
          Exit;
        end;
        nextLen := Length(Result) + 1;
        SetLength(Result, nextLen);
        Result[nextLen - 1] := Byte(code);
        tok := '';
      end;
    end
    else
      tok := tok + c;
  end;
end;

function TViscaCommandMapping.JsonValueToByte(Data: TJSONData): Integer;
var
  S: string;
  v: Int64;
begin
  Result := -1;
  if Data = nil then
    Exit;
  if Data is TJSONNumber then
  begin
    v := TJSONNumber(Data).AsInt64;
    if (v < 0) or (v > 255) then
      Exit(-1);
    Exit(Integer(v));
  end;
  if Data is TJSONString then
  begin
    S := Trim(TJSONString(Data).AsString);
    if S = '' then
      Exit(-1);
    if S[1] = '$' then
      Result := StrToIntDef(S, -1)
    else
      Result := StrToIntDef('$' + S, -1);
    if (Result < 0) or (Result > 255) then
      Result := -1;
  end;
end;

function TViscaCommandMapping.ResolveTemplateSlotByte(const SlotName: string; SlotDefaults,
  MqttPayload: TJSONObject): Integer;
var
  Data: TJSONData;
begin
  Result := -1;
  if MqttPayload <> nil then
  begin
    Data := ObjFindCI(MqttPayload, SlotName);
    Result := JsonValueToByte(Data);
    if Result >= 0 then
      Exit;
  end;
  if SlotDefaults <> nil then
  begin
    Data := ObjFindCI(SlotDefaults, SlotName);
    Result := JsonValueToByte(Data);
  end;
end;

function TViscaCommandMapping.EncodeFramedPacket(TopicDef: TJSONObject; ViscaAddress: Byte;
  const MqttPayloadJson: string): TBytes;
var
  FixedMiddle: TBytes;
  TemplateArray: TJSONArray;
  SlotDefaults: TJSONObject;
  MqttPayload: TJSONObject;
  Parser: TJSONParser;
  PayloadData: TJSONData;
  I: Integer;
  SlotName: string;
  ByteVal: Integer;
  DeviceByte: Byte;
  Stream: TStringStream;
begin
  SetLength(Result, 0);
  MqttPayload := nil;
  PayloadData := nil;
  FixedMiddle := ParseHexSpaceSeparated(JsonGetStringFromObject(TopicDef, 'bytes', ''));
  TemplateArray := nil;
  if ObjFindCI(TopicDef, 'template') is TJSONArray then
    TemplateArray := TJSONArray(ObjFindCI(TopicDef, 'template'));
  if (TemplateArray = nil) or (TemplateArray.Count = 0) then
    Exit;
  SlotDefaults := ObjGetObjectCI(TopicDef, 'variables');
  if Trim(MqttPayloadJson) <> '' then
  begin
    Stream := TStringStream.Create(MqttPayloadJson);
    try
      Parser := TJSONParser.Create(Stream);
      try
        try
          PayloadData := Parser.Parse;
        except
          PayloadData := nil;
        end;
      finally
        Parser.Free;
      end;
    finally
      Stream.Free;
    end;
    if PayloadData is TJSONObject then
      MqttPayload := TJSONObject(PayloadData)
    else if PayloadData <> nil then
    begin
      PayloadData.Free;
      PayloadData := nil;
    end;
  end;
  try
    DeviceByte := Byte($80 + Min(Max(ViscaAddress, 1), 7));
    SetLength(Result, 1 + Length(FixedMiddle) + TemplateArray.Count + 1);
    Result[0] := DeviceByte;
    for I := 0 to High(FixedMiddle) do
      Result[1 + I] := FixedMiddle[I];
    for I := 0 to TemplateArray.Count - 1 do
    begin
      if not (TemplateArray.Items[I] is TJSONString) then
      begin
        SetLength(Result, 0);
        Exit;
      end;
      SlotName := Trim(TJSONString(TemplateArray.Items[I]).AsString);
      if SlotName = '' then
      begin
        SetLength(Result, 0);
        Exit;
      end;
      ByteVal := ResolveTemplateSlotByte(SlotName, SlotDefaults, MqttPayload);
      if ByteVal < 0 then
      begin
        SetLength(Result, 0);
        Exit;
      end;
      Result[1 + Length(FixedMiddle) + I] := Byte(ByteVal);
    end;
    Result[High(Result)] := $FF;
  finally
    if MqttPayload <> nil then
      MqttPayload.Free
    else if PayloadData <> nil then
      PayloadData.Free;
  end;
end;

function TViscaCommandMapping.EncodeFixedMiddleOnlyPacket(TopicDef: TJSONObject; ViscaAddress: Byte): TBytes;
var
  Middle: TBytes;
  DeviceByte: Byte;
  MiddleLen, OutIdx: Integer;
begin
  SetLength(Result, 0);
  Middle := ParseHexSpaceSeparated(JsonGetStringFromObject(TopicDef, 'bytes', ''));
  MiddleLen := Length(Middle);
  if MiddleLen = 0 then
    Exit;
  DeviceByte := Byte($80 + Min(Max(ViscaAddress, 1), 7));
  SetLength(Result, 1 + MiddleLen + 1);
  Result[0] := DeviceByte;
  for OutIdx := 0 to MiddleLen - 1 do
    Result[1 + OutIdx] := Middle[OutIdx];
  Result[High(Result)] := $FF;
end;

constructor TViscaCommandMapping.Create(const MappingFilePath: string);
var
  Parser: TJSONParser;
  FileStream: TFileStream;
  Data: TJSONData;
  Root: TJSONObject;
  ModelsObj: TJSONObject;
begin
  inherited Create;
  FModelDefinitionsRoot := nil;
  FileStream := TFileStream.Create(MappingFilePath, fmOpenRead or fmShareDenyWrite);
  try
    Parser := TJSONParser.Create(FileStream);
    try
      Data := Parser.Parse;
    finally
      Parser.Free;
    end;
  finally
    FileStream.Free;
  end;
  if not (Data is TJSONObject) then
  begin
    Data.Free;
    raise Exception.Create('visca-mapping.json: root must be an object');
  end;
  Root := TJSONObject(Data);
  ModelsObj := ObjGetObjectCI(Root, 'models');
  if ModelsObj = nil then
  begin
    Root.Free;
    raise Exception.Create('visca-mapping.json: missing "models" object');
  end;
  FModelDefinitionsRoot := TJSONObject(ModelsObj.Clone);
  Root.Free;
end;

destructor TViscaCommandMapping.Destroy;
begin
  FModelDefinitionsRoot.Free;
  inherited Destroy;
end;

function TViscaCommandMapping.FindModelObjectByName(const ModelName: string): TJSONObject;
begin
  Result := ObjGetObjectCI(FModelDefinitionsRoot, ModelName);
end;

function TopicKeyMatches(const JsonMemberName, TopicPath: string): Boolean;
begin
  Result := SameText(JsonMemberName, TopicPath);
end;

function TViscaCommandMapping.FindTopicDefinition(M: TJSONObject; const TopicPath: string): TJSONObject;
var
  TopicsObject: TJSONObject;
  MemberIndex: Integer;
  ParentModelName: string;
  BaseModel: TJSONObject;
begin
  Result := nil;
  if M = nil then
    Exit;
  TopicsObject := ObjGetObjectCI(M, 'topics');
  if TopicsObject <> nil then
  begin
    for MemberIndex := 0 to TopicsObject.Count - 1 do
    begin
      if not (TopicsObject.Items[MemberIndex] is TJSONObject) then
        Continue;
      if not TopicKeyMatches(TopicsObject.Names[MemberIndex], TopicPath) then
        Continue;
      Exit(TJSONObject(TopicsObject.Items[MemberIndex]));
    end;
  end;
  ParentModelName := JsonGetStringFromObject(M, 'inherits', '');
  if ParentModelName = '' then
    Exit;
  BaseModel := FindModelObjectByName(ParentModelName);
  Result := FindTopicDefinition(BaseModel, TopicPath);
end;

function TopicUsesNonEmptyTemplateArray(TopicDef: TJSONObject): Boolean;
var
  Arr: TJSONArray;
begin
  Result := False;
  if not (ObjFindCI(TopicDef, 'template') is TJSONArray) then
    Exit;
  Arr := TJSONArray(ObjFindCI(TopicDef, 'template'));
  Result := Arr.Count > 0;
end;

function TViscaCommandMapping.EncodeViscaCommand(const ModelName: string; ViscaAddress: Byte; const TopicPath: string;
  const MqttPayloadJson: string): TBytes;
var
  ModelObject: TJSONObject;
  TopicDefinition: TJSONObject;
begin
  SetLength(Result, 0);
  ModelObject := FindModelObjectByName(ModelName);
  TopicDefinition := FindTopicDefinition(ModelObject, TopicPath);
  if TopicDefinition = nil then
    Exit;
  if TopicUsesNonEmptyTemplateArray(TopicDefinition) then
    Result := EncodeFramedPacket(TopicDefinition, ViscaAddress, MqttPayloadJson)
  else
    Result := EncodeFixedMiddleOnlyPacket(TopicDefinition, ViscaAddress);
end;

end.
