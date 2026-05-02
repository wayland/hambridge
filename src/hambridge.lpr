program hambridge;

{$mode ObjFPC}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils, Classes, BaseUnix, Unix,
  config, devicesconfig, logger, evdevreader, mqttpublisher, mainloop;

const
  AppVersion = '0.1.0';

var
  GStop: Boolean = False;

procedure SigHandler(sig: longint); cdecl;
begin
  GStop := True;
end;

type
  TRun = class
    Mqtt: THaMqttPublisher;
    constructor Create(AM: THaMqttPublisher);
    procedure OnEvdev(Sender: TObject; const Topic, Json: string);
  end;

constructor TRun.Create(AM: THaMqttPublisher);
begin
  inherited Create;
  Mqtt := AM;
end;

procedure TRun.OnEvdev(Sender: TObject; const Topic, Json: string);
begin
  Mqtt.PublishJson(Topic, Json);
end;

procedure PrintHelp;
begin
  WriteLn('HaMBridge (Hardware-MQTT Bridge) ', AppVersion);
  WriteLn('Usage: hambridge [--config PATH] [--devices PATH]');
  WriteLn('See README.md and Visca-MQTT-bridge-Plan.md.');
end;

procedure InstallSignals;
begin
  FpSignal(SIGTERM, @SigHandler);
  FpSignal(SIGINT, @SigHandler);
end;

var
  BridgePath, DevPath: string;
  CliBridge, CliDev: string;
  I: Integer;
  B: TBridgeConfig;
  D: TDevicesConfig;
  Hub: TEvdevHub;
  Mqtt: THaMqttPublisher;
  Runner: TRun;
begin
  CliBridge := '';
  CliDev := '';
  I := 1;
  while I <= ParamCount do
  begin
    if ParamStr(I) = '--help' then
    begin
      PrintHelp;
      Halt(0);
    end
    else if ParamStr(I) = '--version' then
    begin
      WriteLn(AppVersion);
      Halt(0);
    end
    else if (ParamStr(I) = '--config') and (I < ParamCount) then
    begin
      Inc(I);
      CliBridge := ParamStr(I);
    end
    else if (ParamStr(I) = '--devices') and (I < ParamCount) then
    begin
      Inc(I);
      CliDev := ParamStr(I);
    end
    else
    begin
      WriteLn('Unknown argument: ', ParamStr(I));
      PrintHelp;
      Halt(2);
    end;
    Inc(I);
  end;

  BridgePath := FindBridgeConfigPath(CliBridge);
  if BridgePath = '' then
  begin
    WriteLn('No bridge.json found (use --config or BRIDGE_CONFIG or ./bridge.json or /etc/hambridge/bridge.json)');
    Halt(1);
  end;
  DevPath := FindDevicesConfigPath(CliDev);
  if DevPath = '' then
  begin
    WriteLn('No devices.json found');
    Halt(1);
  end;

  B := LoadBridgeConfig(BridgePath);
  LogInit(B.LogLevel);
  LogFmt(llInfo, 'Using bridge config %s', [BridgePath]);
  D := LoadDevicesConfig(DevPath);
  LogFmt(llInfo, 'Using devices config %s', [DevPath]);

  if not D.EvdevEnabled then
  begin
    Log(llError, 'devices.json: evdev.enabled must be true for v0.1');
    Halt(1);
  end;
  if Length(D.EvdevInputs) = 0 then
  begin
    Log(llError, 'devices.json: evdev.inputs must be non-empty when enabled');
    Halt(1);
  end;

  Mqtt := THaMqttPublisher.Create(B);
  Hub := TEvdevHub.Create;
  try
    Hub.AddFromConfig(D);
    Runner := TRun.Create(Mqtt);
    try
      InstallSignals;
      Log(llInfo, 'Starting main loop (Ctrl+C or SIGTERM to exit)');
      RunEvdevMqttLoop(Hub, Mqtt, Runner, @Runner.OnEvdev, GStop);
    finally
      Log(llInfo, 'Shutting down');
      Mqtt.ShutdownPublishLwt;
      Runner.Free;
    end;
  finally
    Hub.Free;
    Mqtt.Free;
  end;
end.
