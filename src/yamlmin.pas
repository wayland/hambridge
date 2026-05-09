unit yamlmin;

{
  Minimal YAML → fpjson for HaMBridge config and VISCA mapping files.
  Block mappings, block sequences (- item), inline flow maps/sequences, null, booleans,
  numbers, quoted strings, # comments (outside quotes).
  Replace with otYaml or full YAML when you need complete spec compliance.
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils, Classes, fpjson;

function YamlFileToJsonData(const FilePath: string): TJSONData;
function YamlTextToJsonData(const YamlText: string): TJSONData;

implementation

uses
  Math;

type
  TStackKind = (skObject, skArray);
  TStackFrame = record
    Indent: Integer;
    Kind: TStackKind;
    Obj: TJSONObject;
    Arr: TJSONArray;
  end;

  TStack = array of TStackFrame;

procedure ParseKeyValueLine(var Stack: TStack; D: Integer; const Content: string; LineNo: Integer); forward;

procedure StackPush(var S: TStack; const F: TStackFrame);
begin
  SetLength(S, Length(S) + 1);
  S[High(S)] := F;
end;

procedure StackPop(var S: TStack);
begin
  if Length(S) > 0 then
    SetLength(S, Length(S) - 1);
end;

function StackTop(var S: TStack): TStackFrame;
begin
  Result := S[High(S)];
end;

function StackLen(const S: TStack): Integer;
begin
  Result := Length(S);
end;

function StripLineComment(const Line: string): string;
var
  I, N: Integer;
  InSQuote, InDQuote: Boolean;
begin
  InSQuote := False;
  InDQuote := False;
  N := Length(Line);
  I := 1;
  while I <= N do
  begin
    if InDQuote then
    begin
      if (Line[I] = '\') and (I < N) then
        Inc(I, 2)
      else
      begin
        if Line[I] = '"' then
          InDQuote := False;
        Inc(I);
      end;
      Continue;
    end;
    if InSQuote then
    begin
      if Line[I] = '''' then
        InSQuote := False;
      Inc(I);
      Continue;
    end;
    case Line[I] of
      '''':
        InSQuote := True;
      '"':
        InDQuote := True;
      '#':
        Exit(Copy(Line, 1, I - 1));
    end;
    Inc(I);
  end;
  Result := Line;
end;

function LeadingSpaceCount(const S: string): Integer;
var
  I, N: Integer;
begin
  N := Length(S);
  I := 1;
  while (I <= N) and (S[I] in [' ', #9]) do
    Inc(I);
  Result := I - 1;
end;

function TrimFrom(const S: string; StartIdx: Integer): string;
begin
  Result := Copy(S, StartIdx, MaxInt);
end;

function ParseScalar(const Raw: string): TJSONData;
var
  T: string;
  F: Double;
  I64: Int64;
begin
  T := Trim(Raw);
  if (T = '') or SameText(T, 'null') or (T = '~') then
    Exit(TJSONNull.Create);
  if SameText(T, 'true') then
    Exit(TJSONBoolean.Create(True));
  if SameText(T, 'false') then
    Exit(TJSONBoolean.Create(False));
  if (Length(T) >= 2) and (T[1] = '"') and (T[Length(T)] = '"') then
    Exit(TJSONString.Create(Copy(T, 2, Length(T) - 2)));
  if (Length(T) >= 2) and (T[1] = '''') and (T[Length(T)] = '''') then
    Exit(TJSONString.Create(Copy(T, 2, Length(T) - 2)));
  if TryStrToInt64(T, I64) then
    Exit(TJSONInt64Number.Create(I64));
  if TryStrToFloat(T, F) then
    Exit(TJSONFloatNumber.Create(F));
  Result := TJSONString.Create(T);
end;

function ParseFlowSequence(const S: string; var Pos: Integer): TJSONArray; forward;
function ParseFlowMapping(const S: string; var Pos: Integer): TJSONObject; forward;

function ParseFlowValue(const S: string; var Pos: Integer): TJSONData;
var
  T: string;
  C: Char;
  P0: Integer;
begin
  while (Pos <= Length(S)) and (S[Pos] in [' ', #9]) do
    Inc(Pos);
  if Pos > Length(S) then
    Exit(TJSONNull.Create);
  C := S[Pos];
  if C = '{' then
    Exit(ParseFlowMapping(S, Pos));
  if C = '[' then
    Exit(ParseFlowSequence(S, Pos));
  P0 := Pos;
  if C = '"' then
  begin
    Inc(Pos);
    T := '';
    while (Pos <= Length(S)) and (S[Pos] <> '"') do
    begin
      if (S[Pos] = '\') and (Pos < Length(S)) then
      begin
        Inc(Pos);
        T := T + S[Pos];
      end
      else
        T := T + S[Pos];
      Inc(Pos);
    end;
    if Pos <= Length(S) then
      Inc(Pos);
    Exit(TJSONString.Create(T));
  end;
  if C = '''' then
  begin
    Inc(Pos);
    T := '';
    while (Pos <= Length(S)) and (S[Pos] <> '''') do
    begin
      T := T + S[Pos];
      Inc(Pos);
    end;
    if Pos <= Length(S) then
      Inc(Pos);
    Exit(TJSONString.Create(T));
  end;
  while (Pos <= Length(S)) and not (S[Pos] in [',', ']', '}', #9, ' ']) do
    Inc(Pos);
  T := Trim(Copy(S, P0, Pos - P0));
  Result := ParseScalar(T);
end;

function ParseFlowMapping(const S: string; var Pos: Integer): TJSONObject;
var
  Key: string;
  Depth: Integer;
  C: Char;
begin
  Result := TJSONObject.Create;
  try
    Inc(Pos);
    while True do
    begin
      while (Pos <= Length(S)) and (S[Pos] in [' ', #9, ',']) do
        Inc(Pos);
      if (Pos > Length(S)) or (S[Pos] = '}') then
      begin
        if Pos <= Length(S) then
          Inc(Pos);
        Break;
      end;
      Depth := 0;
      Key := '';
      while Pos <= Length(S) do
      begin
        C := S[Pos];
        if (Depth = 0) and (C = ':') then
          Break;
        if C = '{' then
          Inc(Depth)
        else if C = '}' then
          Dec(Depth);
        Key := Key + C;
        Inc(Pos);
      end;
      if Pos > Length(S) then
        raise Exception.Create('yaml: unterminated flow map');
      Inc(Pos);
      Key := Trim(Key);
      Result.Add(Key, ParseFlowValue(S, Pos));
    end;
  except
    Result.Free;
    raise;
  end;
end;

function ParseFlowSequence(const S: string; var Pos: Integer): TJSONArray;
begin
  Result := TJSONArray.Create;
  try
    Inc(Pos);
    while True do
    begin
      while (Pos <= Length(S)) and (S[Pos] in [' ', #9, ',']) do
        Inc(Pos);
      if (Pos > Length(S)) or (S[Pos] = ']') then
      begin
        if Pos <= Length(S) then
          Inc(Pos);
        Break;
      end;
      Result.Add(ParseFlowValue(S, Pos));
    end;
  except
    Result.Free;
    raise;
  end;
end;

function IsArrayKey(const Key: string): Boolean;
begin
  Result := SameText(Key, 'devices') or SameText(Key, 'inputs') or SameText(Key, 'endpoints');
end;

procedure ParseDashLine(var Stack: TStack; D: Integer; const AfterDash: string; LineNo: Integer);
var
  Top: TStackFrame;
  ItemObj: TJSONObject;
  Tail: string;
  Fr: TStackFrame;
begin
  while (StackLen(Stack) > 1) and (StackTop(Stack).Indent >= D) do
    StackPop(Stack);
  Top := StackTop(Stack);
  if Top.Kind <> skArray then
    raise Exception.CreateFmt('yaml:%d: sequence item outside array', [LineNo]);

  Tail := Trim(AfterDash);
  ItemObj := TJSONObject.Create;
  Top.Arr.Add(ItemObj);
  Fr.Indent := D;
  Fr.Kind := skObject;
  Fr.Obj := ItemObj;
  Fr.Arr := nil;
  StackPush(Stack, Fr);

  if Tail = '' then
    Exit;
  if Pos(':', Tail) > 0 then
    ParseKeyValueLine(Stack, D + 2, Tail, LineNo);
end;

procedure ParseKeyValueLine(var Stack: TStack; D: Integer; const Content: string; LineNo: Integer);
var
  ColonPos: Integer;
  Key, Rest: string;
  Top: TStackFrame;
  NewObj: TJSONObject;
  NewArr: TJSONArray;
  P: Integer;
  FlowVal: TJSONData;
  Fr: TStackFrame;
begin
  ColonPos := Pos(':', Content);
  if ColonPos < 1 then
    raise Exception.CreateFmt('yaml:%d: expected key: value', [LineNo]);
  Key := Trim(Copy(Content, 1, ColonPos - 1));
  Rest := Trim(Copy(Content, ColonPos + 1, MaxInt));
  if Key = '' then
    raise Exception.CreateFmt('yaml:%d: empty key', [LineNo]);

  while (StackLen(Stack) > 1) and (StackTop(Stack).Indent >= D) do
    StackPop(Stack);
  Top := StackTop(Stack);
  if Top.Kind <> skObject then
    raise Exception.CreateFmt('yaml:%d: mapping in non-object context', [LineNo]);

  if Rest = '' then
  begin
    if IsArrayKey(Key) then
    begin
      NewArr := TJSONArray.Create;
      Top.Obj.Add(Key, NewArr);
      Fr.Indent := D;
      Fr.Kind := skArray;
      Fr.Obj := nil;
      Fr.Arr := NewArr;
      StackPush(Stack, Fr);
    end
    else
    begin
      NewObj := TJSONObject.Create;
      Top.Obj.Add(Key, NewObj);
      Fr.Indent := D;
      Fr.Kind := skObject;
      Fr.Obj := NewObj;
      Fr.Arr := nil;
      StackPush(Stack, Fr);
    end;
    Exit;
  end;

  if (Rest[1] = '{') or (Rest[1] = '[') then
  begin
    P := 1;
    if Rest[1] = '{' then
      FlowVal := ParseFlowMapping(Rest, P)
    else
      FlowVal := ParseFlowSequence(Rest, P);
    Top.Obj.Add(Key, FlowVal);
    Exit;
  end;

  Top.Obj.Add(Key, ParseScalar(Rest));
end;

function YamlTextToJsonData(const YamlText: string): TJSONData;
var
  Lines: TStringList;
  I, D, LineNo, ColonPos: Integer;
  Line, Stripped, Content: string;
  Root: TJSONObject;
  Stack: TStack;
  RootFrame: TStackFrame;
begin
  Root := TJSONObject.Create;
  SetLength(Stack, 0);
  FillChar(RootFrame, SizeOf(RootFrame), 0);
  RootFrame.Indent := -1;
  RootFrame.Kind := skObject;
  RootFrame.Obj := Root;
  RootFrame.Arr := nil;
  StackPush(Stack, RootFrame);

  Lines := TStringList.Create;
  try
    Lines.Text := YamlText;
    for I := 0 to Lines.Count - 1 do
    begin
      LineNo := I + 1;
      Line := Lines[I];
      Stripped := StripLineComment(Line);
      D := LeadingSpaceCount(Stripped);
      Content := TrimFrom(Stripped, D + 1);
      if Trim(Content) = '' then
        Continue;

      if (Length(Content) >= 1) and (Content[1] = '-') then
      begin
        if (Length(Content) < 2) or not (Content[2] in [' ', #9]) then
          raise Exception.CreateFmt('yaml:%d: malformed sequence', [LineNo]);
        ParseDashLine(Stack, D, Trim(Copy(Content, 2, MaxInt)), LineNo);
        Continue;
      end;

      ColonPos := Pos(':', Content);
      if ColonPos < 1 then
        raise Exception.CreateFmt('yaml:%d: expected ":" in mapping', [LineNo]);
      ParseKeyValueLine(Stack, D, Content, LineNo);
    end;
  finally
    Lines.Free;
  end;

  Result := Root;
end;

function YamlFileToJsonData(const FilePath: string): TJSONData;
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(FilePath);
    Result := YamlTextToJsonData(SL.Text);
  finally
    SL.Free;
  end;
end;

end.
