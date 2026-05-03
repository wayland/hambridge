unit commandrouter;

{
  MQTT device/# → VISCA bytes via visca-mapping.json, per-bus queue and inter-command spacing.
  v0.2.1: queued commands carry MQTT JSON for framed template encoding.
  v0.3: serial RX (VISCA frames to FF), decode controller packets → controller/<bus>/event,
        device replies → device/<slug>/telemetry and status snapshot on controller/reply.
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils, Classes, ctypes,
  devicesconfig, viscamapping, serialport, logger, mqttpublisher;

const
  MaxViscaRxAccum = 512;

type
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
    FSerialPorts: array of TSerialPort;
    FCommandQueuesPerBus: array of TFPList;
    FLastTransmitTickPerBus: array of QWord;
    FInterCommandGapMsPerBus: array of Cardinal;
    FMaxQueueDepthPerBus: array of Cardinal;
    FRxAccumPerBus: array of TBytes;
    FLastControllerJson: array of string;
    FLastReplyJson: array of string;
    function IndexOfSerialBusByConfigId(const BusId: string): Integer;
    function IndexOfViscaDeviceByTopicSlug(const TopicSlug: string): Integer;
    function IndexOfViscaDeviceOnBusByReplyByte(SerialBusIndex: Integer; ReplyFirst: Byte): Integer;
    procedure TrimOldestCommandsIfQueueExceedsDepth(SerialBusIndex, DeviceConfigIndex: Integer; MaxDepth: Cardinal);
    procedure DrainSerialIncoming(SerialBusIndex: Integer);
    procedure ConsumeLeadingBytes(var Buf: TBytes; Count: Integer);
    procedure HandleCompleteViscaFrame(SerialBusIndex: Integer; const Frame: TBytes);
    procedure PublishControllerSemantic(const BusId, DeviceSlug, CommandPath, PayloadJson, HexTrace: string);
    procedure PublishControllerRawEvent(const BusId, HexTrace: string);
    procedure PublishDeviceTelemetry(const DeviceSlug, Kind, HexTrace: string);
    procedure PublishDeviceStatusMerge(const DeviceSlug: string; DevIdx: Integer);
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

function TCommandRouter.JsonQuote(const s: string): string;
begin
  Result := '"' + StringReplace(StringReplace(StringReplace(s, '\', '\\', [rfReplaceAll]), '"', '\"', [rfReplaceAll]),
    #10, '\n', [rfReplaceAll]) + '"';
end;

constructor TCommandRouter.Create(const DeviceConfiguration: TDevicesConfig; ViscaCommandMapping: TViscaMapping;
  AMqtt: THaMqttPublisher);
var
  BusLoopIndex, DeviceLoopIndex: Integer;
  SerialBusIndex: Integer;
  DeviceGapMs: Cardinal;
begin
  inherited Create;
  FDeviceConfiguration := DeviceConfiguration;
  FViscaCommandMapping := ViscaCommandMapping;
  FMqtt := AMqtt;
  SetLength(FSerialPorts, Length(FDeviceConfiguration.Buses));
  SetLength(FCommandQueuesPerBus, Length(FDeviceConfiguration.Buses));
  SetLength(FLastTransmitTickPerBus, Length(FDeviceConfiguration.Buses));
  SetLength(FInterCommandGapMsPerBus, Length(FDeviceConfiguration.Buses));
  SetLength(FMaxQueueDepthPerBus, Length(FDeviceConfiguration.Buses));
  SetLength(FRxAccumPerBus, Length(FDeviceConfiguration.Buses));
  for BusLoopIndex := 0 to High(FDeviceConfiguration.Buses) do
  begin
    FCommandQueuesPerBus[BusLoopIndex] := TFPList.Create;
    FLastTransmitTickPerBus[BusLoopIndex] := 0;
    FInterCommandGapMsPerBus[BusLoopIndex] := 40;
    FMaxQueueDepthPerBus[BusLoopIndex] := 50;
    SetLength(FRxAccumPerBus[BusLoopIndex], 0);
    FSerialPorts[BusLoopIndex] := TSerialPort.Create;
    if not FSerialPorts[BusLoopIndex].Open(FDeviceConfiguration.Buses[BusLoopIndex].Port,
      FDeviceConfiguration.Buses[BusLoopIndex].Baud, FDeviceConfiguration.Buses[BusLoopIndex].DataBits,
      FDeviceConfiguration.Buses[BusLoopIndex].Parity, FDeviceConfiguration.Buses[BusLoopIndex].StopBits) then
      LogFmt(llWarn, 'visca: could not open serial bus "%s" (%s)',
        [FDeviceConfiguration.Buses[BusLoopIndex].Id, FDeviceConfiguration.Buses[BusLoopIndex].Port]);
  end;
  SetLength(FLastControllerJson, Length(FDeviceConfiguration.ViscaDevices));
  SetLength(FLastReplyJson, Length(FDeviceConfiguration.ViscaDevices));
  for DeviceLoopIndex := 0 to High(FLastControllerJson) do
  begin
    FLastControllerJson[DeviceLoopIndex] := '';
    FLastReplyJson[DeviceLoopIndex] := '';
  end;
  for DeviceLoopIndex := 0 to High(FDeviceConfiguration.ViscaDevices) do
  begin
    SerialBusIndex := IndexOfSerialBusByConfigId(FDeviceConfiguration.ViscaDevices[DeviceLoopIndex].BusId);
    if SerialBusIndex < 0 then
      Continue;
    DeviceGapMs := FDeviceConfiguration.ViscaDevices[DeviceLoopIndex].MinInterCommandMs;
    if DeviceGapMs > FInterCommandGapMsPerBus[SerialBusIndex] then
      FInterCommandGapMsPerBus[SerialBusIndex] := DeviceGapMs;
    if FDeviceConfiguration.ViscaDevices[DeviceLoopIndex].MaxQueueDepth > FMaxQueueDepthPerBus[SerialBusIndex] then
      FMaxQueueDepthPerBus[SerialBusIndex] := FDeviceConfiguration.ViscaDevices[DeviceLoopIndex].MaxQueueDepth;
  end;
end;

destructor TCommandRouter.Destroy;
var
  BusLoopIndex, QueueSlotIndex: Integer;
  QueueList: TFPList;
  QueuedCommand: TQueuedViscaCommand;
begin
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
    FSerialPorts[BusLoopIndex].Free;
  end;
  inherited Destroy;
end;

function TCommandRouter.IndexOfSerialBusByConfigId(const BusId: string): Integer;
var
  BusLoopIndex: Integer;
begin
  for BusLoopIndex := 0 to High(FDeviceConfiguration.Buses) do
    if SameText(FDeviceConfiguration.Buses[BusLoopIndex].Id, BusId) then
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

function TCommandRouter.IndexOfViscaDeviceOnBusByReplyByte(SerialBusIndex: Integer; ReplyFirst: Byte): Integer;
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
    if IndexOfSerialBusByConfigId(Row.BusId) <> SerialBusIndex then
      Continue;
    Expected := $90 + Row.ViscaAddress - 1;
    if ReplyFirst = Byte(Expected) then
      Exit(DevIdx);
  end;
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
          [FDeviceConfiguration.Buses[SerialBusIndex].Id, FDeviceConfiguration.ViscaDevices[DeviceConfigIndex].Slug]);
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
  DeviceConfigIndex, SerialBusIndex: Integer;
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
  SerialBusIndex := IndexOfSerialBusByConfigId(FDeviceConfiguration.ViscaDevices[DeviceConfigIndex].BusId);
  if SerialBusIndex < 0 then
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
  TrimOldestCommandsIfQueueExceedsDepth(SerialBusIndex, DeviceConfigIndex, DeviceRow.MaxQueueDepth);
  QueuedCommand := TQueuedViscaCommand.Create;
  QueuedCommand.DeviceConfigIndex := DeviceConfigIndex;
  QueuedCommand.SerialBusIndex := SerialBusIndex;
  QueuedCommand.MqttTopic := Topic;
  QueuedCommand.ViscaCommandPath := ViscaCommandPath;
  QueuedCommand.MqttPayloadJson := Payload;
  FCommandQueuesPerBus[SerialBusIndex].Add(QueuedCommand);
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

procedure TCommandRouter.DrainSerialIncoming(SerialBusIndex: Integer);
var
  I, Start: Integer;
  FrameLen: Integer;
  Frame: TBytes;
begin
  if FSerialPorts[SerialBusIndex].SerialFileDescriptor < 0 then
    Exit;
  FSerialPorts[SerialBusIndex].ReadNonBlockingAppend(FRxAccumPerBus[SerialBusIndex], 256);
  if Length(FRxAccumPerBus[SerialBusIndex]) > MaxViscaRxAccum then
  begin
    LogFmt(llWarn, 'visca: rx buffer overflow bus %s — clearing', [FDeviceConfiguration.Buses[SerialBusIndex].Id]);
    SetLength(FRxAccumPerBus[SerialBusIndex], 0);
    Exit;
  end;
  Start := 0;
  I := 0;
  while I <= High(FRxAccumPerBus[SerialBusIndex]) do
  begin
    if FRxAccumPerBus[SerialBusIndex][I] = $FF then
    begin
      FrameLen := I - Start + 1;
      SetLength(Frame, FrameLen);
      if FrameLen > 0 then
        Move(FRxAccumPerBus[SerialBusIndex][Start], Frame[0], FrameLen);
      HandleCompleteViscaFrame(SerialBusIndex, Frame);
      Start := I + 1;
    end;
    Inc(I);
  end;
  if Start > 0 then
    ConsumeLeadingBytes(FRxAccumPerBus[SerialBusIndex], Start);
end;

procedure TCommandRouter.PublishControllerSemantic(const BusId, DeviceSlug, CommandPath, PayloadJson, HexTrace: string);
var
  Js: string;
  Ts: Int64;
begin
  if FMqtt = nil then
    Exit;
  Ts := Int64(DateTimeToUnix(Now, True)) * 1000;
  Js := Format('{"ts":%d,"bus":%s,"source":"controller","command":%s,"deviceSlug":%s,"payload":%s,"trace":{"viscaHex":%s}}',
    [Ts, JsonQuote(BusId), JsonQuote(CommandPath), JsonQuote(DeviceSlug), PayloadJson, JsonQuote(HexTrace)]);
  FMqtt.PublishJson('controller/' + BusId + '/event', Js);
end;

procedure TCommandRouter.PublishControllerRawEvent(const BusId, HexTrace: string);
var
  Js: string;
  Ts: Int64;
begin
  if FMqtt = nil then
    Exit;
  Ts := Int64(DateTimeToUnix(Now, True)) * 1000;
  Js := Format('{"ts":%d,"bus":%s,"source":"controller","command":"event","payload":{"raw":true,"viscaHex":%s},"trace":{"viscaHex":%s}}',
    [Ts, JsonQuote(BusId), JsonQuote(HexTrace), JsonQuote(HexTrace)]);
  FMqtt.PublishJson('controller/' + BusId + '/event', Js);
end;

procedure TCommandRouter.PublishDeviceTelemetry(const DeviceSlug, Kind, HexTrace: string);
var
  Js: string;
  Ts: Int64;
begin
  if FMqtt = nil then
    Exit;
  Ts := Int64(DateTimeToUnix(Now, True)) * 1000;
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
  Body := Format('{"ts":%d,"lastController":%s,"lastReply":%s}', [Ts, Ctrl, Rep]);
  FMqtt.PublishJson('device/' + DeviceSlug + '/status', Body);
end;

procedure TCommandRouter.HandleCompleteViscaFrame(SerialBusIndex: Integer; const Frame: TBytes);
var
  BusId: string;
  B0: Byte;
  DevIdx: Integer;
  Row: TViscaDeviceConfig;
  TopicPath, PayloadJson: string;
  HexStr: string;
  Kind: string;
  Expected: Integer;
  CtrlJson: string;
begin
  if Length(Frame) < 2 then
    Exit;
  BusId := FDeviceConfiguration.Buses[SerialBusIndex].Id;
  HexStr := TViscaMapping.ViscaPacketToHex(Frame);
  B0 := Frame[0];
  if (B0 >= $81) and (B0 <= $87) then
  begin
    for DevIdx := 0 to High(FDeviceConfiguration.ViscaDevices) do
    begin
      Row := FDeviceConfiguration.ViscaDevices[DevIdx];
      if IndexOfSerialBusByConfigId(Row.BusId) <> SerialBusIndex then
        Continue;
      Expected := $80 + Row.ViscaAddress;
      if Integer(B0) <> Expected then
        Continue;
      if FViscaCommandMapping.TryDecodeControllerPacket(Row.Model, Frame, TopicPath, PayloadJson) then
      begin
        PublishControllerSemantic(BusId, Row.Slug, TopicPath, PayloadJson, HexStr);
        CtrlJson := Format('{"command":%s,"payload":%s,"viscaHex":%s}', [JsonQuote(TopicPath), PayloadJson, JsonQuote(HexStr)]);
        FLastControllerJson[DevIdx] := CtrlJson;
      end
      else
      begin
        PublishControllerRawEvent(BusId, HexStr);
        CtrlJson := Format('{"command":"event","payload":{"viscaHex":%s},"viscaHex":%s}', [JsonQuote(HexStr), JsonQuote(HexStr)]);
        FLastControllerJson[DevIdx] := CtrlJson;
      end;
      PublishDeviceStatusMerge(Row.Slug, DevIdx);
      Exit;
    end;
    LogFmt(llDebug, 'visca: controller frame %s on bus %s — no device for address byte %02x', [HexStr, BusId, B0]);
    PublishControllerRawEvent(BusId, HexStr);
    Exit;
  end;
  if (B0 >= $90) and (B0 <= $96) then
  begin
    DevIdx := IndexOfViscaDeviceOnBusByReplyByte(SerialBusIndex, B0);
    if DevIdx < 0 then
    begin
      LogFmt(llDebug, 'visca: reply %s on bus %s — no matching device', [HexStr, BusId]);
      Exit;
    end;
    Kind := 'other';
    if Length(Frame) >= 2 then
    begin
      case Frame[1] of
        $40:
          Kind := 'ack';
        $41..$45:
          Kind := 'completion';
        $60:
          Kind := 'error';
      else
        Kind := 'data';
      end;
    end;
    PublishDeviceTelemetry(FDeviceConfiguration.ViscaDevices[DevIdx].Slug, Kind, HexStr);
    FLastReplyJson[DevIdx] := Format('{"kind":%s,"viscaHex":%s}', [JsonQuote(Kind), JsonQuote(HexStr)]);
    PublishDeviceStatusMerge(FDeviceConfiguration.ViscaDevices[DevIdx].Slug, DevIdx);
    Exit;
  end;
  LogFmt(llDebug, 'visca: unhandled frame on bus %s: %s', [BusId, HexStr]);
end;

procedure TCommandRouter.Tick;
var
  SerialBusIndex: Integer;
  NowTick: QWord;
  QueuedCommand: TQueuedViscaCommand;
  ViscaPacket: TBytes;
  DeviceRow: TViscaDeviceConfig;
begin
  for SerialBusIndex := 0 to High(FSerialPorts) do
    DrainSerialIncoming(SerialBusIndex);
  NowTick := GetTickCount64;
  for SerialBusIndex := 0 to High(FCommandQueuesPerBus) do
  begin
    if FCommandQueuesPerBus[SerialBusIndex].Count = 0 then
      Continue;
    if FSerialPorts[SerialBusIndex].SerialFileDescriptor < 0 then
      Continue;
    if NowTick < FLastTransmitTickPerBus[SerialBusIndex] + FInterCommandGapMsPerBus[SerialBusIndex] then
      Continue;
    QueuedCommand := TQueuedViscaCommand(FCommandQueuesPerBus[SerialBusIndex][0]);
    DeviceRow := FDeviceConfiguration.ViscaDevices[QueuedCommand.DeviceConfigIndex];
    ViscaPacket := FViscaCommandMapping.EncodeViscaCommand(DeviceRow.Model, DeviceRow.ViscaAddress,
      QueuedCommand.ViscaCommandPath, QueuedCommand.MqttPayloadJson);
    if Length(ViscaPacket) = 0 then
    begin
      FCommandQueuesPerBus[SerialBusIndex].Delete(0);
      QueuedCommand.Free;
      Continue;
    end;
    if not FSerialPorts[SerialBusIndex].WriteBuf(ViscaPacket[0], Length(ViscaPacket)) then
      LogFmt(llWarn, 'visca: short write on bus %s', [FDeviceConfiguration.Buses[SerialBusIndex].Id])
    else
      LogFmt(llDebug, 'visca: sent %u bytes to %s for %s', [Length(ViscaPacket),
        FDeviceConfiguration.Buses[SerialBusIndex].Id, QueuedCommand.MqttTopic]);
    FCommandQueuesPerBus[SerialBusIndex].Delete(0);
    QueuedCommand.Free;
    FLastTransmitTickPerBus[SerialBusIndex] := NowTick;
    Exit;
  end;
end;

end.

