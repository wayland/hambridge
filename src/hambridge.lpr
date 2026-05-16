program hambridge;

{
  HaMBridge v0.4.0: single hambridge.yaml (+ VISCA mapping YAML); optional evdev→MQTT; MQTT device/#→VISCA;
  serial VISCA RX; ACK/retry/commandAck; coalesce + state + redundant skip; reply decode + controller/<bus>/status.
}

{$mode ObjFPC}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils, Classes, BaseUnix, Unix,
  config, devicesconfig, logger, evdevreader, mqttpublisher, mainloop,
  viscamapping, commandrouter;

const
  AppVersion = '0.5.1';

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
  WriteLn('Usage: hambridge [--config PATH]');
  WriteLn('See README.md and docs/user/ConfigurationGuide.md.');
end;

procedure InstallSignals;
begin
  FpSignal(SIGTERM, @SigHandler);
  FpSignal(SIGINT, @SigHandler);
end;

var
  BridgePath, MapPath: string;
  CliBridge: string;
  I: Integer;
  B: TBridgeConfig;
  D: TDevicesConfig;
  Hub: TEvdevHub;
  Mqtt: THaMqttPublisher;
  Runner: TRun;
  VMap: TViscaMapping;
  Router: TCommandRouter;
  hasEvdev, hasVisca: Boolean;
begin
  CliBridge := '';
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
    else
    begin
      WriteLn('Unknown argument: ', ParamStr(I));
      PrintHelp;
      Halt(2);
    end;
    Inc(I);
  end;

  BridgePath := FindHambridgeConfigPath(CliBridge);
  if BridgePath = '' then
  begin
    WriteLn('No hambridge.yaml found. Use --config PATH, set BRIDGE_CONFIG, or install under ',
      '.local/etc/config/, /etc/hambridge/config/, or /etc/hambridge/ (see docs/user/ConfigurationGuide.md).');
    Halt(1);
  end;

  B := LoadBridgeConfig(BridgePath);
  LogInit(B.LogLevel);
  LogFmt(llInfo, 'Using config %s', [BridgePath]);
  D := LoadDevicesConfig(BridgePath);
  ValidateDevicesConfig(D);

  hasEvdev := D.EvdevEnabled and (Length(D.EvdevInputs) > 0);
  hasVisca := Length(D.ViscaDevices) > 0;
  if not hasEvdev and not hasVisca then
  begin
    Log(llError, 'hambridge.yaml: enable evdev with non-empty inputs, and/or configure buses+VISCA devices');
    Halt(1);
  end;

  Mqtt := THaMqttPublisher.Create(B);
  VMap := nil;
  Router := nil;
  if hasVisca then
  begin
    MapPath := DiscoverViscaMappingPath(BridgePath, D);
    if MapPath = '' then
    begin
      Log(llError, 'VISCA mapping not found (device_mappings.visca in hambridge.yaml, mappings/visca.yaml beside it, or BRIDGE_VISCA_MAPPING)');
      Halt(1);
    end;
    LogFmt(llInfo, 'Using VISCA mapping %s', [MapPath]);
    VMap := TViscaMapping.Create(MapPath);
    Router := TCommandRouter.Create(D, VMap, Mqtt);
    Mqtt.OnDeviceMessage := @Router.OnMqttDeviceMessage;
  end;
  Hub := TEvdevHub.Create;
  try
    if hasEvdev then
      Hub.AddFromConfig(D);
    Runner := TRun.Create(Mqtt);
    try
      InstallSignals;
      Log(llInfo, 'Starting main loop (Ctrl+C or SIGTERM to exit)');
      RunHaMBridgeLoop(Hub, Mqtt, Router, Runner, @Runner.OnEvdev, GStop);
    finally
      Log(llInfo, 'Shutting down');
      Mqtt.OnDeviceMessage := nil;
      Mqtt.ShutdownPublishLwt;
      Runner.Free;
    end;
  finally
    Router.Free;
    VMap.Free;
    Hub.Free;
    Mqtt.Free;
  end;
end.
