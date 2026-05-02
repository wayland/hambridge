unit mqttpublisher;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils, Classes, mqtt, config, logger;

type
  THaMqttPublisher = class
  private
    FBridge: TBridgeConfig;
    FClient: TMQTTClient;
    FLastConnectAttempt: QWord;
    FConnectBackoffMs: Cardinal;
    procedure OnConnect(AClient: TMQTTClient);
    procedure OnDisconnect(AClient: TMQTTClient);
    procedure OnDebug(Txt: string);
  public
    constructor Create(const ABridge: TBridgeConfig);
    destructor Destroy; override;
    procedure TickReconnect;
    procedure ProcessSynchronize;
    function Connected: Boolean;
    procedure PublishJson(const Topic, Json: string);
    procedure ShutdownPublishLwt;
  end;

implementation

uses
  Math, openssl, opensslsockets;

constructor THaMqttPublisher.Create(const ABridge: TBridgeConfig);
begin
  inherited Create;
  FBridge := ABridge;
  FClient := TMQTTClient.Create(nil);
  FClient.OnConnect := @OnConnect;
  FClient.OnDisconnect := @OnDisconnect;
  FClient.OnDebug := @OnDebug;
  FLastConnectAttempt := 0;
  FConnectBackoffMs := 1000;
end;

destructor THaMqttPublisher.Destroy;
begin
  if FClient <> nil then
  begin
    FClient.OnConnect := nil;
    FClient.OnDisconnect := nil;
    FClient.OnDebug := nil;
    if FClient.Connected then
      FClient.Disconnect;
    FClient.Free;
  end;
  inherited Destroy;
end;

procedure THaMqttPublisher.OnDebug(Txt: string);
begin
  Log(llDebug, Txt);
end;

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
end;

procedure THaMqttPublisher.OnDisconnect(AClient: TMQTTClient);
begin
  Log(llWarn, 'mqtt: disconnected');
end;

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

procedure THaMqttPublisher.ProcessSynchronize;
begin
  CheckSynchronize(0);
end;

function THaMqttPublisher.Connected: Boolean;
begin
  Result := FClient.Connected;
end;

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
