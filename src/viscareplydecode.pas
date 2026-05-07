unit viscareplydecode;

{
  v0.3.3: structured decode for device-origin VISCA frames (90..96) beyond kind + hex.
  Builds a JSON object suitable for telemetry/status "decode" field (not model-specific inquiry tables).
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils;

{ Returns empty string, or a JSON object for the telemetry decode field (no extra nesting). }
function TryDeviceReplyDecodeJson(const Frame: TBytes; const Kind: string): string;

implementation

function ByteRangeJsonArray(const Frame: TBytes; StartIdx, EndIdx: Integer): string;
var
  I: Integer;
begin
  Result := '[';
  for I := StartIdx to EndIdx do
  begin
    if I > StartIdx then
      Result := Result + ',';
    Result := Result + IntToStr(Frame[I]);
  end;
  Result := Result + ']';
end;

function TryDeviceReplyDecodeJson(const Frame: TBytes; const Kind: string): string;
var
  N, Socket, PayStart, PayEnd: Integer;
begin
  Result := '';
  N := Length(Frame);
  if N < 2 then
    Exit;
  if Frame[N - 1] <> $FF then
    Exit;

  if SameText(Kind, 'ack') then
  begin
    Socket := Frame[1] and $0F;
    Exit(Format('{"replyClass":"ack","socket":%d}', [Socket]));
  end;

  if SameText(Kind, 'completion') then
  begin
    Socket := Frame[1] and $0F;
    PayStart := 2;
    PayEnd := N - 2;
    if PayEnd >= PayStart then
      Exit(Format('{"replyClass":"completion","socket":%d,"payload":%s}', [Socket, ByteRangeJsonArray(Frame, PayStart, PayEnd)]))
    else
      Exit(Format('{"replyClass":"completion","socket":%d}', [Socket]));
  end;

  if SameText(Kind, 'error') then
  begin
    if N >= 3 then
      Exit(Format('{"replyClass":"error","code":%d}', [Frame[2]]))
    else
      Exit('{"replyClass":"error"}');
  end;

  if SameText(Kind, 'data') then
  begin
    PayStart := 2;
    PayEnd := N - 2;
    if PayEnd >= PayStart then
      Exit(Format('{"replyClass":"data","payload":%s}', [ByteRangeJsonArray(Frame, PayStart, PayEnd)]));
  end;

  PayStart := 1;
  PayEnd := N - 2;
  if PayEnd >= PayStart then
    Exit(Format('{"replyClass":"other","bytes":%s}', [ByteRangeJsonArray(Frame, PayStart, PayEnd)]));
end;

end.
