unit test_bridgeconfig;

{$mode ObjFPC}{$H+}

interface

uses
  fpcunit, testregistry;

implementation

uses
  SysUtils,
  config,
  fixturepaths;

type
  TTestBridgeConfig = class(TTestCase)
  published
    procedure TestTlsShorthandFalse;
    procedure TestTlsShorthandTrue;
    procedure TestTlsObjectMinimal;
    procedure TestTlsClientCertWithoutKey;
  end;

procedure TTestBridgeConfig.TestTlsShorthandFalse;
var
  B: TBridgeConfig;
begin
  B := LoadBridgeConfig(FixturePath('bridge-tls-shorthand-false.yaml'));
  AssertFalse(B.Mqtt.TlsOn);
end;

procedure TTestBridgeConfig.TestTlsShorthandTrue;
var
  B: TBridgeConfig;
begin
  B := LoadBridgeConfig(FixturePath('bridge-tls-shorthand-true.yaml'));
  AssertTrue(B.Mqtt.TlsOn);
  AssertTrue(B.Mqtt.Tls.VerifyPeer);
end;

procedure TTestBridgeConfig.TestTlsObjectMinimal;
var
  B: TBridgeConfig;
begin
  B := LoadBridgeConfig(FixturePath('bridge-tls-minimal-object.yaml'));
  AssertTrue(B.Mqtt.TlsOn);
  AssertTrue(B.Mqtt.Tls.VerifyPeer);
  AssertEquals('', B.Mqtt.Tls.CaFile);
end;

procedure TTestBridgeConfig.TestTlsClientCertWithoutKey;
begin
  try
    LoadBridgeConfig(FixturePath('bridge-tls-client-cert-no-key.yaml'));
    Fail('expected exception for clientCertFile without clientKeyFile');
  except
    on E: Exception do
      AssertTrue(Pos('clientCertFile', E.Message) > 0);
  end;
end;

initialization
  RegisterTest(TTestBridgeConfig);
end.
