unit test_viscamapping;

{$mode ObjFPC}{$H+}

interface

uses
  fpcunit, testregistry;

implementation

uses
  SysUtils,
  viscamapping,
  fixturepaths;

type
  TTestViscaMapping = class(TTestCase)
  published
    procedure TestEncodePresetCall;
    procedure TestEncodePowerOn;
    procedure TestViscaPacketToHexSpacing;
    procedure TestDecodeControllerPowerOn;
  end;

procedure TTestViscaMapping.TestEncodePresetCall;
var
  M: TViscaMapping;
  B: TBytes;
begin
  M := TViscaMapping.Create(FixturePath('visca-min.yaml'));
  try
    B := M.EncodeViscaCommand('marshall-cv344', 1, 'preset/call', '{"presetIndex": 2}');
    AssertEquals('81 01 04 3F 02 02 FF', TViscaMapping.ViscaPacketToHex(B));
  finally
    M.Free;
  end;
end;

procedure TTestViscaMapping.TestEncodePowerOn;
var
  M: TViscaMapping;
  B: TBytes;
begin
  M := TViscaMapping.Create(FixturePath('visca-min.yaml'));
  try
    B := M.EncodeViscaCommand('marshall-cv344', 1, 'power/on', '{}');
    AssertEquals('81 01 04 00 02 FF', TViscaMapping.ViscaPacketToHex(B));
  finally
    M.Free;
  end;
end;

procedure TTestViscaMapping.TestViscaPacketToHexSpacing;
var
  B: TBytes;
begin
  SetLength(B, 2);
  B[0] := 0;
  B[1] := $FF;
  AssertEquals('00 FF', TViscaMapping.ViscaPacketToHex(B));
end;

procedure TTestViscaMapping.TestDecodeControllerPowerOn;
{
  Golden wire bytes: address 1 ($81), category 01 04 00, argument 02, terminator FF.
  Same framing as common Sony VISCA “power on” / standby patterns cited for UDP golden tests
  in Specification.md §10.4 (e.g. Bitfocus Companion Sony VISCA connection docs).
}
var
  M: TViscaMapping;
  Pkt: TBytes;
  Ok: Boolean;
  Topic, Payload: string;
begin
  SetLength(Pkt, 6);
  Pkt[0] := $81;
  Pkt[1] := $01;
  Pkt[2] := $04;
  Pkt[3] := $00;
  Pkt[4] := $02;
  Pkt[5] := $FF;
  M := TViscaMapping.Create(FixturePath('visca-min.yaml'));
  try
    Ok := M.TryDecodeControllerPacket('marshall-cv344', Pkt, Topic, Payload);
    AssertTrue(Ok);
    AssertEquals('power/on', Topic);
  finally
    M.Free;
  end;
end;

initialization
  RegisterTest(TTestViscaMapping);
end.
