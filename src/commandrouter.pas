unit commandrouter;

{
  v0.2: MQTT device/# → VISCA bytes via visca-mapping.json, per-bus queue and inter-command spacing.
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils, Classes, ctypes,
  devicesconfig, viscamapping, serialport, logger;

type
  TQueuedViscaCmd = class
    DevIdx: Integer;
    BusIdx: Integer;
    Topic: string;
    CommandPath: string;
  end;

  TCommandRouter = class
  private
    FDev: TDevicesConfig;
    FMapping: TViscaMapping;
    FPorts: array of TSerialPort;
    FQueues: array of TFPList;
    FLastSend: array of QWord;
    FGapMs: array of Cardinal;
    FMaxDepth: array of Cardinal;
    function BusIndexById(const BusId: string): Integer;
    function DeviceIndexById(const IdStr: string): Integer;
    procedure TrimQueueIfNeeded(BusIdx, DevIdx: Integer; MaxDepth: Cardinal);
  public
    constructor Create(const ADev: TDevicesConfig; AMapping: TViscaMapping);
    destructor Destroy; override;
    procedure OnMqttDeviceMessage(Sender: TObject; const Topic, Payload: string);
    procedure Tick;
  end;

implementation

uses
  Math, StrUtils;

constructor TCommandRouter.Create(const ADev: TDevicesConfig; AMapping: TViscaMapping);
var
  I, J, bi: Integer;
  gap: Cardinal;
begin
  inherited Create;
  FDev := ADev;
  FMapping := AMapping;
  SetLength(FPorts, Length(FDev.Buses));
  SetLength(FQueues, Length(FDev.Buses));
  SetLength(FLastSend, Length(FDev.Buses));
  SetLength(FGapMs, Length(FDev.Buses));
  SetLength(FMaxDepth, Length(FDev.Buses));
  for I := 0 to High(FDev.Buses) do
  begin
    FQueues[I] := TFPList.Create;
    FLastSend[I] := 0;
    FGapMs[I] := 40;
    FMaxDepth[I] := 50;
    FPorts[I] := TSerialPort.Create;
    if not FPorts[I].Open(FDev.Buses[I].Port, FDev.Buses[I].Baud, FDev.Buses[I].DataBits,
      FDev.Buses[I].Parity, FDev.Buses[I].StopBits) then
      LogFmt(llWarn, 'visca: could not open serial bus "%s" (%s)', [FDev.Buses[I].Id, FDev.Buses[I].Port]);
  end;
  for J := 0 to High(FDev.ViscaDevices) do
  begin
    bi := BusIndexById(FDev.ViscaDevices[J].BusId);
    if bi < 0 then
      Continue;
    gap := FDev.ViscaDevices[J].MinInterCommandMs;
    if gap > FGapMs[bi] then
      FGapMs[bi] := gap;
    if FDev.ViscaDevices[J].MaxQueueDepth > FMaxDepth[bi] then
      FMaxDepth[bi] := FDev.ViscaDevices[J].MaxQueueDepth;
  end;
end;

destructor TCommandRouter.Destroy;
var
  I, K: Integer;
  Q: TFPList;
  C: TQueuedViscaCmd;
begin
  for I := 0 to High(FQueues) do
  begin
    Q := FQueues[I];
    if Q <> nil then
    begin
      for K := 0 to Q.Count - 1 do
      begin
        C := TQueuedViscaCmd(Q[K]);
        C.Free;
      end;
      Q.Free;
    end;
    FPorts[I].Free;
  end;
  inherited Destroy;
end;

function TCommandRouter.BusIndexById(const BusId: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FDev.Buses) do
    if SameText(FDev.Buses[I].Id, BusId) then
      Exit(I);
  Result := -1;
end;

function TCommandRouter.DeviceIndexById(const IdStr: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FDev.ViscaDevices) do
    if SameText(FDev.ViscaDevices[I].Id, IdStr) then
      Exit(I);
  Result := -1;
end;

procedure TCommandRouter.TrimQueueIfNeeded(BusIdx, DevIdx: Integer; MaxDepth: Cardinal);
var
  Q: TFPList;
  K, cnt: Integer;
  C: TQueuedViscaCmd;
begin
  Q := FQueues[BusIdx];
  cnt := 0;
  for K := 0 to Q.Count - 1 do
    if TQueuedViscaCmd(Q[K]).DevIdx = DevIdx then
      Inc(cnt);
  while cnt >= Integer(MaxDepth) do
  begin
    for K := 0 to Q.Count - 1 do
    begin
      C := TQueuedViscaCmd(Q[K]);
      if C.DevIdx = DevIdx then
      begin
        LogFmt(llWarn, 'visca: queue overflow bus %s device %s — dropping oldest',
          [FDev.Buses[BusIdx].Id, FDev.ViscaDevices[DevIdx].Id]);
        Q.Delete(K);
        C.Free;
        Dec(cnt);
        Break;
      end;
    end;
  end;
end;

procedure TCommandRouter.OnMqttDeviceMessage(Sender: TObject; const Topic, Payload: string);
var
  pl: string;
var
  p: Integer;
  rest: string;
  idStr, cmdPath: string;
  di, bi: Integer;
  cmd: TQueuedViscaCmd;
begin
  pl := Trim(Payload);
  if pl <> '' then
    LogFmt(llDebug, 'visca: mqtt payload ignored in v0.2 (len=%u)', [Length(pl)]);
  if not StartsText('device/', Topic) then
    Exit;
  rest := Copy(Topic, Length('device/') + 1, MaxInt);
  p := Pos('/', rest);
  if p <= 0 then
    Exit;
  idStr := Copy(rest, 1, p - 1);
  cmdPath := Copy(rest, p + 1, MaxInt);
  if cmdPath = '' then
    Exit;
  di := DeviceIndexById(idStr);
  if di < 0 then
  begin
    LogFmt(llDebug, 'visca: unknown device id in topic %s', [Topic]);
    Exit;
  end;
  bi := BusIndexById(FDev.ViscaDevices[di].BusId);
  if bi < 0 then
  begin
    LogFmt(llWarn, 'visca: device %s references unknown bus', [idStr]);
    Exit;
  end;
  if Length(FMapping.EncodeCommand(FDev.ViscaDevices[di].Model, FDev.ViscaDevices[di].ViscaAddress,
    cmdPath)) = 0 then
  begin
    LogFmt(llDebug, 'visca: no mapping for topic %s (model %s)', [Topic, FDev.ViscaDevices[di].Model]);
    Exit;
  end;
  TrimQueueIfNeeded(bi, di, FDev.ViscaDevices[di].MaxQueueDepth);
  cmd := TQueuedViscaCmd.Create;
  cmd.DevIdx := di;
  cmd.BusIdx := bi;
  cmd.Topic := Topic;
  cmd.CommandPath := cmdPath;
  FQueues[bi].Add(cmd);
end;

procedure TCommandRouter.Tick;
var
  bi: Integer;
  nowt: QWord;
  cmd: TQueuedViscaCmd;
  pkt: TBytes;
  dev: TViscaDeviceConfig;
begin
  nowt := GetTickCount64;
  for bi := 0 to High(FQueues) do
  begin
    if FQueues[bi].Count = 0 then
      Continue;
    if FPorts[bi].Handle < 0 then
      Continue;
    if nowt < FLastSend[bi] + FGapMs[bi] then
      Continue;
    cmd := TQueuedViscaCmd(FQueues[bi][0]);
    dev := FDev.ViscaDevices[cmd.DevIdx];
    pkt := FMapping.EncodeCommand(dev.Model, dev.ViscaAddress, cmd.CommandPath);
    if Length(pkt) = 0 then
    begin
      FQueues[bi].Delete(0);
      cmd.Free;
      Continue;
    end;
    if not FPorts[bi].WriteBuf(pkt[0], Length(pkt)) then
      LogFmt(llWarn, 'visca: short write on bus %s', [FDev.Buses[bi].Id])
    else
      LogFmt(llDebug, 'visca: sent %u bytes to %s for %s', [Length(pkt), FDev.Buses[bi].Id, cmd.Topic]);
    FQueues[bi].Delete(0);
    cmd.Free;
    FLastSend[bi] := nowt;
    Exit;
  end;
end;

end.
