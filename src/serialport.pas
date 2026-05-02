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
    FPath: string;
    FFd: cint;
    function RunStty(const Port: string; Baud: Integer; DataBits: Integer; Parity: Char;
      StopBits: Integer): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    { Opens port, applies 8N1-style termios via stty, leaves fd O_RDWR|O_NONBLOCK. }
    function Open(const Port: string; Baud: Integer; DataBits: Integer; Parity: Char;
      StopBits: Integer): Boolean;
    procedure ClosePort;
    function WriteBuf(const Buf; Len: SizeUInt): Boolean;
    property Path: string read FPath;
    property Handle: cint read FFd;
  end;

implementation

uses
  Process;

constructor TSerialPort.Create;
begin
  inherited Create;
  FFd := -1;
  FPath := '';
end;

destructor TSerialPort.Destroy;
begin
  ClosePort;
  inherited Destroy;
end;

procedure AddSttyDataBits(P: TProcess; DataBits: Integer);
begin
  case DataBits of
    5: P.Parameters.Add('cs5');
    6: P.Parameters.Add('cs6');
    7: P.Parameters.Add('cs7');
  else
    P.Parameters.Add('cs8');
  end;
end;

procedure AddSttyParity(P: TProcess; Parity: Char);
begin
  case UpCase(Parity) of
    'E':
      begin
        P.Parameters.Add('parenb');
        P.Parameters.Add('-parodd');
      end;
    'O':
      begin
        P.Parameters.Add('parenb');
        P.Parameters.Add('parodd');
      end;
  else
    P.Parameters.Add('-parenb');
  end;
end;

function TSerialPort.RunStty(const Port: string; Baud: Integer; DataBits: Integer; Parity: Char;
  StopBits: Integer): Boolean;
var
  P: TProcess;
begin
  Result := False;
  P := TProcess.Create(nil);
  try
    P.Executable := '/usr/bin/stty';
    P.Parameters.Add('-F');
    P.Parameters.Add(Port);
    P.Parameters.Add(IntToStr(Baud));
    P.Parameters.Add('raw');
    P.Parameters.Add('-echo');
    P.Parameters.Add('-echoe');
    P.Parameters.Add('-icanon');
    if StopBits = 2 then
      P.Parameters.Add('cstopb')
    else
      P.Parameters.Add('-cstopb');
    AddSttyParity(P, Parity);
    AddSttyDataBits(P, DataBits);
    P.Options := [poWaitOnExit, poStderrToOutPut];
    try
      P.Execute;
      Result := (P.ExitStatus = 0);
    except
      Result := False;
    end;
  finally
    P.Free;
  end;
end;

function TSerialPort.Open(const Port: string; Baud: Integer; DataBits: Integer; Parity: Char;
  StopBits: Integer): Boolean;
begin
  ClosePort;
  FPath := Port;
  if not FileExists(Port) then
    Exit(False);
  { stty configures the line before we open (common pattern for embedded tools). }
  if not RunStty(Port, Baud, DataBits, Parity, StopBits) then
    ; { continue anyway — some environments lack stty; user may pre-configure port }
  FFd := fpOpen(PChar(Port), O_RDWR or O_NOCTTY or O_NONBLOCK);
  Result := FFd >= 0;
  if not Result then
    FFd := -1;
end;

procedure TSerialPort.ClosePort;
begin
  if FFd >= 0 then
  begin
    fpClose(FFd);
    FFd := -1;
  end;
  FPath := '';
end;

function TSerialPort.WriteBuf(const Buf; Len: SizeUInt): Boolean;
var
  n: ssize_t;
begin
  Result := False;
  if FFd < 0 then
    Exit;
  n := fpWrite(FFd, @Buf, Len);
  Result := n = ssize_t(Len);
end;

end.
