unit commandrouter;

{
  MQTT device/# → VISCA bytes via VISCA mapping YAML, per-bus queue and inter-command spacing.
  v0.2.1: queued commands carry MQTT JSON for framed template encoding.
  v0.3: serial RX (VISCA frames to FF), decode controller packets → controller/<bus>/event,
        device replies → device/<slug>/telemetry and status snapshot on controller/reply.
  v0.3.1: ACK wait + retry (scheduler), TX queue + pump, serial reopen, MQTT device/<slug>/commandAck,
        optional per-bus rs485 ioctl from hambridge.yaml transport_configuration.
  v0.3.2: scheduler.coalesce queue drops, last-wire skip for redundant VISCA, state snapshot on status.
  v0.3.3: device reply decode on telemetry/status; controller/<bus>/status bus snapshot.
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils, Classes, ctypes,
  devicesconfig, viscamapping, serialport, udpport, logger, mqttpublisher, viscareplydecode;

const
  MaxViscaRxAccum = 512;

type
  TBusTxPhase = (btpIdle, btpDrainingTx, btpWaitReply, btpBackoffRetry);

  TPathLastWire = record
    CmdPath: string;
    Wire: TBytes;
    Valid: Boolean;
  end;

  TDeviceStateSnap = record
    PanJson: string;
    TiltJson: string;
    ZoomJson: string;
    PresetJson: string;
  end;

  TQueuedViscaCommand = class
    DeviceConfigIndex: Integer;
    SerialBusIndex: Integer;
    MqttTopic: string;
    ViscaCommandPath: string;
    MqttPayloadJson: string;
  end;

  TCommandRouter = class
  private
    FDeviceConfiguration: TDevicesConfig;
    FViscaCommandMapping: TViscaMapping;
    FMqtt: THaMqttPublisher;
    FSerialPorts: array of TSerialPort; { nil for udp buses }
    FUdpPorts: array of TUdpViscaPort;  { nil for serial buses }
    FCommandQueuesPerBus: array of TFPList; { per VISCA bus }
    FLastTransmitTickPerBus: array of QWord;
    FInterCommandGapMsPerBus: array of Cardinal;
    FMaxQueueDepthPerBus: array of Cardinal;
    FRxAccumPerBus: array of TBytes;
    FLastControllerJson: array of string;
    FLastReplyJson: array of string;
    FBusTxPhase: array of TBusTxPhase;
    FInFlightWaitStartTick: array of QWord;
    FInFlightAckTimeoutMs: array of Cardinal;
    FInFlightSendCount: array of Integer;
    FInFlightPacket: array of TBytes;
    FInFlightUdpHost: array of string;
    FInFlightUdpPort: array of Integer;
    FRetryResumeTick: array of QWord;
    FPathWireCache: array of array of TPathLastWire;
    FStateSnap: array of TDeviceStateSnap;
    FLastBusCtrlEventJson: array of string;
    FLastBusDeviceReplyJson: array of string;
    FControllerTopicPerBus: array of string; { controller topic slug per bus (fallback bus id) }
    function UdpRemoteAllowed(BusIndex: Integer; const RemoteHost: string): Boolean;
    function IndexOfViscaBusById(const BusId: string): Integer;
    function IndexOfViscaDeviceByTopicSlug(const TopicSlug: string): Integer;
    function IndexOfViscaDeviceOnBusByReplyByte(BusIndex: Integer; ReplyFirst: Byte): Integer;
    function IndexOfUdpDeviceOnBusByRemoteAndId(BusIndex: Integer; const RemoteHost: string; RemotePort: Integer; DeviceID: Integer): Integer;
    function ControllerTopicSlugForBusIndex(BusIndex: Integer): string;
    procedure TrimOldestCommandsIfQueueExceedsDepth(SerialBusIndex, DeviceConfigIndex: Integer; MaxDepth: Cardinal);
    procedure DrainSerialIncoming(BusIndex: Integer);
    procedure DrainUdpIncoming(BusIndex: Integer);
    procedure ConsumeLeadingBytes(var Buf: TBytes; Count: Integer);
    procedure HandleCompleteViscaFrame(BusIndex: Integer; const Frame: TBytes; const RemoteHost: string = ''; RemotePort: Integer = 0);
    procedure PublishControllerSemantic(const BusId, ControllerSlug: string; const DeviceSlugOrEmpty: string;
      const CommandPath, PayloadJson, HexTrace: string; const RemoteHost: string = ''; RemotePort: Integer = 0);
    procedure PublishControllerRawEvent(const BusId, ControllerSlug, HexTrace: string; const RemoteHost: string = ''; RemotePort: Integer = 0);
    procedure PublishDeviceTelemetry(const DeviceSlug, Kind, HexTrace: string; const DecodeJsonObject: string = '');
    procedure PublishControllerBusSnapshot(BusIndex: Integer);
    procedure PublishDeviceStatusMerge(const DeviceSlug: string; DevIdx: Integer);
    procedure PublishDeviceCommandAck(const DeviceSlug, MqttTopic, CmdPath: string; Ok: Boolean;
      const Reason: string; Attempts: Integer; const ViscaKind, ViscaHex: string);
    procedure PopQueueHead(SerialBusIndex: Integer);
    procedure AbortInFlight(SerialBusIndex: Integer; const Reason: string);
    procedure TryFinalizeInFlightFromReply(SerialBusIndex, DevIdx: Integer; const Kind, HexStr: string);
    procedure OnDrainingComplete(SerialBusIndex: Integer; NowTick: QWord);
    procedure OnAckTimeout(SerialBusIndex: Integer; NowTick: QWord);
    procedure MaybeStartHeadCommand(SerialBusIndex: Integer; NowTick: QWord);
    procedure AdvanceBusTransmission(SerialBusIndex: Integer; NowTick: QWord);
    function FirstPathSegment(const Path: string): string;
    function CoalesceGroupKey(DeviceIndex: Integer; const Path: string): string;
    procedure RemoveQueuedCoalesced(SerialBusIndex, DeviceIndex: Integer; const GroupKey: string);
    function ViscaBytesEqual(const A, B: TBytes): Boolean;
    function PathWireCacheIndex(DevIdx: Integer; const CmdPath: string): Integer;
    procedure PathWireCacheUpsert(DevIdx: Integer; const CmdPath: string; const Wire: TBytes);
    function PathWireCacheMatches(DevIdx: Integer; const CmdPath: string; const Wire: TBytes): Boolean;
    procedure RememberBridgeWireAndState(DevIdx: Integer; const CmdPath, PayloadJson: string; const Wire: TBytes);
    procedure StateSnapFromPathPayload(DevIdx: Integer; const CmdPath, PayloadJson: string);
    function BuildStateJsonFragment(DevIdx: Integer): string;
    function JsonQuote(const s: string): string;
  public
    constructor Create(const DeviceConfiguration: TDevicesConfig; ViscaCommandMapping: TViscaMapping;
      AMqtt: THaMqttPublisher);
    destructor Destroy; override;
    procedure OnMqttDeviceMessage(Sender: TObject; const Topic, Payload: string);
    procedure Tick;
  end;

implementation

uses
  Math, StrUtils, DateUtils;

const
  MaxPathWireCachePerDevice = 48;

function TCommandRouter.FirstPathSegment(const Path: string): string;
var
  P: Integer;
begin
  P := Pos('/', Path);
  if P <= 0 then
    Result := Path
  else
    Result := Copy(Path, 1, P - 1);
end;

function TCommandRouter.CoalesceGroupKey(DeviceIndex: Integer; const Path: string): string;
var
  fs: string;
  k: Integer;
  Row: TViscaDeviceConfig;
begin
  Result := '';
  if (DeviceIndex < 0) or (DeviceIndex > High(FDeviceConfiguration.ViscaDevices)) then
    Exit;
  Row := FDeviceConfiguration.ViscaDevices[DeviceIndex];
  fs := FirstPathSegment(Path);
  if fs = '' then
    Exit;
  for k := 0 to High(Row.CoalescePaths) do
  begin
    if SameText(fs, Trim(Row.CoalescePaths[k])) then
      Exit(fs);
  end;
end;

procedure TCommandRouter.RemoveQueuedCoalesced(SerialBusIndex, DeviceIndex: Integer; const GroupKey: string);
var
  Q: TFPList;
  I: Integer;
  Qc: TQueuedViscaCommand;
begin
  if GroupKey = '' then
    Exit;
  Q := FCommandQueuesPerBus[SerialBusIndex];
  for I := Q.Count - 1 downto 0 do
  begin
    Qc := TQueuedViscaCommand(Q[I]);
    if Qc.DeviceConfigIndex <> DeviceIndex then
      Continue;
    if not SameText(CoalesceGroupKey(Qc.DeviceConfigIndex, Qc.ViscaCommandPath), GroupKey) then
      Continue;
    if (I = 0) and (FBusTxPhase[SerialBusIndex] <> btpIdle) then
      Continue;
    Q.Delete(I);
    Qc.Free;
  end;
end;

function TCommandRouter.ViscaBytesEqual(const A, B: TBytes): Boolean;
var
  n, I: Integer;
begin
  n := Length(A);
  if Length(B) <> n then
    Exit(False);
  for I := 0 to n - 1 do
    if A[I] <> B[I] then
      Exit(False);
  Result := True;
end;

function TCommandRouter.PathWireCacheIndex(DevIdx: Integer; const CmdPath: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  if (DevIdx < 0) or (DevIdx > High(FPathWireCache)) then
    Exit;
  for I := 0 to High(FPathWireCache[DevIdx]) do
    if SameText(FPathWireCache[DevIdx][I].CmdPath, CmdPath) then
      Exit(I);
end;

procedure TCommandRouter.PathWireCacheUpsert(DevIdx: Integer; const CmdPath: string; const Wire: TBytes);
var
  I, J: Integer;
begin
  if (DevIdx < 0) or (DevIdx > High(FPathWireCache)) or (CmdPath = '') then
    Exit;
  I := PathWireCacheIndex(DevIdx, CmdPath);
  if I >= 0 then
  begin
    FPathWireCache[DevIdx][I].Wire := Copy(Wire, 0, Length(Wire));
    FPathWireCache[DevIdx][I].Valid := Length(Wire) > 0;
    Exit;
  end;
  while Length(FPathWireCache[DevIdx]) >= MaxPathWireCachePerDevice do
  begin
    for J := 0 to High(FPathWireCache[DevIdx]) - 1 do
      FPathWireCache[DevIdx][J] := FPathWireCache[DevIdx][J + 1];
    SetLength(FPathWireCache[DevIdx], High(FPathWireCache[DevIdx]));
  end;
  SetLength(FPathWireCache[DevIdx], Length(FPathWireCache[DevIdx]) + 1);
  I := High(FPathWireCache[DevIdx]);
  FPathWireCache[DevIdx][I].CmdPath := CmdPath;
  FPathWireCache[DevIdx][I].Wire := Copy(Wire, 0, Length(Wire));
  FPathWireCache[DevIdx][I].Valid := Length(Wire) > 0;
end;

function TCommandRouter.PathWireCacheMatches(DevIdx: Integer; const CmdPath: string; const Wire: TBytes): Boolean;
var
  I: Integer;
begin
  Result := False;
  I := PathWireCacheIndex(DevIdx, CmdPath);
  if I < 0 then
    Exit;
  if not FPathWireCache[DevIdx][I].Valid then
    Exit;
  Result := ViscaBytesEqual(FPathWireCache[DevIdx][I].Wire, Wire);
end;

procedure TCommandRouter.StateSnapFromPathPayload(DevIdx: Integer; const CmdPath, PayloadJson: string);
var
  seg: string;
begin
  if (DevIdx < 0) or (DevIdx > High(FStateSnap)) then
    Exit;
  seg := FirstPathSegment(CmdPath);
  if SameText(seg, 'pan') then
    FStateSnap[DevIdx].PanJson := PayloadJson
  else if SameText(seg, 'tilt') then
    FStateSnap[DevIdx].TiltJson := PayloadJson
  else if SameText(seg, 'zoom') then
    FStateSnap[DevIdx].ZoomJson := PayloadJson
  else if SameText(seg, 'preset') or StartsText(CmdPath, 'preset/') then
    FStateSnap[DevIdx].PresetJson := PayloadJson;
end;

procedure TCommandRouter.RememberBridgeWireAndState(DevIdx: Integer; const CmdPath, PayloadJson: string;
  const Wire: TBytes);
begin
  PathWireCacheUpsert(DevIdx, CmdPath, Wire);
  StateSnapFromPathPayload(DevIdx, CmdPath, PayloadJson);
end;

function TCommandRouter.BuildStateJsonFragment(DevIdx: Integer): string;
var
  S: string;
  first: Boolean;
begin
  Result := '';
  if (DevIdx < 0) or (DevIdx > High(FStateSnap)) then
    Exit;
  first := True;
  S := '';
  if Trim(FStateSnap[DevIdx].PanJson) <> '' then
  begin
    if not first then
      S := S + ',';
    S := S + '"pan":' + FStateSnap[DevIdx].PanJson;
    first := False;
  end;
  if Trim(FStateSnap[DevIdx].TiltJson) <> '' then
  begin
    if not first then
      S := S + ',';
    S := S + '"tilt":' + FStateSnap[DevIdx].TiltJson;
    first := False;
  end;
  if Trim(FStateSnap[DevIdx].ZoomJson) <> '' then
  begin
    if not first then
      S := S + ',';
    S := S + '"zoom":' + FStateSnap[DevIdx].ZoomJson;
    first := False;
  end;
  if Trim(FStateSnap[DevIdx].PresetJson) <> '' then
  begin
    if not first then
      S := S + ',';
    S := S + '"preset":' + FStateSnap[DevIdx].PresetJson;
    first := False;
  end;
  if S = '' then
    Exit;
  Result := ',"state":{' + S + '}';
end;

function TCommandRouter.JsonQuote(const s: string): string;
begin
  Result := '"' + StringReplace(StringReplace(StringReplace(s, '\', '\\', [rfReplaceAll]), '"', '\"', [rfReplaceAll]),
    #10, '\n', [rfReplaceAll]) + '"';
end;

function ParseDottedIPv4ToU32(const S: string; out Addr: Cardinal): Boolean;
var
  A, B, C, D: Integer;
  P1, P2, P3: Integer;
  Part: string;
begin
  Result := False;
  Addr := 0;
  P1 := Pos('.', S);
  if P1 <= 0 then
    Exit;
  P2 := Pos('.', Copy(S, P1 + 1, MaxInt));
  if P2 <= 0 then
    Exit;
  Inc(P2, P1);
  P3 := Pos('.', Copy(S, P2 + 1, MaxInt));
  if P3 <= 0 then
    Exit;
  Inc(P3, P2);
  Part := Copy(S, 1, P1 - 1);
  A := StrToIntDef(Part, -1);
  Part := Copy(S, P1 + 1, P2 - P1 - 1);
  B := StrToIntDef(Part, -1);
  Part := Copy(S, P2 + 1, P3 - P2 - 1);
  C := StrToIntDef(Part, -1);
  Part := Copy(S, P3 + 1, MaxInt);
  D := StrToIntDef(Part, -1);
  if (A < 0) or (A > 255) or (B < 0) or (B > 255) or (C < 0) or (C > 255) or (D < 0) or (D > 255) then
    Exit;
  Addr := Cardinal(A shl 24 or B shl 16 or C shl 8 or D);
  Result := True;
end;

function CidrMatchIPv4(const RemoteHost: string; const Cidr: string): Boolean;
var
  SlashPos: Integer;
  NetStr, MaskStr: string;
  NetAddr, RemoteAddr: Cardinal;
  NetBe, RemBe: Cardinal;
  Prefix: Integer;
  Mask: Cardinal;
begin
  Result := False;
  SlashPos := Pos('/', Cidr);
  if SlashPos > 0 then
  begin
    NetStr := Trim(Copy(Cidr, 1, SlashPos - 1));
    MaskStr := Trim(Copy(Cidr, SlashPos + 1, MaxInt));
    Prefix := StrToIntDef(MaskStr, -1);
  end
  else
  begin
    NetStr := Trim(Cidr);
    Prefix := 32;
  end;
  if (Prefix < 0) or (Prefix > 32) then
    Exit;
  if not ParseDottedIPv4ToU32(NetStr, NetAddr) then
    Exit;
  if not ParseDottedIPv4ToU32(RemoteHost, RemoteAddr) then
    Exit;
  NetBe := ((NetAddr and $FF) shl 24) or ((NetAddr shr 8 and $FF) shl 16) or ((NetAddr shr 16 and $FF) shl 8) or (NetAddr shr 24);
  RemBe := ((RemoteAddr and $FF) shl 24) or ((RemoteAddr shr 8 and $FF) shl 16) or ((RemoteAddr shr 16 and $FF) shl 8) or (RemoteAddr shr 24);
  if Prefix = 0 then
    Mask := 0
  else
    Mask := Cardinal(not ((Cardinal(1) shl (32 - Prefix)) - 1));
  Result := (NetBe and Mask) = (RemBe and Mask);
end;

function TCommandRouter.UdpRemoteAllowed(BusIndex: Integer; const RemoteHost: string): Boolean;
var
  I: Integer;
  Cidr: string;
begin
  Result := True;
  if (BusIndex < 0) or (BusIndex > High(FDeviceConfiguration.ViscaBuses)) then
    Exit;
  if Length(FDeviceConfiguration.ViscaBuses[BusIndex].AllowFrom) = 0 then
    Exit;
  for I := 0 to High(FDeviceConfiguration.ViscaBuses[BusIndex].AllowFrom) do
  begin
    Cidr := Trim(FDeviceConfiguration.ViscaBuses[BusIndex].AllowFrom[I]);
    if Cidr = '' then
      Continue;
    if CidrMatchIPv4(RemoteHost, Cidr) then
      Exit(True);
  end;
  Result := False;
end;

constructor TCommandRouter.Create(const DeviceConfiguration: TDevicesConfig; ViscaCommandMapping: TViscaMapping;
  AMqtt: THaMqttPublisher);
var
  BusLoopIndex, DeviceLoopIndex, CtlIx: Integer;
  BusIndex: Integer;
  DeviceGapMs: Cardinal;
  BusId: string;
  Cs: string;
begin
  inherited Create;
  FDeviceConfiguration := DeviceConfiguration;
  FViscaCommandMapping := ViscaCommandMapping;
  FMqtt := AMqtt;
  SetLength(FSerialPorts, Length(FDeviceConfiguration.ViscaBuses));
  SetLength(FUdpPorts, Length(FDeviceConfiguration.ViscaBuses));
  SetLength(FCommandQueuesPerBus, Length(FDeviceConfiguration.ViscaBuses));
  SetLength(FLastTransmitTickPerBus, Length(FDeviceConfiguration.ViscaBuses));
  SetLength(FInterCommandGapMsPerBus, Length(FDeviceConfiguration.ViscaBuses));
  SetLength(FMaxQueueDepthPerBus, Length(FDeviceConfiguration.ViscaBuses));
  SetLength(FRxAccumPerBus, Length(FDeviceConfiguration.ViscaBuses));
  SetLength(FBusTxPhase, Length(FDeviceConfiguration.ViscaBuses));
  SetLength(FInFlightWaitStartTick, Length(FDeviceConfiguration.ViscaBuses));
  SetLength(FInFlightAckTimeoutMs, Length(FDeviceConfiguration.ViscaBuses));
  SetLength(FInFlightSendCount, Length(FDeviceConfiguration.ViscaBuses));
  SetLength(FInFlightPacket, Length(FDeviceConfiguration.ViscaBuses));
  SetLength(FInFlightUdpHost, Length(FDeviceConfiguration.ViscaBuses));
  SetLength(FInFlightUdpPort, Length(FDeviceConfiguration.ViscaBuses));
  SetLength(FRetryResumeTick, Length(FDeviceConfiguration.ViscaBuses));
  SetLength(FControllerTopicPerBus, Length(FDeviceConfiguration.ViscaBuses));
  for BusLoopIndex := 0 to High(FDeviceConfiguration.ViscaBuses) do
  begin
    FCommandQueuesPerBus[BusLoopIndex] := TFPList.Create;
    FLastTransmitTickPerBus[BusLoopIndex] := 0;
    FInterCommandGapMsPerBus[BusLoopIndex] := 40;
    FMaxQueueDepthPerBus[BusLoopIndex] := 50;
    SetLength(FRxAccumPerBus[BusLoopIndex], 0);
    FBusTxPhase[BusLoopIndex] := btpIdle;
    SetLength(FInFlightPacket[BusLoopIndex], 0);
    FInFlightSendCount[BusLoopIndex] := 0;
    FInFlightUdpHost[BusLoopIndex] := '';
    FInFlightUdpPort[BusLoopIndex] := 0;
    FSerialPorts[BusLoopIndex] := nil;
    FUdpPorts[BusLoopIndex] := nil;

    if SameText(FDeviceConfiguration.ViscaBuses[BusLoopIndex].Transport, 'serial') then
    begin
      FSerialPorts[BusLoopIndex] := TSerialPort.Create;
      if not FSerialPorts[BusLoopIndex].Open(FDeviceConfiguration.ViscaBuses[BusLoopIndex].Port,
        FDeviceConfiguration.ViscaBuses[BusLoopIndex].Baud, FDeviceConfiguration.ViscaBuses[BusLoopIndex].DataBits,
        FDeviceConfiguration.ViscaBuses[BusLoopIndex].Parity, FDeviceConfiguration.ViscaBuses[BusLoopIndex].StopBits,
        FDeviceConfiguration.ViscaBuses[BusLoopIndex].Rs485) then
        LogFmt(llWarn, 'visca: could not open serial bus "%s" (%s)',
          [FDeviceConfiguration.ViscaBuses[BusLoopIndex].Id, FDeviceConfiguration.ViscaBuses[BusLoopIndex].Port]);
    end
    else
    begin
      FUdpPorts[BusLoopIndex] := TUdpViscaPort.Create;
      if not FUdpPorts[BusLoopIndex].Open(FDeviceConfiguration.ViscaBuses[BusLoopIndex].BindHost,
        FDeviceConfiguration.ViscaBuses[BusLoopIndex].BindPort) then
        LogFmt(llWarn, 'visca: could not bind udp bus "%s" (%s:%d)',
          [FDeviceConfiguration.ViscaBuses[BusLoopIndex].Id, FDeviceConfiguration.ViscaBuses[BusLoopIndex].BindHost,
          FDeviceConfiguration.ViscaBuses[BusLoopIndex].BindPort]);
    end;

    BusId := FDeviceConfiguration.ViscaBuses[BusLoopIndex].Id;
    Cs := '';
    for CtlIx := 0 to High(FDeviceConfiguration.ViscaControllers) do
      if SameText(FDeviceConfiguration.ViscaControllers[CtlIx].BusId, BusId) then
        Cs := FDeviceConfiguration.ViscaControllers[CtlIx].Slug;
    if Cs = '' then
      Cs := BusId;
    FControllerTopicPerBus[BusLoopIndex] := Cs;
  end;
  SetLength(FLastBusCtrlEventJson, Length(FDeviceConfiguration.ViscaBuses));
  SetLength(FLastBusDeviceReplyJson, Length(FDeviceConfiguration.ViscaBuses));
  for BusLoopIndex := 0 to High(FLastBusCtrlEventJson) do
  begin
    FLastBusCtrlEventJson[BusLoopIndex] := '';
    FLastBusDeviceReplyJson[BusLoopIndex] := '';
  end;
  SetLength(FLastControllerJson, Length(FDeviceConfiguration.ViscaDevices));
  SetLength(FLastReplyJson, Length(FDeviceConfiguration.ViscaDevices));
  for DeviceLoopIndex := 0 to High(FLastControllerJson) do
  begin
    FLastControllerJson[DeviceLoopIndex] := '';
    FLastReplyJson[DeviceLoopIndex] := '';
  end;
  SetLength(FPathWireCache, Length(FDeviceConfiguration.ViscaDevices));
  SetLength(FStateSnap, Length(FDeviceConfiguration.ViscaDevices));
  for DeviceLoopIndex := 0 to High(FPathWireCache) do
  begin
    SetLength(FPathWireCache[DeviceLoopIndex], 0);
    FStateSnap[DeviceLoopIndex].PanJson := '';
    FStateSnap[DeviceLoopIndex].TiltJson := '';
    FStateSnap[DeviceLoopIndex].ZoomJson := '';
    FStateSnap[DeviceLoopIndex].PresetJson := '';
  end;
  for DeviceLoopIndex := 0 to High(FDeviceConfiguration.ViscaDevices) do
  begin
    BusIndex := IndexOfViscaBusById(FDeviceConfiguration.ViscaDevices[DeviceLoopIndex].BusId);
    if BusIndex < 0 then
      Continue;
    DeviceGapMs := FDeviceConfiguration.ViscaDevices[DeviceLoopIndex].MinInterCommandMs;
    if DeviceGapMs > FInterCommandGapMsPerBus[BusIndex] then
      FInterCommandGapMsPerBus[BusIndex] := DeviceGapMs;
    if FDeviceConfiguration.ViscaDevices[DeviceLoopIndex].MaxQueueDepth > FMaxQueueDepthPerBus[BusIndex] then
      FMaxQueueDepthPerBus[BusIndex] := FDeviceConfiguration.ViscaDevices[DeviceLoopIndex].MaxQueueDepth;
  end;
end;

destructor TCommandRouter.Destroy;
var
  BusLoopIndex, QueueSlotIndex, DevLoop: Integer;
  QueueList: TFPList;
  QueuedCommand: TQueuedViscaCommand;
begin
  for DevLoop := 0 to High(FPathWireCache) do
    SetLength(FPathWireCache[DevLoop], 0);
  for BusLoopIndex := 0 to High(FCommandQueuesPerBus) do
  begin
    QueueList := FCommandQueuesPerBus[BusLoopIndex];
    if QueueList <> nil then
    begin
      for QueueSlotIndex := 0 to QueueList.Count - 1 do
      begin
        QueuedCommand := TQueuedViscaCommand(QueueList[QueueSlotIndex]);
        QueuedCommand.Free;
      end;
      QueueList.Free;
    end;
    if FSerialPorts[BusLoopIndex] <> nil then
      FSerialPorts[BusLoopIndex].Free;
    if FUdpPorts[BusLoopIndex] <> nil then
      FUdpPorts[BusLoopIndex].Free;
  end;
  inherited Destroy;
end;

function TCommandRouter.IndexOfViscaBusById(const BusId: string): Integer;
var
  BusLoopIndex: Integer;
begin
  for BusLoopIndex := 0 to High(FDeviceConfiguration.ViscaBuses) do
    if SameText(FDeviceConfiguration.ViscaBuses[BusLoopIndex].Id, BusId) then
      Exit(BusLoopIndex);
  Result := -1;
end;

function TCommandRouter.IndexOfViscaDeviceByTopicSlug(const TopicSlug: string): Integer;
var
  DeviceLoopIndex: Integer;
begin
  for DeviceLoopIndex := 0 to High(FDeviceConfiguration.ViscaDevices) do
    if SameText(FDeviceConfiguration.ViscaDevices[DeviceLoopIndex].Slug, TopicSlug) then
      Exit(DeviceLoopIndex);
  Result := -1;
end;

function TCommandRouter.IndexOfViscaDeviceOnBusByReplyByte(BusIndex: Integer; ReplyFirst: Byte): Integer;
var
  DevIdx: Integer;
  Expected: Integer;
  Row: TViscaDeviceConfig;
begin
  Result := -1;
  if (ReplyFirst < $90) or (ReplyFirst > $96) then
    Exit;
  for DevIdx := 0 to High(FDeviceConfiguration.ViscaDevices) do
  begin
    Row := FDeviceConfiguration.ViscaDevices[DevIdx];
    if IndexOfViscaBusById(Row.BusId) <> BusIndex then
      Continue;
    Expected := $90 + Row.ViscaAddress - 1;
    if ReplyFirst = Byte(Expected) then
      Exit(DevIdx);
  end;
end;

function TCommandRouter.IndexOfUdpDeviceOnBusByRemoteAndId(BusIndex: Integer; const RemoteHost: string; RemotePort: Integer; DeviceID: Integer): Integer;
var
  DevIdx: Integer;
  Row: TViscaDeviceConfig;
begin
  Result := -1;
  if (DeviceID < 1) or (DeviceID > 7) then
    Exit;
  for DevIdx := 0 to High(FDeviceConfiguration.ViscaDevices) do
  begin
    Row := FDeviceConfiguration.ViscaDevices[DevIdx];
    if IndexOfViscaBusById(Row.BusId) <> BusIndex then
      Continue;
    if not SameText(Row.UdpHost, RemoteHost) then
      Continue;
    if Row.UdpPort <> RemotePort then
      Continue;
    if Integer(Row.ViscaAddress) <> DeviceID then
      Continue;
    Exit(DevIdx);
  end;
end;

function TCommandRouter.ControllerTopicSlugForBusIndex(BusIndex: Integer): string;
begin
  if (BusIndex < 0) or (BusIndex > High(FControllerTopicPerBus)) then
    Exit('');
  Result := FControllerTopicPerBus[BusIndex];
end;

procedure TCommandRouter.TrimOldestCommandsIfQueueExceedsDepth(SerialBusIndex, DeviceConfigIndex: Integer;
  MaxDepth: Cardinal);
var
  QueueList: TFPList;
  QueueSlotIndex, DeviceCommandCount: Integer;
  QueuedCommand: TQueuedViscaCommand;
begin
  QueueList := FCommandQueuesPerBus[SerialBusIndex];
  DeviceCommandCount := 0;
  for QueueSlotIndex := 0 to QueueList.Count - 1 do
    if TQueuedViscaCommand(QueueList[QueueSlotIndex]).DeviceConfigIndex = DeviceConfigIndex then
      Inc(DeviceCommandCount);
  while DeviceCommandCount >= Integer(MaxDepth) do
  begin
    for QueueSlotIndex := 0 to QueueList.Count - 1 do
    begin
      QueuedCommand := TQueuedViscaCommand(QueueList[QueueSlotIndex]);
      if QueuedCommand.DeviceConfigIndex = DeviceConfigIndex then
      begin
        LogFmt(llWarn, 'visca: queue overflow bus %s device %s — dropping oldest',
          [FDeviceConfiguration.ViscaBuses[SerialBusIndex].Id, FDeviceConfiguration.ViscaDevices[DeviceConfigIndex].Slug]);
        QueueList.Delete(QueueSlotIndex);
        QueuedCommand.Free;
        Dec(DeviceCommandCount);
        Break;
      end;
    end;
  end;
end;

procedure TCommandRouter.OnMqttDeviceMessage(Sender: TObject; const Topic, Payload: string);
var
  SlashInRest: Integer;
  TopicRestAfterDevicePrefix: string;
  TopicSlug, ViscaCommandPath: string;
  DeviceConfigIndex, BusIndex: Integer;
  QueuedCommand: TQueuedViscaCommand;
  EncodedProbe: TBytes;
  DeviceRow: TViscaDeviceConfig;
begin
  if not StartsText('device/', Topic) then
    Exit;
  TopicRestAfterDevicePrefix := Copy(Topic, Length('device/') + 1, MaxInt);
  SlashInRest := Pos('/', TopicRestAfterDevicePrefix);
  if SlashInRest <= 0 then
    Exit;
  TopicSlug := Copy(TopicRestAfterDevicePrefix, 1, SlashInRest - 1);
  ViscaCommandPath := Copy(TopicRestAfterDevicePrefix, SlashInRest + 1, MaxInt);
  if ViscaCommandPath = '' then
    Exit;
  DeviceConfigIndex := IndexOfViscaDeviceByTopicSlug(TopicSlug);
  if DeviceConfigIndex < 0 then
  begin
    LogFmt(llDebug, 'visca: unknown device slug in topic %s', [Topic]);
    Exit;
  end;
  BusIndex := IndexOfViscaBusById(FDeviceConfiguration.ViscaDevices[DeviceConfigIndex].BusId);
  if BusIndex < 0 then
  begin
    LogFmt(llWarn, 'visca: device slug %s references unknown bus', [TopicSlug]);
    Exit;
  end;
  DeviceRow := FDeviceConfiguration.ViscaDevices[DeviceConfigIndex];
  EncodedProbe := FViscaCommandMapping.EncodeViscaCommand(DeviceRow.Model, DeviceRow.ViscaAddress, ViscaCommandPath,
    Payload);
  if Length(EncodedProbe) = 0 then
  begin
    LogFmt(llDebug, 'visca: no mapping or missing template values for topic %s (model %s)', [Topic, DeviceRow.Model]);
    Exit;
  end;
  if PathWireCacheMatches(DeviceConfigIndex, ViscaCommandPath, EncodedProbe) then
  begin
    PublishDeviceCommandAck(DeviceRow.Slug, Topic, ViscaCommandPath, True, 'redundant', 0, 'skipped',
      TViscaMapping.ViscaPacketToHex(EncodedProbe));
    Exit;
  end;
  TrimOldestCommandsIfQueueExceedsDepth(BusIndex, DeviceConfigIndex, DeviceRow.MaxQueueDepth);
  RemoveQueuedCoalesced(BusIndex, DeviceConfigIndex, CoalesceGroupKey(DeviceConfigIndex, ViscaCommandPath));
  QueuedCommand := TQueuedViscaCommand.Create;
  QueuedCommand.DeviceConfigIndex := DeviceConfigIndex;
  QueuedCommand.SerialBusIndex := BusIndex;
  QueuedCommand.MqttTopic := Topic;
  QueuedCommand.ViscaCommandPath := ViscaCommandPath;
  QueuedCommand.MqttPayloadJson := Payload;
  FCommandQueuesPerBus[BusIndex].Add(QueuedCommand);
end;

procedure TCommandRouter.ConsumeLeadingBytes(var Buf: TBytes; Count: Integer);
var
  NewLen, J: Integer;
begin
  if Count <= 0 then
    Exit;
  if Count >= Length(Buf) then
  begin
    SetLength(Buf, 0);
    Exit;
  end;
  NewLen := Length(Buf) - Count;
  for J := 0 to NewLen - 1 do
    Buf[J] := Buf[Count + J];
  SetLength(Buf, NewLen);
end;

procedure TCommandRouter.DrainSerialIncoming(BusIndex: Integer);
var
  I, Start: Integer;
  FrameLen: Integer;
  Frame: TBytes;
  Rv: Integer;
begin
  if (BusIndex < 0) or (BusIndex > High(FSerialPorts)) or (FSerialPorts[BusIndex] = nil) then
    Exit;
  FSerialPorts[BusIndex].TryScheduledReopen(GetTickCount64);
  if FSerialPorts[BusIndex].SerialFileDescriptor < 0 then
    Exit;
  Rv := FSerialPorts[BusIndex].ReadNonBlockingAppend(FRxAccumPerBus[BusIndex], 256);
  if Rv < 0 then
  begin
    AbortInFlight(BusIndex, 'serial_read');
    FSerialPorts[BusIndex].ScheduleReopen(GetTickCount64);
    Exit;
  end;
  if Length(FRxAccumPerBus[BusIndex]) > MaxViscaRxAccum then
  begin
    LogFmt(llWarn, 'visca: rx buffer overflow bus %s — clearing', [FDeviceConfiguration.ViscaBuses[BusIndex].Id]);
    SetLength(FRxAccumPerBus[BusIndex], 0);
    Exit;
  end;
  Start := 0;
  I := 0;
  while I <= High(FRxAccumPerBus[BusIndex]) do
  begin
    if FRxAccumPerBus[BusIndex][I] = $FF then
    begin
      FrameLen := I - Start + 1;
      SetLength(Frame, FrameLen);
      if FrameLen > 0 then
        Move(FRxAccumPerBus[BusIndex][Start], Frame[0], FrameLen);
      HandleCompleteViscaFrame(BusIndex, Frame);
      Start := I + 1;
    end;
    Inc(I);
  end;
  if Start > 0 then
    ConsumeLeadingBytes(FRxAccumPerBus[BusIndex], Start);
end;

procedure TCommandRouter.DrainUdpIncoming(BusIndex: Integer);
var
  Data, Frame: TBytes;
  RemoteHost: string;
  RemotePort: Integer;
  I, Start, FrameLen: Integer;
begin
  if (BusIndex < 0) or (BusIndex > High(FUdpPorts)) or (FUdpPorts[BusIndex] = nil) then
    Exit;
  while FUdpPorts[BusIndex].RecvDatagram(Data, RemoteHost, RemotePort) do
  begin
    if not UdpRemoteAllowed(BusIndex, RemoteHost) then
      Continue;
    Start := 0;
    I := 0;
    while I <= High(Data) do
    begin
      if Data[I] = $FF then
      begin
        FrameLen := I - Start + 1;
        if FrameLen > 0 then
        begin
          SetLength(Frame, FrameLen);
          Move(Data[Start], Frame[0], FrameLen);
          HandleCompleteViscaFrame(BusIndex, Frame, RemoteHost, RemotePort);
        end;
        Start := I + 1;
      end;
      Inc(I);
    end;
  end;
end;

procedure TCommandRouter.PublishControllerSemantic(const BusId, ControllerSlug: string; const DeviceSlugOrEmpty: string;
  const CommandPath, PayloadJson, HexTrace: string; const RemoteHost: string; RemotePort: Integer);
var
  Js: string;
  Ts: Int64;
  BusIx: Integer;
  DeviceSlugJson: string;
  TraceExtra: string;
begin
  if FMqtt = nil then
    Exit;
  Ts := Int64(DateTimeToUnix(Now, True)) * 1000;
  if Trim(DeviceSlugOrEmpty) = '' then
    DeviceSlugJson := 'null'
  else
    DeviceSlugJson := JsonQuote(DeviceSlugOrEmpty);
  TraceExtra := '';
  if (Trim(RemoteHost) <> '') and (RemotePort > 0) then
    TraceExtra := Format(',"transport":"udp","remoteHost":%s,"remotePort":%d', [JsonQuote(RemoteHost), RemotePort]);
  Js := Format('{"ts":%d,"bus":%s,"source":"controller","command":%s,"deviceSlug":%s,"payload":%s,"trace":{"viscaHex":%s%s}}',
    [Ts, JsonQuote(BusId), JsonQuote(CommandPath), DeviceSlugJson, PayloadJson, JsonQuote(HexTrace), TraceExtra]);
  FMqtt.PublishJson('controller/' + ControllerSlug + '/event', Js);
  BusIx := IndexOfViscaBusById(BusId);
  if BusIx >= 0 then
  begin
    FLastBusCtrlEventJson[BusIx] := Format('{"deviceSlug":%s,"command":%s,"payload":%s,"viscaHex":%s}',
      [DeviceSlugJson, JsonQuote(CommandPath), PayloadJson, JsonQuote(HexTrace)]);
    PublishControllerBusSnapshot(BusIx);
  end;
end;

procedure TCommandRouter.PublishControllerRawEvent(const BusId, ControllerSlug, HexTrace: string; const RemoteHost: string; RemotePort: Integer);
var
  Js: string;
  Ts: Int64;
  BusIx: Integer;
  TraceExtra: string;
begin
  if FMqtt = nil then
    Exit;
  Ts := Int64(DateTimeToUnix(Now, True)) * 1000;
  TraceExtra := '';
  if (Trim(RemoteHost) <> '') and (RemotePort > 0) then
    TraceExtra := Format(',"transport":"udp","remoteHost":%s,"remotePort":%d', [JsonQuote(RemoteHost), RemotePort]);
  Js := Format('{"ts":%d,"bus":%s,"source":"controller","command":"event","payload":{"raw":true,"viscaHex":%s},"trace":{"viscaHex":%s%s}}',
    [Ts, JsonQuote(BusId), JsonQuote(HexTrace), JsonQuote(HexTrace), TraceExtra]);
  FMqtt.PublishJson('controller/' + ControllerSlug + '/event', Js);
  BusIx := IndexOfViscaBusById(BusId);
  if BusIx >= 0 then
  begin
    FLastBusCtrlEventJson[BusIx] := Format('{"command":"event","payload":{"raw":true,"viscaHex":%s},"viscaHex":%s}',
      [JsonQuote(HexTrace), JsonQuote(HexTrace)]);
    PublishControllerBusSnapshot(BusIx);
  end;
end;

procedure TCommandRouter.PublishControllerBusSnapshot(BusIndex: Integer);
var
  BusId: string;
  Ts: Int64;
  Ctrl, Devp, Js: string;
  CSlug: string;
begin
  if FMqtt = nil then
    Exit;
  if (BusIndex < 0) or (BusIndex > High(FDeviceConfiguration.ViscaBuses)) then
    Exit;
  BusId := FDeviceConfiguration.ViscaBuses[BusIndex].Id;
  CSlug := ControllerTopicSlugForBusIndex(BusIndex);
  Ts := Int64(DateTimeToUnix(Now, True)) * 1000;
  if FLastBusCtrlEventJson[BusIndex] = '' then
    Ctrl := 'null'
  else
    Ctrl := FLastBusCtrlEventJson[BusIndex];
  if FLastBusDeviceReplyJson[BusIndex] = '' then
    Devp := 'null'
  else
    Devp := FLastBusDeviceReplyJson[BusIndex];
  Js := Format('{"ts":%d,"bus":%s,"lastController":%s,"lastDeviceReply":%s}', [Ts, JsonQuote(BusId), Ctrl, Devp]);
  FMqtt.PublishJson('controller/' + CSlug + '/status', Js);
end;

procedure TCommandRouter.PublishDeviceTelemetry(const DeviceSlug, Kind, HexTrace: string; const DecodeJsonObject: string);
var
  Js: string;
  Ts: Int64;
begin
  if FMqtt = nil then
    Exit;
  Ts := Int64(DateTimeToUnix(Now, True)) * 1000;
  if Trim(DecodeJsonObject) <> '' then
    Js := Format('{"ts":%d,"source":"visca","kind":%s,"viscaHex":%s,"decode":%s}',
      [Ts, JsonQuote(Kind), JsonQuote(HexTrace), DecodeJsonObject])
  else
    Js := Format('{"ts":%d,"source":"visca","kind":%s,"viscaHex":%s}', [Ts, JsonQuote(Kind), JsonQuote(HexTrace)]);
  FMqtt.PublishJson('device/' + DeviceSlug + '/telemetry', Js);
end;

procedure TCommandRouter.PublishDeviceStatusMerge(const DeviceSlug: string; DevIdx: Integer);
var
  Ts: Int64;
  Ctrl, Rep, Body: string;
begin
  if (FMqtt = nil) or (DevIdx < 0) or (DevIdx > High(FLastControllerJson)) then
    Exit;
  Ts := Int64(DateTimeToUnix(Now, True)) * 1000;
  Ctrl := FLastControllerJson[DevIdx];
  if Ctrl = '' then
    Ctrl := 'null';
  Rep := FLastReplyJson[DevIdx];
  if Rep = '' then
    Rep := 'null';
  Body := Format('{"ts":%d,"lastController":%s,"lastReply":%s%s}', [Ts, Ctrl, Rep, BuildStateJsonFragment(DevIdx)]);
  FMqtt.PublishJson('device/' + DeviceSlug + '/status', Body);
end;

procedure TCommandRouter.PublishDeviceCommandAck(const DeviceSlug, MqttTopic, CmdPath: string; Ok: Boolean;
  const Reason: string; Attempts: Integer; const ViscaKind, ViscaHex: string);
var
  Js: string;
  Ts: Int64;
  Rj: string;
begin
  if FMqtt = nil then
    Exit;
  Ts := Int64(DateTimeToUnix(Now, True)) * 1000;
  if Trim(Reason) <> '' then
    Rj := JsonQuote(Reason)
  else
    Rj := 'null';
  Js := Format(
    '{"ts":%d,"ok":%s,"reason":%s,"attempts":%d,"mqttTopic":%s,"command":%s,"viscaKind":%s,"viscaHex":%s}',
    [Ts, BoolToStr(Ok, 'true', 'false'), Rj, Attempts, JsonQuote(MqttTopic), JsonQuote(CmdPath), JsonQuote(ViscaKind),
    JsonQuote(ViscaHex)]);
  FMqtt.PublishJson('device/' + DeviceSlug + '/commandAck', Js);
end;

procedure TCommandRouter.PopQueueHead(SerialBusIndex: Integer);
var
  Q: TFPList;
  Head: TQueuedViscaCommand;
begin
  Q := FCommandQueuesPerBus[SerialBusIndex];
  if Q.Count = 0 then
    Exit;
  Head := TQueuedViscaCommand(Q[0]);
  Q.Delete(0);
  Head.Free;
end;

procedure TCommandRouter.AbortInFlight(SerialBusIndex: Integer; const Reason: string);
var
  Head: TQueuedViscaCommand;
  Attempts: Integer;
begin
  if FBusTxPhase[SerialBusIndex] = btpIdle then
    Exit;
  if FCommandQueuesPerBus[SerialBusIndex].Count = 0 then
  begin
    FBusTxPhase[SerialBusIndex] := btpIdle;
    Exit;
  end;
  Head := TQueuedViscaCommand(FCommandQueuesPerBus[SerialBusIndex][0]);
  Attempts := FInFlightSendCount[SerialBusIndex];
  PublishDeviceCommandAck(FDeviceConfiguration.ViscaDevices[Head.DeviceConfigIndex].Slug, Head.MqttTopic,
    Head.ViscaCommandPath, False, Reason, Attempts, '', '');
  PopQueueHead(SerialBusIndex);
  FBusTxPhase[SerialBusIndex] := btpIdle;
  SetLength(FInFlightPacket[SerialBusIndex], 0);
  FLastTransmitTickPerBus[SerialBusIndex] := GetTickCount64;
end;

procedure TCommandRouter.TryFinalizeInFlightFromReply(SerialBusIndex, DevIdx: Integer; const Kind, HexStr: string);
var
  Head: TQueuedViscaCommand;
  Slug: string;
  Ok: Boolean;
  Reason: string;
begin
  if FBusTxPhase[SerialBusIndex] <> btpWaitReply then
    Exit;
  if FCommandQueuesPerBus[SerialBusIndex].Count = 0 then
    Exit;
  Head := TQueuedViscaCommand(FCommandQueuesPerBus[SerialBusIndex][0]);
  if Head.DeviceConfigIndex <> DevIdx then
    Exit;
  if not (SameText(Kind, 'ack') or SameText(Kind, 'completion') or SameText(Kind, 'error')) then
    Exit;
  Slug := FDeviceConfiguration.ViscaDevices[DevIdx].Slug;
  Ok := not SameText(Kind, 'error');
  if Ok then
    Reason := ''
  else
    Reason := 'visca_error';
  PublishDeviceCommandAck(Slug, Head.MqttTopic, Head.ViscaCommandPath, Ok, Reason, FInFlightSendCount[SerialBusIndex],
    Kind, HexStr);
  if Ok then
    RememberBridgeWireAndState(DevIdx, Head.ViscaCommandPath, Head.MqttPayloadJson, FInFlightPacket[SerialBusIndex]);
  PopQueueHead(SerialBusIndex);
  FBusTxPhase[SerialBusIndex] := btpIdle;
  SetLength(FInFlightPacket[SerialBusIndex], 0);
  FLastTransmitTickPerBus[SerialBusIndex] := GetTickCount64;
end;

procedure TCommandRouter.OnDrainingComplete(SerialBusIndex: Integer; NowTick: QWord);
var
  Head: TQueuedViscaCommand;
  Row: TViscaDeviceConfig;
  Slug: string;
begin
  if FCommandQueuesPerBus[SerialBusIndex].Count = 0 then
  begin
    FBusTxPhase[SerialBusIndex] := btpIdle;
    Exit;
  end;
  Head := TQueuedViscaCommand(FCommandQueuesPerBus[SerialBusIndex][0]);
  Row := FDeviceConfiguration.ViscaDevices[Head.DeviceConfigIndex];
  Inc(FInFlightSendCount[SerialBusIndex]);
  if Row.AckTimeoutMs = 0 then
  begin
    Slug := Row.Slug;
    PublishDeviceCommandAck(Slug, Head.MqttTopic, Head.ViscaCommandPath, True, '', FInFlightSendCount[SerialBusIndex],
      'immediate', TViscaMapping.ViscaPacketToHex(FInFlightPacket[SerialBusIndex]));
    RememberBridgeWireAndState(Head.DeviceConfigIndex, Head.ViscaCommandPath, Head.MqttPayloadJson,
      FInFlightPacket[SerialBusIndex]);
    PopQueueHead(SerialBusIndex);
    FBusTxPhase[SerialBusIndex] := btpIdle;
    SetLength(FInFlightPacket[SerialBusIndex], 0);
    FLastTransmitTickPerBus[SerialBusIndex] := NowTick;
    Exit;
  end;
  FInFlightWaitStartTick[SerialBusIndex] := NowTick;
  FInFlightAckTimeoutMs[SerialBusIndex] := Row.AckTimeoutMs;
  FBusTxPhase[SerialBusIndex] := btpWaitReply;
end;

procedure TCommandRouter.OnAckTimeout(SerialBusIndex: Integer; NowTick: QWord);
var
  Head: TQueuedViscaCommand;
  Row: TViscaDeviceConfig;
  MaxAttempts: Integer;
  Slug: string;
begin
  if FCommandQueuesPerBus[SerialBusIndex].Count = 0 then
  begin
    FBusTxPhase[SerialBusIndex] := btpIdle;
    Exit;
  end;
  Head := TQueuedViscaCommand(FCommandQueuesPerBus[SerialBusIndex][0]);
  Row := FDeviceConfiguration.ViscaDevices[Head.DeviceConfigIndex];
  MaxAttempts := 1 + Integer(Row.CommandRetryMax);
  if FInFlightSendCount[SerialBusIndex] < MaxAttempts then
  begin
    FRetryResumeTick[SerialBusIndex] := NowTick + Row.RetryBackoffMs;
    FBusTxPhase[SerialBusIndex] := btpBackoffRetry;
    Exit;
  end;
  Slug := Row.Slug;
  PublishDeviceCommandAck(Slug, Head.MqttTopic, Head.ViscaCommandPath, False, 'timeout', FInFlightSendCount[SerialBusIndex],
    '', '');
  PopQueueHead(SerialBusIndex);
  FBusTxPhase[SerialBusIndex] := btpIdle;
  SetLength(FInFlightPacket[SerialBusIndex], 0);
  FLastTransmitTickPerBus[SerialBusIndex] := NowTick;
end;

procedure TCommandRouter.MaybeStartHeadCommand(SerialBusIndex: Integer; NowTick: QWord);
var
  Head: TQueuedViscaCommand;
  ViscaPacket: TBytes;
  DeviceRow: TViscaDeviceConfig;
begin
  if FBusTxPhase[SerialBusIndex] <> btpIdle then
    Exit;
  if FCommandQueuesPerBus[SerialBusIndex].Count = 0 then
    Exit;
  if NowTick < FLastTransmitTickPerBus[SerialBusIndex] + FInterCommandGapMsPerBus[SerialBusIndex] then
    Exit;
  if SameText(FDeviceConfiguration.ViscaBuses[SerialBusIndex].Transport, 'serial') then
  begin
    if (FSerialPorts[SerialBusIndex] = nil) or (FSerialPorts[SerialBusIndex].SerialFileDescriptor < 0) then
      Exit;
  end
  else
  begin
    if (FUdpPorts[SerialBusIndex] = nil) or (not FUdpPorts[SerialBusIndex].IsOpen) then
      Exit;
  end;
  Head := TQueuedViscaCommand(FCommandQueuesPerBus[SerialBusIndex][0]);
  DeviceRow := FDeviceConfiguration.ViscaDevices[Head.DeviceConfigIndex];
  ViscaPacket := FViscaCommandMapping.EncodeViscaCommand(DeviceRow.Model, DeviceRow.ViscaAddress,
    Head.ViscaCommandPath, Head.MqttPayloadJson);
  if Length(ViscaPacket) = 0 then
  begin
    PublishDeviceCommandAck(DeviceRow.Slug, Head.MqttTopic, Head.ViscaCommandPath, False, 'encode', 0, '', '');
    PopQueueHead(SerialBusIndex);
    FLastTransmitTickPerBus[SerialBusIndex] := NowTick;
    Exit;
  end;
  if PathWireCacheMatches(Head.DeviceConfigIndex, Head.ViscaCommandPath, ViscaPacket) then
  begin
    PublishDeviceCommandAck(DeviceRow.Slug, Head.MqttTopic, Head.ViscaCommandPath, True, 'redundant', 1, 'skipped',
      TViscaMapping.ViscaPacketToHex(ViscaPacket));
    PopQueueHead(SerialBusIndex);
    FLastTransmitTickPerBus[SerialBusIndex] := NowTick;
    Exit;
  end;
  FInFlightPacket[SerialBusIndex] := Copy(ViscaPacket, 0, Length(ViscaPacket));
  FInFlightSendCount[SerialBusIndex] := 0;
  if SameText(FDeviceConfiguration.ViscaBuses[SerialBusIndex].Transport, 'serial') then
  begin
    if not FSerialPorts[SerialBusIndex].QueueTransmit(FInFlightPacket[SerialBusIndex]) then
    begin
      LogFmt(llWarn, 'visca: TX queue overflow bus %s', [FDeviceConfiguration.ViscaBuses[SerialBusIndex].Id]);
      PublishDeviceCommandAck(DeviceRow.Slug, Head.MqttTopic, Head.ViscaCommandPath, False, 'tx_queue', 0, '', '');
      PopQueueHead(SerialBusIndex);
      SetLength(FInFlightPacket[SerialBusIndex], 0);
      FLastTransmitTickPerBus[SerialBusIndex] := NowTick;
      Exit;
    end;
  end
  else
  begin
    FInFlightUdpHost[SerialBusIndex] := DeviceRow.UdpHost;
    FInFlightUdpPort[SerialBusIndex] := DeviceRow.UdpPort;
    if (Trim(FInFlightUdpHost[SerialBusIndex]) = '') or (FInFlightUdpPort[SerialBusIndex] <= 0) then
    begin
      PublishDeviceCommandAck(DeviceRow.Slug, Head.MqttTopic, Head.ViscaCommandPath, False, 'udp_dest', 0, '', '');
      PopQueueHead(SerialBusIndex);
      SetLength(FInFlightPacket[SerialBusIndex], 0);
      FLastTransmitTickPerBus[SerialBusIndex] := NowTick;
      Exit;
    end;
  end;
  FBusTxPhase[SerialBusIndex] := btpDrainingTx;
end;

procedure TCommandRouter.AdvanceBusTransmission(SerialBusIndex: Integer; NowTick: QWord);
var
  Pr: TSerialPumpResult;
begin
  case FBusTxPhase[SerialBusIndex] of
    btpIdle:
      MaybeStartHeadCommand(SerialBusIndex, NowTick);
    btpDrainingTx:
      begin
        if SameText(FDeviceConfiguration.ViscaBuses[SerialBusIndex].Transport, 'serial') then
        begin
          Pr := FSerialPorts[SerialBusIndex].PumpTransmit;
          case Pr of
            sprDone:
              OnDrainingComplete(SerialBusIndex, NowTick);
            sprError:
              AbortInFlight(SerialBusIndex, 'serial_write');
          else
            ;
          end;
        end
        else
        begin
          if FUdpPorts[SerialBusIndex].SendTo(FInFlightPacket[SerialBusIndex], FInFlightUdpHost[SerialBusIndex],
            FInFlightUdpPort[SerialBusIndex]) then
            OnDrainingComplete(SerialBusIndex, NowTick)
          else
            AbortInFlight(SerialBusIndex, 'udp_send');
        end;
      end;
    btpWaitReply:
      if QWord(NowTick - FInFlightWaitStartTick[SerialBusIndex]) >= QWord(FInFlightAckTimeoutMs[SerialBusIndex]) then
        OnAckTimeout(SerialBusIndex, NowTick);
    btpBackoffRetry:
      if NowTick >= FRetryResumeTick[SerialBusIndex] then
      begin
        if SameText(FDeviceConfiguration.ViscaBuses[SerialBusIndex].Transport, 'serial') then
        begin
          if not FSerialPorts[SerialBusIndex].QueueTransmit(FInFlightPacket[SerialBusIndex]) then
          begin
            AbortInFlight(SerialBusIndex, 'tx_queue');
            Exit;
          end;
        end;
        FBusTxPhase[SerialBusIndex] := btpDrainingTx;
      end;
  end;
end;

procedure TCommandRouter.HandleCompleteViscaFrame(BusIndex: Integer; const Frame: TBytes; const RemoteHost: string; RemotePort: Integer);
var
  BusId: string;
  ControllerSlug: string;
  B0: Byte;
  DevIdx: Integer;
  Row: TViscaDeviceConfig;
  TopicPath, PayloadJson: string;
  HexStr: string;
  Kind: string;
  Expected: Integer;
  CtrlJson: string;
  EncodedProbe: TBytes;
  Dec: string;
  DeviceID: Integer;
  MatchCount: Integer;
  MatchedDev: Integer;
begin
  if Length(Frame) < 2 then
    Exit;
  BusId := FDeviceConfiguration.ViscaBuses[BusIndex].Id;
  ControllerSlug := ControllerTopicSlugForBusIndex(BusIndex);
  HexStr := TViscaMapping.ViscaPacketToHex(Frame);
  B0 := Frame[0];
  if (B0 >= $81) and (B0 <= $87) then
  begin
    DeviceID := Integer(B0) - $80;
    MatchCount := 0;
    MatchedDev := -1;
    for DevIdx := 0 to High(FDeviceConfiguration.ViscaDevices) do
    begin
      Row := FDeviceConfiguration.ViscaDevices[DevIdx];
      if IndexOfViscaBusById(Row.BusId) <> BusIndex then
        Continue;
      if Integer(Row.ViscaAddress) <> DeviceID then
        Continue;
      Inc(MatchCount);
      MatchedDev := DevIdx;
    end;
    if MatchCount = 1 then
    begin
      DevIdx := MatchedDev;
      Row := FDeviceConfiguration.ViscaDevices[DevIdx];
      Expected := $80 + Row.ViscaAddress;
      if Integer(B0) = Expected then
      begin
        if FViscaCommandMapping.TryDecodeControllerPacket(Row.Model, Frame, TopicPath, PayloadJson) then
        begin
          PublishControllerSemantic(BusId, ControllerSlug, Row.Slug, TopicPath, PayloadJson, HexStr, RemoteHost, RemotePort);
          CtrlJson := Format('{"command":%s,"payload":%s,"viscaHex":%s}', [JsonQuote(TopicPath), PayloadJson, JsonQuote(HexStr)]);
          FLastControllerJson[DevIdx] := CtrlJson;
          EncodedProbe := FViscaCommandMapping.EncodeViscaCommand(Row.Model, Row.ViscaAddress, TopicPath, PayloadJson);
          if Length(EncodedProbe) > 0 then
            RememberBridgeWireAndState(DevIdx, TopicPath, PayloadJson, EncodedProbe);
        end
        else
        begin
          PublishControllerRawEvent(BusId, ControllerSlug, HexStr, RemoteHost, RemotePort);
          CtrlJson := Format('{"command":"event","payload":{"viscaHex":%s},"viscaHex":%s}', [JsonQuote(HexStr), JsonQuote(HexStr)]);
          FLastControllerJson[DevIdx] := CtrlJson;
        end;
        PublishDeviceStatusMerge(Row.Slug, DevIdx);
        Exit;
      end;
    end;
    LogFmt(llDebug, 'visca: controller frame %s on bus %s — ambiguous or unknown address %02x', [HexStr, BusId, B0]);
    PublishControllerRawEvent(BusId, ControllerSlug, HexStr, RemoteHost, RemotePort);
    Exit;
  end;
  if (B0 >= $90) and (B0 <= $96) then
  begin
    if SameText(FDeviceConfiguration.ViscaBuses[BusIndex].Transport, 'udp') then
    begin
      DeviceID := Integer(B0) - $90 + 1;
      DevIdx := IndexOfUdpDeviceOnBusByRemoteAndId(BusIndex, RemoteHost, RemotePort, DeviceID);
    end
    else
      DevIdx := IndexOfViscaDeviceOnBusByReplyByte(BusIndex, B0);
    if DevIdx < 0 then
    begin
      LogFmt(llDebug, 'visca: reply %s on bus %s — no matching device', [HexStr, BusId]);
      Exit;
    end;
    Kind := 'other';
    Dec := '';
    if Length(Frame) >= 2 then
    begin
      if Frame[1] = $60 then
        Kind := 'error'
      else if (Frame[1] and $F0) = $40 then
        Kind := 'ack'
      else if (Frame[1] and $F0) = $50 then
        Kind := 'completion'
      else
        Kind := 'data';
    end;
    TryFinalizeInFlightFromReply(BusIndex, DevIdx, Kind, HexStr);
    Dec := TryDeviceReplyDecodeJson(Frame, Kind);
    if Dec <> '' then
      FLastReplyJson[DevIdx] := Format('{"kind":%s,"viscaHex":%s,"decode":%s}', [JsonQuote(Kind), JsonQuote(HexStr), Dec])
    else
      FLastReplyJson[DevIdx] := Format('{"kind":%s,"viscaHex":%s}', [JsonQuote(Kind), JsonQuote(HexStr)]);
    if Dec <> '' then
      FLastBusDeviceReplyJson[BusIndex] := Format('{"deviceSlug":%s,"kind":%s,"viscaHex":%s,"decode":%s}',
        [JsonQuote(FDeviceConfiguration.ViscaDevices[DevIdx].Slug), JsonQuote(Kind), JsonQuote(HexStr), Dec])
    else
      FLastBusDeviceReplyJson[BusIndex] := Format('{"deviceSlug":%s,"kind":%s,"viscaHex":%s}',
        [JsonQuote(FDeviceConfiguration.ViscaDevices[DevIdx].Slug), JsonQuote(Kind), JsonQuote(HexStr)]);
    PublishControllerBusSnapshot(BusIndex);
    PublishDeviceTelemetry(FDeviceConfiguration.ViscaDevices[DevIdx].Slug, Kind, HexStr, Dec);
    PublishDeviceStatusMerge(FDeviceConfiguration.ViscaDevices[DevIdx].Slug, DevIdx);
    Exit;
  end;
  LogFmt(llDebug, 'visca: unhandled frame on bus %s: %s', [BusId, HexStr]);
end;

procedure TCommandRouter.Tick;
var
  BusIndex: Integer;
  NowTick: QWord;
begin
  NowTick := GetTickCount64;
  for BusIndex := 0 to High(FCommandQueuesPerBus) do
  begin
    if SameText(FDeviceConfiguration.ViscaBuses[BusIndex].Transport, 'serial') then
      DrainSerialIncoming(BusIndex)
    else
      DrainUdpIncoming(BusIndex);
    AdvanceBusTransmission(BusIndex, NowTick);
  end;
end;

end.

