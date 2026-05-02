unit mqttpublisher;

{
  Wraps prof7bit/fpc-mqtt-client TMQTTClient with bridge.json settings: connect/reconnect backoff,
  optional TLS init, birth on connect, best-effort LWT publish on shutdown (see plan §3.0 notes).
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils, Classes, mqtt, config, logger;

type
  THaMqttDeviceMessageEvent = procedure(Sender: TObject; const Topic, Payload: string) of object;

  { Application-facing MQTT facade: owns one TMQTTClient and bridges config + logging. }
  THaMqttPublisher = class
  private
    FBridge: TBridgeConfig;       { Snapshot from LoadBridgeConfig }
    FClient: TMQTTClient;          { Vendored MQTT v5 client instance }
    FLastConnectAttempt: QWord;    { GetTickCount64 of last Connect attempt }
    FConnectBackoffMs: Cardinal;   { Delay between retries; doubles on failure up to cap }
    FOnDeviceMessage: THaMqttDeviceMessageEvent;
    procedure OnConnect(AClient: TMQTTClient);
    procedure OnDisconnect(AClient: TMQTTClient);
    procedure OnDebug(Txt: string);
    procedure HandleMqttReceive(AClient: TMQTTClient; Msg: TMQTTRXData);
  public
    constructor Create(const ABridge: TBridgeConfig);
    destructor Destroy; override;
    { Call each loop iteration: attempts reconnect when disconnected (backoff). }
    procedure TickReconnect;
    { Must run in the same thread as the client object; drains library sync queue. }
    procedure ProcessSynchronize;
    function Connected: Boolean;
    procedure PublishJson(const Topic, Json: string);
    { Call on shutdown before Free: optional LWT publish + disconnect. }
    procedure ShutdownPublishLwt;
    property OnDeviceMessage: THaMqttDeviceMessageEvent read FOnDeviceMessage write FOnDeviceMessage;
  end;

implementation

uses
  Math, openssl, opensslsockets;

{ Wires OnConnect/OnDisconnect/OnDebug and initial backoff state. }
constructor THaMqttPublisher.Create(const ABridge: TBridgeConfig);
begin
  inherited Create;
  FBridge := ABridge;
  FOnDeviceMessage := nil;
  FClient := TMQTTClient.Create(nil);
  FClient.OnConnect := @OnConnect;
  FClient.OnDisconnect := @OnDisconnect;
  FClient.OnDebug := @OnDebug;
  FClient.OnReceive := @HandleMqttReceive;
  FLastConnectAttempt := 0;
  FConnectBackoffMs := 1000;
end;

destructor THaMqttPublisher.Destroy;
begin
  { Drop event handlers then disconnect so worker threads do not call into freed methods. }
  if FClient <> nil then
  begin
    FClient.OnConnect := nil;
    FClient.OnDisconnect := nil;
    FClient.OnDebug := nil;
    FClient.OnReceive := nil;
    if FClient.Connected then
      FClient.Disconnect;
    FClient.Free;
  end;
  inherited Destroy;
end;

procedure THaMqttPublisher.HandleMqttReceive(AClient: TMQTTClient; Msg: TMQTTRXData);
begin
  if Assigned(FOnDeviceMessage) then
    FOnDeviceMessage(Self, Msg.Topic, Msg.Message);
end;

{ Forwards client debug strings to our logger at debug level (signature matches TMQTTDebugFunc). }
procedure THaMqttPublisher.OnDebug(Txt: string);
begin
  Log(llDebug, Txt);
end;

{ Resets backoff and publishes birth message when broker session comes up. }
procedure THaMqttPublisher.OnConnect(AClient: TMQTTClient);
begin
  Log(llInfo, 'mqtt: connected');
  FConnectBackoffMs := 1000;
  if FBridge.Mqtt.Birth.Topic <> '' then
  begin
    if AClient.Publish(FBridge.Mqtt.Birth.Topic, FBridge.Mqtt.Birth.Payload, FBridge.Mqtt.Birth.Qos,
      FBridge.Mqtt.Birth.Retain) <> mqeNoError then
      Log(llWarn, 'mqtt: birth publish failed');
  end;
  if Assigned(FOnDeviceMessage) then
  begin
    if AClient.Subscribe('device/#', 0, 1) <> mqeNoError then
      Log(llWarn, 'mqtt: subscribe device/# failed');
  end;
end;

{ Broker closed the session or network failed; log only — TickReconnect will try again. }
procedure THaMqttPublisher.OnDisconnect(AClient: TMQTTClient);
begin
  Log(llWarn, 'mqtt: disconnected');
end;

{ Non-blocking reconnect: if disconnected and backoff elapsed, attempts Connect with optional TLS setup. }
procedure THaMqttPublisher.TickReconnect;
var
  err: TMQTTError;
  nowt: QWord;
  user, pass: string;
begin
  if FClient.Connected then
    Exit;
  nowt := GetTickCount64;
  if nowt < FLastConnectAttempt + FConnectBackoffMs then
    Exit;
  FLastConnectAttempt := nowt;
  if FBridge.Mqtt.Tls then
  begin
{$ifndef windows}
    if not InitSSLInterface then
    begin
      openssl.DLLVersions[1] := '.3';
      InitSSLInterface;
    end;
{$endif}
  end;
  user := FBridge.Mqtt.Username;
  pass := FBridge.Mqtt.Password;
  err := FClient.Connect(FBridge.Mqtt.Host, FBridge.Mqtt.Port, FBridge.Mqtt.ClientId, user, pass,
    FBridge.Mqtt.Tls, True);
  if err <> mqeNoError then
  begin
    LogFmt(llWarn, 'mqtt: connect failed (%d), retry in %u ms', [Ord(err), FConnectBackoffMs]);
    FConnectBackoffMs := Min(FConnectBackoffMs * 2, 60000);
  end;
end;

{ Drains the client's internal synchronize queue (required because fpc-mqtt-client uses threads). }
procedure THaMqttPublisher.ProcessSynchronize;
begin
  CheckSynchronize(0);
end;

{ Thin wrapper so main loop can skip work when the broker is down. }
function THaMqttPublisher.Connected: Boolean;
begin
  Result := FClient.Connected;
end;

{ Publishes one evdev JSON payload at QoS 0 / no retain when the broker link is up. }
procedure THaMqttPublisher.PublishJson(const Topic, Json: string);
var
  err: TMQTTError;
begin
  if not FClient.Connected then
    Exit;
  err := FClient.Publish(Topic, Json, 0, False);
  if err <> mqeNoError then
    LogFmt(llWarn, 'mqtt: publish failed (%d) topic %s', [Ord(err), Topic]);
end;

{ On SIGTERM path: publish configured LWT payload while still connected, then disconnect cleanly. }
procedure THaMqttPublisher.ShutdownPublishLwt;
begin
  if (FClient <> nil) and FClient.Connected and (FBridge.Mqtt.Lwt.Topic <> '') then
  begin
    FClient.Publish(FBridge.Mqtt.Lwt.Topic, FBridge.Mqtt.Lwt.Payload, FBridge.Mqtt.Lwt.Qos, FBridge.Mqtt.Lwt.Retain);
    CheckSynchronize(200);
  end;
  if (FClient <> nil) and FClient.Connected then
    FClient.Disconnect;
  CheckSynchronize(200);
end;

end.
