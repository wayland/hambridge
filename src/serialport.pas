unit serialport;

{
  Minimal Linux serial TX for VISCA: configure line with stty(1), then write(2) on a raw fd.
  v0.2 is transmit-only; non-blocking read is reserved for v0.3 ACK handling.
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils, Classes, ctypes, BaseUnix;

type
  TSerialPort = class
  private
    FSerialDevicePath: string;
    FSerialFileDescriptor: cint;
    function RunStty(const Port: string; Baud: Integer; DataBits: Integer; Parity: Char;
      StopBits: Integer): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function Open(const Port: string; Baud: Integer; DataBits: Integer; Parity: Char;
      StopBits: Integer): Boolean;
    procedure ClosePort;
    function WriteBuf(const Buf; Len: SizeUInt): Boolean;
    property SerialDevicePath: string read FSerialDevicePath;
    property SerialFileDescriptor: cint read FSerialFileDescriptor;
  end;

implementation

uses
  Process;

constructor TSerialPort.Create;
begin
  inherited Create;
  FSerialFileDescriptor := -1;
  FSerialDevicePath := '';
end;

destructor TSerialPort.Destroy;
begin
  ClosePort;
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

function TSerialPort.Open(const Port: string; Baud: Integer; DataBits: Integer; Parity: Char;
  StopBits: Integer): Boolean;
begin
  ClosePort;
  FSerialDevicePath := Port;
  if not FileExists(Port) then
    Exit(False);
  if not RunStty(Port, Baud, DataBits, Parity, StopBits) then
    ;
  FSerialFileDescriptor := fpOpen(PChar(Port), O_RDWR or O_NOCTTY or O_NONBLOCK);
  Result := FSerialFileDescriptor >= 0;
  if not Result then
    FSerialFileDescriptor := -1;
end;

procedure TSerialPort.ClosePort;
begin
  if FSerialFileDescriptor >= 0 then
  begin
    fpClose(FSerialFileDescriptor);
    FSerialFileDescriptor := -1;
  end;
  FSerialDevicePath := '';
end;

function TSerialPort.WriteBuf(const Buf; Len: SizeUInt): Boolean;
var
  WrittenCount: ssize_t;
begin
  Result := False;
  if FSerialFileDescriptor < 0 then
    Exit;
  WrittenCount := fpWrite(FSerialFileDescriptor, @Buf, Len);
  Result := WrittenCount = ssize_t(Len);
end;

end.
