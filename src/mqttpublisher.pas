unit mqttpublisher;

{
  Wraps prof7bit/fpc-mqtt-client TMQTTClient with hambridge.yaml bridge.mqtt settings: connect/reconnect backoff,
  optional TLS init, birth on connect, best-effort LWT publish on shutdown (see plan §3.0 notes).
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils, Classes, mqtt, config, logger, opensslsockets;

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
    FTlsInsecureWarned: Boolean;
    FTlsVersionWarned: Boolean;
    procedure OnConnect(AClient: TMQTTClient);
    procedure OnDisconnect(AClient: TMQTTClient);
    procedure OnDebug(Txt: string);
    procedure HandleMqttReceive(AClient: TMQTTClient; Msg: TMQTTRXData);
    procedure HaVerifySsl(AClient: TMQTTClient; ASSLHandler: TOpenSSLSocketHandler; var Allow: Boolean);
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
  Math, openssl, sslsockets;

{ Wires OnConnect/OnDisconnect/OnDebug and initial backoff state. }
constructor THaMqttPublisher.Create(const ABridge: TBridgeConfig);
begin
  inherited Create;
  FBridge := ABridge;
  FOnDeviceMessage := nil;
  FTlsInsecureWarned := False;
  FTlsVersionWarned := False;
  FClient := TMQTTClient.Create(nil);
  FClient.OnConnect := @OnConnect;
  FClient.OnDisconnect := @OnDisconnect;
  FClient.OnDebug := @OnDebug;
  FClient.OnReceive := @HandleMqttReceive;
  FClient.OnVerifySSL := @HaVerifySsl;
  FLastConnectAttempt := 0;
  FConnectBackoffMs := 1000;
  if FBridge.Mqtt.Tls.KeyReadableByOthers then
    Log(llWarn, 'mqtt tls: client private key is readable by group or others; restrict permissions (e.g. chmod 600)');
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
    FClient.OnVerifySSL := nil;
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

procedure THaMqttPublisher.HaVerifySsl(AClient: TMQTTClient; ASSLHandler: TOpenSSLSocketHandler; var Allow: Boolean);
var
  H: TSSLSocketHandler;
  HostNm: string;
begin
  Allow := True;
  if not FBridge.Mqtt.TlsOn then
    Exit;
  H := ASSLHandler;
  H.VerifyPeerCert := FBridge.Mqtt.Tls.VerifyPeer;
  if Trim(FBridge.Mqtt.Tls.CaFile) <> '' then
    H.CertificateData.TrustedCertificate.FileName := Trim(FBridge.Mqtt.Tls.CaFile);
  if (Trim(FBridge.Mqtt.Tls.CaPath) <> '') and (Trim(FBridge.Mqtt.Tls.CaFile) = '') then
    H.CertificateData.CertCA.FileName := Trim(FBridge.Mqtt.Tls.CaPath);
  HostNm := Trim(FBridge.Mqtt.Tls.ServerName);
  if HostNm = '' then
    HostNm := FBridge.Mqtt.Host;
  H.CertificateData.HostName := HostNm;
  H.SendHostAsSNI := True;
  if Trim(FBridge.Mqtt.Tls.Ciphers) <> '' then
    H.CertificateData.CipherList := Trim(FBridge.Mqtt.Tls.Ciphers);
  if (Trim(FBridge.Mqtt.Tls.MinVersion) <> '') or (Trim(FBridge.Mqtt.Tls.MaxVersion) <> '') then
  begin
    if not FTlsVersionWarned then
    begin
      FTlsVersionWarned := True;
      Log(llWarn, 'mqtt tls: minVersion/maxVersion are not enforced; use mqtt.tls.ciphers or OpenSSL defaults');
    end;
  end;
  if not FBridge.Mqtt.Tls.VerifyPeer then
  begin
    if not FTlsInsecureWarned then
    begin
      FTlsInsecureWarned := True;
      Log(llWarn, 'mqtt tls: verifyPeer is false — broker certificate will not be validated (insecure)');
    end;
  end;
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
  if FBridge.Mqtt.TlsOn then
  begin
{$ifndef windows}
    if not InitSSLInterface then
    begin
      openssl.DLLVersions[1] := '.3';
      InitSSLInterface;
    end;
{$endif}
  end;
  if FBridge.Mqtt.TlsOn then
  begin
    FClient.ClientCert := FBridge.Mqtt.Tls.ClientCertFile;
    FClient.ClientKey := FBridge.Mqtt.Tls.ClientKeyFile;
  end
  else
  begin
    FClient.ClientCert := '';
    FClient.ClientKey := '';
  end;
  user := FBridge.Mqtt.Username;
  pass := FBridge.Mqtt.Password;
  err := FClient.Connect(FBridge.Mqtt.Host, FBridge.Mqtt.Port, FBridge.Mqtt.ClientId, user, pass,
    FBridge.Mqtt.TlsOn, True);
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
