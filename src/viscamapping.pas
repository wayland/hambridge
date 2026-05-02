unit viscamapping;

{
  Loads visca-mapping.json (plan §3.3): per-model topic paths → static VISCA hex frames,
  with optional single-level "inherits" merge for topic lookup.
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils, Classes, fpjson, jsonparser;

type
  TViscaMapping = class
  private
    FModels: TJSONObject;
    function ModelByName(const ModelName: string): TJSONObject;
    function TopicBytesFromModel(M: TJSONObject; const TopicPath: string): string;
  public
    constructor Create(const Path: string);
    destructor Destroy; override;
    { Returns VISCA packet bytes; empty if unknown model/topic. Applies address to first $81..$87. }
    function EncodeCommand(const ModelName: string; ViscaAddress: Byte; const TopicPath: string): TBytes;
  end;

implementation

uses
  jsonutil, Math;

function JsonGetStringObj(Obj: TJSONObject; const Key: string; const Default: string = ''): string;
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

function HexStringToBytes(const Hex: string; ViscaAddress: Byte): TBytes;
var
  S: string;
  tok: string;
  v: Integer;
  c: Char;
  code: Integer;
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
        v := Length(Result);
        SetLength(Result, v + 1);
        Result[v] := Byte(code);
        tok := '';
      end;
    end
    else
      tok := tok + c;
  end;
  if (Length(Result) > 0) and (Result[0] >= $81) and (Result[0] <= $87) then
    Result[0] := Byte($80 + Min(Max(ViscaAddress, 1), 7));
end;

constructor TViscaMapping.Create(const Path: string);
var
  Parser: TJSONParser;
  Stream: TFileStream;
  Data: TJSONData;
  Root: TJSONObject;
begin
  inherited Create;
  FModels := nil;
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
    raise Exception.Create('visca-mapping.json: root must be an object');
  end;
  Root := TJSONObject(Data);
  if ObjGetObjectCI(Root, 'models') = nil then
  begin
    Root.Free;
    raise Exception.Create('visca-mapping.json: missing "models" object');
  end;
  FModels := TJSONObject(ObjGetObjectCI(Root, 'models').Clone);
  Root.Free;
end;

destructor TViscaMapping.Destroy;
begin
  FModels.Free;
  inherited Destroy;
end;

function TViscaMapping.ModelByName(const ModelName: string): TJSONObject;
begin
  Result := ObjGetObjectCI(FModels, ModelName);
end;

function TopicKeyMatch(const AName, TopicPath: string): Boolean;
begin
  Result := SameText(AName, TopicPath);
end;

function TViscaMapping.TopicBytesFromModel(M: TJSONObject; const TopicPath: string): string;
var
  Topics: TJSONObject;
  I: Integer;
  Child: TJSONObject;
  Hex: string;
  inh: string;
  Base: TJSONObject;
begin
  Result := '';
  if M = nil then
    Exit;
  Topics := ObjGetObjectCI(M, 'topics');
  if Topics <> nil then
  begin
    for I := 0 to Topics.Count - 1 do
    begin
      if not (Topics.Items[I] is TJSONObject) then
        Continue;
      if not TopicKeyMatch(Topics.Names[I], TopicPath) then
        Continue;
      Child := TJSONObject(Topics.Items[I]);
      Hex := JsonGetStringObj(Child, 'bytes', '');
      if Hex <> '' then
        Exit(Hex);
    end;
  end;
  inh := JsonGetStringObj(M, 'inherits', '');
  if inh = '' then
    Exit;
  Base := ModelByName(inh);
  Result := TopicBytesFromModel(Base, TopicPath);
end;

function TViscaMapping.EncodeCommand(const ModelName: string; ViscaAddress: Byte; const TopicPath: string): TBytes;
var
  M: TJSONObject;
  Hex: string;
begin
  SetLength(Result, 0);
  M := ModelByName(ModelName);
  Hex := TopicBytesFromModel(M, TopicPath);
  if Hex = '' then
    Exit;
  Result := HexStringToBytes(Hex, ViscaAddress);
end;

end.
