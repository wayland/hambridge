unit viscamapping;

{
  Loads VISCA mapping YAML (device_mappings.visca): per-model topic → VISCA packets.
  v0.2.1: framed encoding (device byte + optional fixed middle hex + template slots + FF) with MQTT JSON
  and "variables" defaults; if template is absent/empty, bytes alone is the full middle (after device byte, before FF).
  v0.3.1: each template slot may be 1..8 wire bytes (JSON object with slot + width keys, or string = width 1);
  multi-byte values from MQTT: integer big-endian or JSON array of byte-sized numbers.
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
    function ResolveTemplateSlotBytes(const SlotName: string; Width: Integer; SlotDefaults,
      MqttPayload: TJSONObject): TBytes;
    function JsonValueToByte(Data: TJSONData): Integer;
    function TryMatchTopicDef(ModelObj: TJSONObject; const TopicPath: string; ViscaAddress: Byte; const Packet: TBytes;
      out PayloadJson: string): Boolean;
  public
    constructor Create(const MappingFilePath: string);
    destructor Destroy; override;
    function EncodeViscaCommand(const ModelName: string; ViscaAddress: Byte; const TopicPath: string;
      const MqttPayloadJson: string): TBytes;
    { Controller→camera packets (first byte $81..$87): match mapping for ModelName + inferred address. }
    function TryDecodeControllerPacket(const ModelName: string; const Packet: TBytes; out TopicPath, PayloadJson: string): Boolean;
    { Space-separated uppercase hex for logging / MQTT trace fields. }
    class function ViscaPacketToHex(const Packet: TBytes): string; static;
    procedure CollectTopicPathsLeafFirst(const ModelName: string; List: TStrings);
  end;

  TViscaMapping = TViscaCommandMapping;

implementation

uses
  jsonutil, Math, yamlmin;

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

function JsonIntFromObject(Obj: TJSONObject; const Key: string; Default: Integer): Integer;
var
  Data: TJSONData;
begin
  Result := Default;
  if Obj = nil then
    Exit;
  Data := ObjFindCI(Obj, Key);
  if Data = nil then
    Exit;
  if Data is TJSONNumber then
    Exit(Integer(TJSONNumber(Data).AsInt64));
  if Data is TJSONString then
    Exit(StrToIntDef(TJSONString(Data).AsString, Default));
end;

procedure ParseTemplateSlotEntry(Item: TJSONData; out SlotName: string; out Width: Integer; out Ok: Boolean);
var
  O: TJSONObject;
  W: Integer;
begin
  Ok := False;
  SlotName := '';
  Width := 1;
  if Item is TJSONString then
  begin
    SlotName := Trim(TJSONString(Item).AsString);
    Ok := SlotName <> '';
    Exit;
  end;
  if Item is TJSONObject then
  begin
    O := TJSONObject(Item);
    SlotName := Trim(JsonGetStringFromObject(O, 'slot', ''));
    if SlotName = '' then
      SlotName := Trim(JsonGetStringFromObject(O, 'name', ''));
    W := JsonIntFromObject(O, 'width', 0);
    if W <= 0 then
      W := JsonIntFromObject(O, 'bytes', 1);
    Width := Max(1, Min(8, W));
    Ok := SlotName <> '';
  end;
end;

procedure BeStoreUInt(v: QWord; Width: Integer; Dest: PByte);
var
  Shift: Integer;
  B: Integer;
begin
  for B := Width - 1 downto 0 do
  begin
    Shift := B * 8;
    Dest[Width - 1 - B] := Byte((v shr Shift) and $FF);
  end;
end;

function UIntFitsBeWidth(v: QWord; Width: Integer): Boolean;
var
  Bits: Integer;
begin
  if Width >= 8 then
    Exit(True);
  Bits := Width * 8;
  if Bits >= 64 then
    Exit(True);
  Result := v < (QWord(1) shl Bits);
end;

function TViscaCommandMapping.ResolveTemplateSlotBytes(const SlotName: string; Width: Integer; SlotDefaults,
  MqttPayload: TJSONObject): TBytes;
var
  Data: TJSONData;
  I: Integer;
  v: QWord;
  vi: Int64;
  Arr: TJSONArray;
begin
  SetLength(Result, 0);
  if Width < 1 then
    Exit;
  SetLength(Result, Width);
  Data := nil;
  if MqttPayload <> nil then
    Data := ObjFindCI(MqttPayload, SlotName);
  if Data = nil then
  begin
    if SlotDefaults <> nil then
      Data := ObjFindCI(SlotDefaults, SlotName);
  end;
  if Data = nil then
  begin
    SetLength(Result, 0);
    Exit;
  end;
  if Data is TJSONArray then
  begin
    Arr := TJSONArray(Data);
    if Arr.Count < Width then
    begin
      SetLength(Result, 0);
      Exit;
    end;
    for I := 0 to Width - 1 do
    begin
      if JsonValueToByte(Arr.Items[I]) < 0 then
      begin
        SetLength(Result, 0);
        Exit;
      end;
      Result[I] := Byte(JsonValueToByte(Arr.Items[I]));
    end;
    Exit;
  end;
  if Data is TJSONNumber then
  begin
    vi := TJSONNumber(Data).AsInt64;
    if vi < 0 then
    begin
      SetLength(Result, 0);
      Exit;
    end;
    v := QWord(vi);
    if not UIntFitsBeWidth(v, Width) then
    begin
      SetLength(Result, 0);
      Exit;
    end;
    BeStoreUInt(v, Width, @Result[0]);
    Exit;
  end;
  if Width = 1 then
  begin
    I := JsonValueToByte(Data);
    if I < 0 then
      SetLength(Result, 0)
    else
      Result[0] := Byte(I);
    Exit;
  end;
  SetLength(Result, 0);
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
  I, J, OutPos, TotalSlotBytes, SlotW: Integer;
  SlotName: string;
  Ok: Boolean;
  SlotBytes: TBytes;
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
    TotalSlotBytes := 0;
    for I := 0 to TemplateArray.Count - 1 do
    begin
      ParseTemplateSlotEntry(TemplateArray.Items[I], SlotName, SlotW, Ok);
      if not Ok then
      begin
        SetLength(Result, 0);
        Exit;
      end;
      Inc(TotalSlotBytes, SlotW);
    end;
    SetLength(Result, 1 + Length(FixedMiddle) + TotalSlotBytes + 1);
    Result[0] := DeviceByte;
    for I := 0 to High(FixedMiddle) do
      Result[1 + I] := FixedMiddle[I];
    OutPos := 1 + Length(FixedMiddle);
    for I := 0 to TemplateArray.Count - 1 do
    begin
      ParseTemplateSlotEntry(TemplateArray.Items[I], SlotName, SlotW, Ok);
      SlotBytes := ResolveTemplateSlotBytes(SlotName, SlotW, SlotDefaults, MqttPayload);
      if Length(SlotBytes) <> SlotW then
      begin
        SetLength(Result, 0);
        Exit;
      end;
      for J := 0 to SlotW - 1 do
      begin
        Result[OutPos] := SlotBytes[J];
        Inc(OutPos);
      end;
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
  Ext: string;
begin
  inherited Create;
  FModelDefinitionsRoot := nil;
  Ext := LowerCase(ExtractFileExt(MappingFilePath));
  if (Ext = '.yaml') or (Ext = '.yml') then
    Data := YamlFileToJsonData(MappingFilePath)
  else
  begin
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
  end;
  if not (Data is TJSONObject) then
  begin
    Data.Free;
    raise Exception.Create('VISCA mapping: root must be an object');
  end;
  Root := TJSONObject(Data);
  ModelsObj := ObjGetObjectCI(Root, 'models');
  if ModelsObj = nil then
  begin
    Root.Free;
    raise Exception.Create('VISCA mapping: missing "models" object');
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

class function TViscaCommandMapping.ViscaPacketToHex(const Packet: TBytes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Packet) do
  begin
    if I > 0 then
      Result := Result + ' ';
    Result := Result + UpperCase(IntToHex(Packet[I], 2));
  end;
end;

procedure TViscaCommandMapping.CollectTopicPathsLeafFirst(const ModelName: string; List: TStrings);
var
  M: TJSONObject;

  procedure AddKeysFromTopics(TopicsObj: TJSONObject);
  var
    MemberIndex: Integer;
  begin
    if TopicsObj = nil then
      Exit;
    for MemberIndex := 0 to TopicsObj.Count - 1 do
    begin
      if not (TopicsObj.Items[MemberIndex] is TJSONObject) then
        Continue;
      if List.IndexOf(TopicsObj.Names[MemberIndex]) < 0 then
        List.Add(TopicsObj.Names[MemberIndex]);
    end;
  end;

  procedure WalkChildThenInherited(M: TJSONObject);
  var
    ParentName: string;
    ParentModel: TJSONObject;
  begin
    if M = nil then
      Exit;
    AddKeysFromTopics(ObjGetObjectCI(M, 'topics'));
    ParentName := Trim(JsonGetStringFromObject(M, 'inherits', ''));
    if ParentName = '' then
      Exit;
    ParentModel := FindModelObjectByName(ParentName);
    WalkChildThenInherited(ParentModel);
  end;

begin
  List.Clear;
  M := FindModelObjectByName(ModelName);
  if M = nil then
    Exit;
  WalkChildThenInherited(M);
end;

function TViscaCommandMapping.TryMatchTopicDef(ModelObj: TJSONObject; const TopicPath: string; ViscaAddress: Byte;
  const Packet: TBytes; out PayloadJson: string): Boolean;
var
  TopicDef: TJSONObject;
  FixedMiddle: TBytes;
  TemplateArray: TJSONArray;
  ExpectedLen, I, SlotIndex, Off, TotalSlotBytes, SlotW: Integer;
  DeviceByte: Byte;
  SlotName: string;
  Ok: Boolean;
begin
  Result := False;
  PayloadJson := '';
  TopicDef := FindTopicDefinition(ModelObj, TopicPath);
  if TopicDef = nil then
    Exit;
  DeviceByte := Byte($80 + Min(Max(ViscaAddress, 1), 7));
  if (Length(Packet) < 3) or (Packet[0] <> DeviceByte) or (Packet[High(Packet)] <> $FF) then
    Exit;
  FixedMiddle := ParseHexSpaceSeparated(JsonGetStringFromObject(TopicDef, 'bytes', ''));
  if not (ObjFindCI(TopicDef, 'template') is TJSONArray) then
    TemplateArray := nil
  else
    TemplateArray := TJSONArray(ObjFindCI(TopicDef, 'template'));
  if (TemplateArray = nil) or (TemplateArray.Count = 0) then
  begin
    if Length(FixedMiddle) = 0 then
      Exit;
    ExpectedLen := 1 + Length(FixedMiddle) + 1;
    if Length(Packet) <> ExpectedLen then
      Exit;
    for I := 0 to High(FixedMiddle) do
      if Packet[1 + I] <> FixedMiddle[I] then
        Exit;
    PayloadJson := '{}';
    Result := True;
    Exit;
  end;
  TotalSlotBytes := 0;
  for SlotIndex := 0 to TemplateArray.Count - 1 do
  begin
    ParseTemplateSlotEntry(TemplateArray.Items[SlotIndex], SlotName, SlotW, Ok);
    if not Ok then
      Exit;
    Inc(TotalSlotBytes, SlotW);
  end;
  ExpectedLen := 1 + Length(FixedMiddle) + TotalSlotBytes + 1;
  if Length(Packet) <> ExpectedLen then
    Exit;
  for I := 0 to High(FixedMiddle) do
    if Packet[1 + I] <> FixedMiddle[I] then
      Exit;
  PayloadJson := '{';
  Off := 1 + Length(FixedMiddle);
  for SlotIndex := 0 to TemplateArray.Count - 1 do
  begin
    ParseTemplateSlotEntry(TemplateArray.Items[SlotIndex], SlotName, SlotW, Ok);
    if not Ok then
    begin
      PayloadJson := '';
      Exit;
    end;
    if SlotIndex > 0 then
      PayloadJson := PayloadJson + ',';
    if SlotW <= 0 then
    begin
      PayloadJson := '';
      Exit;
    end;
    if Off + SlotW > Length(Packet) - 1 then
    begin
      PayloadJson := '';
      Exit;
    end;
    if SlotW = 1 then
      PayloadJson := PayloadJson + '"' + SlotName + '":' + IntToStr(Packet[Off])
    else
    begin
      PayloadJson := PayloadJson + '"' + SlotName + '":[';
      for I := 0 to SlotW - 1 do
      begin
        if I > 0 then
          PayloadJson := PayloadJson + ',';
        PayloadJson := PayloadJson + IntToStr(Packet[Off + I]);
      end;
      PayloadJson := PayloadJson + ']';
    end;
    Inc(Off, SlotW);
  end;
  PayloadJson := PayloadJson + '}';
  Result := True;
end;

function TViscaCommandMapping.TryDecodeControllerPacket(const ModelName: string; const Packet: TBytes; out TopicPath,
  PayloadJson: string): Boolean;
var
  ModelObj: TJSONObject;
  Paths: TStringList;
  PathIndex: Integer;
  DevByte: Byte;
  Addr: Integer;
begin
  Result := False;
  TopicPath := '';
  PayloadJson := '';
  if (Length(Packet) < 3) or (Packet[High(Packet)] <> $FF) then
    Exit;
  DevByte := Packet[0];
  if (DevByte < $81) or (DevByte > $87) then
    Exit;
  Addr := DevByte - $80;
  ModelObj := FindModelObjectByName(ModelName);
  if ModelObj = nil then
    Exit;
  Paths := TStringList.Create;
  try
    CollectTopicPathsLeafFirst(ModelName, Paths);
    for PathIndex := 0 to Paths.Count - 1 do
    begin
      if TryMatchTopicDef(ModelObj, Paths[PathIndex], Byte(Addr), Packet, PayloadJson) then
      begin
        TopicPath := Paths[PathIndex];
        Exit(True);
      end;
    end;
  finally
    Paths.Free;
  end;
end;

end.
