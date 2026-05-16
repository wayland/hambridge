unit test_devicesconfig;

{$mode ObjFPC}{$H+}

interface

uses
  fpcunit, testregistry;

implementation

uses
  SysUtils,
  devicesconfig,
  fixturepaths;

type
  TTestDevicesConfig = class(TTestCase)
  published
    procedure TestValidSerialMinimal;
    procedure TestDuplicateDeviceSlug;
    procedure TestDuplicateUdpTriple;
    procedure TestUdpCrossBusReuse;
    procedure TestUdpMissingController;
    procedure TestDuplicateViscaControllers;
  end;

function ValidateFailsContaining(const YamlRel, Needle: string): Boolean;
var
  D: TDevicesConfig;
begin
  Result := False;
  try
    D := LoadDevicesConfig(FixturePath(YamlRel));
    ValidateDevicesConfig(D);
  except
    on E: Exception do
      Result := Pos(LowerCase(Needle), LowerCase(E.Message)) > 0;
  end;
end;

procedure TTestDevicesConfig.TestValidSerialMinimal;
var
  D: TDevicesConfig;
begin
  D := LoadDevicesConfig(FixturePath('valid-serial-only.yaml'));
  ValidateDevicesConfig(D);
  AssertEquals(1, Length(D.ViscaDevices));
  AssertEquals('cam_alpha', D.ViscaDevices[0].Slug);
  AssertEquals(1, Length(D.ViscaBuses));
  AssertEquals(0, Length(D.ViscaControllers));
end;

procedure TTestDevicesConfig.TestDuplicateDeviceSlug;
begin
  AssertTrue(ValidateFailsContaining('duplicate-device-slug.yaml', 'duplicate visca device slug'));
end;

procedure TTestDevicesConfig.TestDuplicateUdpTriple;
begin
  AssertTrue(ValidateFailsContaining('duplicate-udp-triple.yaml', 'duplicate udp device triple'));
end;

procedure TTestDevicesConfig.TestUdpCrossBusReuse;
begin
  AssertTrue(ValidateFailsContaining('udp-cross-bus-reuse.yaml', 'reused across buses'));
end;

procedure TTestDevicesConfig.TestUdpMissingController;
begin
  AssertTrue(ValidateFailsContaining('udp-missing-controller.yaml', 'exactly one controller'));
end;

procedure TTestDevicesConfig.TestDuplicateViscaControllers;
begin
  AssertTrue(ValidateFailsContaining('duplicate-visca-controllers.yaml', 'multiple visca controller'));
end;

initialization
  RegisterTest(TTestDevicesConfig);
end.
