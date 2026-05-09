unit udpport;

{
  VISCA over UDP transport (v0.4.4): bind a UDP socket, receive datagrams non-blocking, and send
  raw VISCA frames (bytes terminated by 0xFF) to a configured remote host/port.
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils, Classes, ctypes, BaseUnix, Sockets;

type
  TUdpViscaPort = class
  private
    FFd: cint;
    FBindHost: string;
    FBindPort: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    function Open(const BindHost: string; BindPort: Integer): Boolean;
    procedure ClosePort;
    function IsOpen: Boolean;
    function RecvDatagram(out Data: TBytes; out RemoteHost: string; out RemotePort: Integer): Boolean;
    function SendTo(const Data: TBytes; const Host: string; Port: Integer): Boolean;
    property Fd: cint read FFd;
  end;

implementation

constructor TUdpViscaPort.Create;
begin
  inherited Create;
  FFd := -1;
  FBindHost := '';
  FBindPort := 0;
end;

destructor TUdpViscaPort.Destroy;
begin
  ClosePort;
  inherited Destroy;
end;

procedure TUdpViscaPort.ClosePort;
begin
  if FFd >= 0 then
  begin
    FpClose(FFd);
    FFd := -1;
  end;
end;

function TUdpViscaPort.IsOpen: Boolean;
begin
  Result := FFd >= 0;
end;

function TUdpViscaPort.Open(const BindHost: string; BindPort: Integer): Boolean;
var
  sa: TInetSockAddr;
begin
  Result := False;
  ClosePort;
  if (BindPort <= 0) or (BindPort > 65535) then
    Exit(False);
  FFd := fpSocket(AF_INET, SOCK_DGRAM, 0);
  if FFd < 0 then
  begin
    FFd := -1;
    Exit(False);
  end;

  { Non-blocking. }
  fpfcntl(FFd, F_SETFL, fpfcntl(FFd, F_GETFL, 0) or O_NONBLOCK);

  FillChar(sa, SizeOf(sa), 0);
  sa.sin_family := AF_INET;
  sa.sin_port := htons(Word(BindPort));
  if Trim(BindHost) = '' then
    sa.sin_addr := StrToNetAddr('0.0.0.0')
  else
    sa.sin_addr := StrToNetAddr(BindHost);

  if fpBind(FFd, @sa, SizeOf(sa)) <> 0 then
  begin
    ClosePort;
    Exit(False);
  end;

  FBindHost := BindHost;
  FBindPort := BindPort;
  Result := True;
end;

function TUdpViscaPort.RecvDatagram(out Data: TBytes; out RemoteHost: string; out RemotePort: Integer): Boolean;
var
  sa: TInetSockAddr;
  salen: TSockLen;
  buf: array[0..2047] of Byte;
  r: ssize_t;
  err: cint;
begin
  Result := False;
  SetLength(Data, 0);
  RemoteHost := '';
  RemotePort := 0;
  if FFd < 0 then
    Exit;
  FillChar(sa, SizeOf(sa), 0);
  salen := SizeOf(sa);
  r := fpRecvFrom(FFd, @buf[0], SizeOf(buf), 0, @sa, @salen);
  if r < 0 then
  begin
    err := fpGetErrno;
    if (err = ESysEAGAIN) or (err = ESysEWOULDBLOCK) then
      Exit(False);
    Exit(False);
  end;
  if r = 0 then
    Exit(False);
  SetLength(Data, r);
  Move(buf[0], Data[0], r);
  RemoteHost := NetAddrToStr(sa.sin_addr);
  RemotePort := ntohs(sa.sin_port);
  Result := True;
end;

function TUdpViscaPort.SendTo(const Data: TBytes; const Host: string; Port: Integer): Boolean;
var
  sa: TInetSockAddr;
  r: ssize_t;
begin
  Result := False;
  if (FFd < 0) or (Length(Data) = 0) then
    Exit;
  if (Port <= 0) or (Port > 65535) then
    Exit;
  FillChar(sa, SizeOf(sa), 0);
  sa.sin_family := AF_INET;
  sa.sin_port := htons(Word(Port));
  sa.sin_addr := StrToNetAddr(Host);
  r := fpSendTo(FFd, @Data[0], Length(Data), 0, @sa, SizeOf(sa));
  Result := r = Length(Data);
end;

end.

