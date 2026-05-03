unit serialport;

{
  Linux serial for VISCA: stty(1), non-blocking read/write, TX queue (partial write + EAGAIN),
  optional RS-485 ioctl (TIOCSRS485), and reopen with backoff after hard I/O errors.
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils, Classes, ctypes, BaseUnix, devicesconfig;

const
  MaxSerialTxQueue = 8192;
  SerialReopenBackoffInitialMs = 500;
  SerialReopenBackoffMaxMs = 30000;

type
  TSerialPumpResult = (sprDone, sprAgain, sprError);

  TSerialPort = class
  private
    FSerialDevicePath: string;
    FSerialFileDescriptor: cint;
    FPendingTx: TBytes;
    FBaud: Integer;
    FDataBits: Integer;
    FParity: Char;
    FStopBits: Integer;
    FRs485: TRs485BusConfig;
    FReopenNextTick: QWord;
    FReopenBackoffMs: Cardinal;
    function RunStty(const Port: string; Baud: Integer; DataBits: Integer; Parity: Char;
      StopBits: Integer): Boolean;
    function ApplyRs485Ioctl: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function Open(const Port: string; Baud: Integer; DataBits: Integer; Parity: Char;
      StopBits: Integer; const Rs485: TRs485BusConfig): Boolean;
    procedure ClosePort;
    { Appends data to the software TX queue (drops and returns False if over MaxSerialTxQueue). }
    function QueueTransmit(const Data: TBytes): Boolean;
    { Writes as much as possible to the fd (handles partial write and EAGAIN). }
    function PumpTransmit: TSerialPumpResult;
    function HasPendingTransmit: Boolean;
    { Legacy: enqueue + pump until empty or error; True if all bytes reached the driver. }
    function WriteBuf(const Buf; Len: SizeUInt): Boolean;
    { Appends up to MaxChunk bytes from the port into Dest (non-blocking). Returns bytes read, or -1 on hard error. }
    function ReadNonBlockingAppend(var Dest: TBytes; MaxChunk: Integer): Integer;
    { When fd is closed after error, call each tick until open succeeds or backoff not elapsed. }
    function TryScheduledReopen(NowTick: QWord): Boolean;
    procedure ScheduleReopen(NowTick: QWord);
    property SerialDevicePath: string read FSerialDevicePath;
    property SerialFileDescriptor: cint read FSerialFileDescriptor;
  end;

implementation

uses
  Process, Errors, Math, logger;

const
  TIOCSRS485 = $542F;
  SER_RS485_ENABLED = 1 shl 0;
  SER_RS485_RTS_ON_SEND = 1 shl 1;
  SER_RS485_RTS_AFTER_SEND = 1 shl 2;

type
  TSerialRs485Ioctl = packed record
    flags: cuint;
    delay_rts_before_send: cuint;
    delay_rts_after_send: cuint;
    padding: array[0..4] of cuint;
  end;

constructor TSerialPort.Create;
begin
  inherited Create;
  FSerialFileDescriptor := -1;
  FSerialDevicePath := '';
  SetLength(FPendingTx, 0);
  FReopenNextTick := 0;
  FReopenBackoffMs := SerialReopenBackoffInitialMs;
  FillChar(FRs485, SizeOf(FRs485), 0);
end;

destructor TSerialPort.Destroy;
begin
  ClosePort;
  FSerialDevicePath := '';
  inherited Destroy;
end;

procedure AddSttyDataBits(Process: TProcess; DataBits: Integer);
begin
  case DataBits of
    5: Process.Parameters.Add('cs5');
    6: Process.Parameters.Add('cs6');
    7: Process.Parameters.Add('cs7');
  else
    Process.Parameters.Add('cs8');
  end;
end;

procedure AddSttyParity(Process: TProcess; Parity: Char);
begin
  case UpCase(Parity) of
    'E':
      begin
        Process.Parameters.Add('parenb');
        Process.Parameters.Add('-parodd');
      end;
    'O':
      begin
        Process.Parameters.Add('parenb');
        Process.Parameters.Add('parodd');
      end;
  else
    Process.Parameters.Add('-parenb');
  end;
end;

function TSerialPort.RunStty(const Port: string; Baud: Integer; DataBits: Integer; Parity: Char;
  StopBits: Integer): Boolean;
var
  SttyProcess: TProcess;
begin
  Result := False;
  SttyProcess := TProcess.Create(nil);
  try
    SttyProcess.Executable := '/usr/bin/stty';
    SttyProcess.Parameters.Add('-F');
    SttyProcess.Parameters.Add(Port);
    SttyProcess.Parameters.Add(IntToStr(Baud));
    SttyProcess.Parameters.Add('raw');
    SttyProcess.Parameters.Add('-echo');
    SttyProcess.Parameters.Add('-echoe');
    SttyProcess.Parameters.Add('-icanon');
    if StopBits = 2 then
      SttyProcess.Parameters.Add('cstopb')
    else
      SttyProcess.Parameters.Add('-cstopb');
    AddSttyParity(SttyProcess, Parity);
    AddSttyDataBits(SttyProcess, DataBits);
    SttyProcess.Options := [poWaitOnExit, poStderrToOutPut];
    try
      SttyProcess.Execute;
      Result := (SttyProcess.ExitStatus = 0);
    except
      Result := False;
    end;
  finally
    SttyProcess.Free;
  end;
end;

function TSerialPort.ApplyRs485Ioctl: Boolean;
var
  R: TSerialRs485Ioctl;
begin
  Result := True;
  if (FSerialFileDescriptor < 0) or not FRs485.Enabled then
    Exit;
  FillChar(R, SizeOf(R), 0);
  R.flags := SER_RS485_ENABLED;
  if FRs485.RtsOnSend then
    R.flags := R.flags or SER_RS485_RTS_ON_SEND;
  if FRs485.RtsAfterSend then
    R.flags := R.flags or SER_RS485_RTS_AFTER_SEND;
  R.delay_rts_before_send := FRs485.DelayRtsBeforeSend;
  R.delay_rts_after_send := FRs485.DelayRtsAfterSend;
  Result := FpIOCtl(FSerialFileDescriptor, TIOCSRS485, @R) = 0;
end;

function TSerialPort.Open(const Port: string; Baud: Integer; DataBits: Integer; Parity: Char;
  StopBits: Integer; const Rs485: TRs485BusConfig): Boolean;
begin
  ClosePort;
  FRs485 := Rs485;
  FSerialDevicePath := Port;
  FBaud := Baud;
  FDataBits := DataBits;
  FParity := Parity;
  FStopBits := StopBits;
  if not FileExists(Port) then
    Exit(False);
  if not RunStty(Port, Baud, DataBits, Parity, StopBits) then
    ;
  FSerialFileDescriptor := fpOpen(PChar(Port), O_RDWR or O_NOCTTY or O_NONBLOCK);
  Result := FSerialFileDescriptor >= 0;
  if not Result then
  begin
    FSerialFileDescriptor := -1;
    Exit;
  end;
  if FRs485.Enabled and not ApplyRs485Ioctl then
    LogFmt(llWarn, 'serial: TIOCSRS485 failed for %s (errno %d)', [Port, fpGetErrno]);
  FReopenBackoffMs := SerialReopenBackoffInitialMs;
  FReopenNextTick := 0;
end;

procedure TSerialPort.ClosePort;
begin
  if FSerialFileDescriptor >= 0 then
  begin
    fpClose(FSerialFileDescriptor);
    FSerialFileDescriptor := -1;
  end;
  SetLength(FPendingTx, 0);
end;

procedure TSerialPort.ScheduleReopen(NowTick: QWord);
begin
  ClosePort;
  if FReopenNextTick < NowTick then
    FReopenNextTick := NowTick + FReopenBackoffMs;
  if FReopenBackoffMs < SerialReopenBackoffMaxMs then
    FReopenBackoffMs := Min(FReopenBackoffMs * 2, SerialReopenBackoffMaxMs);
end;

function TSerialPort.TryScheduledReopen(NowTick: QWord): Boolean;
begin
  Result := False;
  if FSerialFileDescriptor >= 0 then
    Exit(True);
  if FSerialDevicePath = '' then
    Exit(False);
  if NowTick < FReopenNextTick then
    Exit(False);
  Result := Open(FSerialDevicePath, FBaud, FDataBits, FParity, FStopBits, FRs485);
  if Result then
  begin
    LogFmt(llInfo, 'serial: reopened %s', [FSerialDevicePath]);
    FReopenBackoffMs := SerialReopenBackoffInitialMs;
  end
  else
    FReopenNextTick := NowTick + FReopenBackoffMs;
end;

function TSerialPort.QueueTransmit(const Data: TBytes): Boolean;
var
  OldLen, N, I: Integer;
begin
  Result := False;
  N := Length(Data);
  if N <= 0 then
    Exit(True);
  OldLen := Length(FPendingTx);
  if OldLen + N > MaxSerialTxQueue then
    Exit;
  SetLength(FPendingTx, OldLen + N);
  for I := 0 to N - 1 do
    FPendingTx[OldLen + I] := Data[I];
  Result := True;
end;

function TSerialPort.HasPendingTransmit: Boolean;
begin
  Result := Length(FPendingTx) > 0;
end;

procedure ConsumeTxLeading(var Buf: TBytes; Count: Integer);
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

function TSerialPort.PumpTransmit: TSerialPumpResult;
var
  WrittenCount: ssize_t;
  ErrNo: cint;
begin
  if FSerialFileDescriptor < 0 then
  begin
    if HasPendingTransmit then
      Exit(sprError);
    Exit(sprDone);
  end;
  while Length(FPendingTx) > 0 do
  begin
    WrittenCount := fpWrite(FSerialFileDescriptor, @FPendingTx[0], Length(FPendingTx));
    if WrittenCount < 0 then
    begin
      ErrNo := fpGetErrno;
      if (ErrNo = ESysEAGAIN) or (ErrNo = ESysEWOULDBLOCK) then
        Exit(sprAgain);
      LogFmt(llWarn, 'serial: write error on %s errno %d', [FSerialDevicePath, ErrNo]);
      ScheduleReopen(GetTickCount64);
      Exit(sprError);
    end;
    if WrittenCount = 0 then
      Exit(sprAgain);
    ConsumeTxLeading(FPendingTx, Integer(WrittenCount));
  end;
  Result := sprDone;
end;

function TSerialPort.WriteBuf(const Buf; Len: SizeUInt): Boolean;
var
  Tmp: TBytes;
  I: Integer;
  P: PByte;
begin
  SetLength(Tmp, Integer(Len));
  if Len > 0 then
  begin
    P := @Buf;
    for I := 0 to Integer(Len) - 1 do
      Tmp[I] := P[I];
  end;
  Result := QueueTransmit(Tmp) and (PumpTransmit = sprDone);
end;

function TSerialPort.ReadNonBlockingAppend(var Dest: TBytes; MaxChunk: Integer): Integer;
var
  Chunk: array[0..511] of Byte;
  ReadCount: ssize_t;
  OldLen, I: Integer;
  ErrNo: cint;
begin
  Result := 0;
  if FSerialFileDescriptor < 0 then
    Exit(0);
  if MaxChunk > SizeInt(Length(Chunk)) then
    MaxChunk := Length(Chunk);
  ReadCount := fpRead(FSerialFileDescriptor, @Chunk[0], MaxChunk);
  if ReadCount < 0 then
  begin
    ErrNo := fpGetErrno;
    if (ErrNo = ESysEAGAIN) or (ErrNo = ESysEWOULDBLOCK) then
      Exit(0);
    LogFmt(llWarn, 'serial: read error on %s errno %d', [FSerialDevicePath, ErrNo]);
    Exit(-1);
  end;
  if ReadCount = 0 then
    Exit(0);
  OldLen := Length(Dest);
  SetLength(Dest, OldLen + ReadCount);
  for I := 0 to ReadCount - 1 do
    Dest[OldLen + I] := Chunk[I];
  Result := ReadCount;
end;

end.
