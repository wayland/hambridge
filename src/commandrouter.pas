unit commandrouter;

{
  MQTT device/# → VISCA bytes via visca-mapping.json, per-bus queue and inter-command spacing.
  v0.2.1: queued commands carry MQTT JSON for framed template encoding.
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils, Classes, ctypes,
  devicesconfig, viscamapping, serialport, logger;

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
    FSerialPorts: array of TSerialPort;
    FCommandQueuesPerBus: array of TFPList;
    FLastTransmitTickPerBus: array of QWord;
    FInterCommandGapMsPerBus: array of Cardinal;
    FMaxQueueDepthPerBus: array of Cardinal;
    function IndexOfSerialBusByConfigId(const BusId: string): Integer;
    function IndexOfViscaDeviceByTopicSlug(const TopicSlug: string): Integer;
    procedure TrimOldestCommandsIfQueueExceedsDepth(SerialBusIndex, DeviceConfigIndex: Integer; MaxDepth: Cardinal);
  public
    constructor Create(const DeviceConfiguration: TDevicesConfig; ViscaCommandMapping: TViscaMapping);
    destructor Destroy; override;
    procedure OnMqttDeviceMessage(Sender: TObject; const Topic, Payload: string);
    procedure Tick;
  end;

implementation

uses
  Math, StrUtils;

constructor TCommandRouter.Create(const DeviceConfiguration: TDevicesConfig; ViscaCommandMapping: TViscaMapping);
var
  BusLoopIndex, DeviceLoopIndex: Integer;
  SerialBusIndex: Integer;
  DeviceGapMs: Cardinal;
begin
  inherited Create;
  FDeviceConfiguration := DeviceConfiguration;
  FViscaCommandMapping := ViscaCommandMapping;
  SetLength(FSerialPorts, Length(FDeviceConfiguration.Buses));
  SetLength(FCommandQueuesPerBus, Length(FDeviceConfiguration.Buses));
  SetLength(FLastTransmitTickPerBus, Length(FDeviceConfiguration.Buses));
  SetLength(FInterCommandGapMsPerBus, Length(FDeviceConfiguration.Buses));
  SetLength(FMaxQueueDepthPerBus, Length(FDeviceConfiguration.Buses));
  for BusLoopIndex := 0 to High(FDeviceConfiguration.Buses) do
  begin
    FCommandQueuesPerBus[BusLoopIndex] := TFPList.Create;
    FLastTransmitTickPerBus[BusLoopIndex] := 0;
    FInterCommandGapMsPerBus[BusLoopIndex] := 40;
    FMaxQueueDepthPerBus[BusLoopIndex] := 50;
    FSerialPorts[BusLoopIndex] := TSerialPort.Create;
    if not FSerialPorts[BusLoopIndex].Open(FDeviceConfiguration.Buses[BusLoopIndex].Port,
      FDeviceConfiguration.Buses[BusLoopIndex].Baud, FDeviceConfiguration.Buses[BusLoopIndex].DataBits,
      FDeviceConfiguration.Buses[BusLoopIndex].Parity, FDeviceConfiguration.Buses[BusLoopIndex].StopBits) then
      LogFmt(llWarn, 'visca: could not open serial bus "%s" (%s)',
        [FDeviceConfiguration.Buses[BusLoopIndex].Id, FDeviceConfiguration.Buses[BusLoopIndex].Port]);
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

procedure TCommandRouter.Tick;
var
  SerialBusIndex: Integer;
  NowTick: QWord;
  QueuedCommand: TQueuedViscaCommand;
  ViscaPacket: TBytes;
  DeviceRow: TViscaDeviceConfig;
begin
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
