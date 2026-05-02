unit evdevreader;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils, Classes, ctypes, BaseUnix, Unix, fpjson,
  devicesconfig, libevdev_binding, logger;

type
  TEvdevPublishEvent = procedure(Sender: TObject; const Topic, Json: string) of object;

  TEvdevInput = class
  private
    FCfg: TEvdevInputConfig;
    FDev: Plibevdev;
    FFd: cint;
    FBackoffMs: Cardinal;
    FNextTryTick: QWord;
    procedure CloseLocked;
    function TryOpen: Boolean;
  public
    constructor Create(const ACfg: TEvdevInputConfig);
    destructor Destroy; override;
    function PollFd: cint;
    procedure TickBackoff;
    { Drain all pending events from this device; calls OnPub for each. }
    procedure DrainEvents(ASender: TObject; OnPub: TEvdevPublishEvent);
    function FormatEventJson(const ev: TInputEvent): string;
    property Cfg: TEvdevInputConfig read FCfg;
  end;

  TEvdevHub = class
  private
    FItems: TFPList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    procedure AddFromConfig(const Dev: TDevicesConfig);
    function Count: Integer;
    function Item(I: Integer): TEvdevInput;
    procedure TickAll;
    procedure BuildPollFds(Fds: TFPList); // list of cint as Pointer-sized store; Fds must be non-nil
    procedure DrainFd(fd: cint; ASender: TObject; OnPub: TEvdevPublishEvent);
  end;

implementation

uses
  Math, DateUtils;

constructor TEvdevInput.Create(const ACfg: TEvdevInputConfig);
begin
  inherited Create;
  FCfg := ACfg;
  FDev := nil;
  FFd := -1;
  FBackoffMs := 1000;
  FNextTryTick := 0;
end;

destructor TEvdevInput.Destroy;
begin
  CloseLocked;
  inherited Destroy;
end;

procedure TEvdevInput.CloseLocked;
begin
  if FDev <> nil then
  begin
    libevdev_free(FDev);
    FDev := nil;
  end;
  if FFd >= 0 then
  begin
    FpClose(FFd);
    FFd := -1;
  end;
end;

function TEvdevInput.TryOpen: Boolean;
var
  r: cint;
begin
  Result := False;
  CloseLocked;
  FFd := fpOpen(PChar(FCfg.DeviceNode), O_RDONLY or O_NONBLOCK);
  if FFd < 0 then
  begin
    LogFmt(llWarn, 'evdev: cannot open %s for input %s: %s', [FCfg.DeviceNode, FCfg.Id, SysErrorMessage(fpgeterrno)]);
    Exit;
  end;
  FDev := libevdev_new;
  if FDev = nil then
  begin
    LogFmt(llError, 'evdev: libevdev_new failed for %s', [FCfg.Id]);
    FpClose(FFd);
    FFd := -1;
    Exit;
  end;
  r := libevdev_set_fd(FDev, FFd);
  if r < 0 then
  begin
    LogFmt(llWarn, 'evdev: libevdev_set_fd failed for %s: errno %d', [FCfg.Id, -Integer(r)]);
    libevdev_free(FDev);
    FDev := nil;
    FpClose(FFd);
    FFd := -1;
    Exit;
  end;
  if FCfg.GrabExclusive then
  begin
    r := libevdev_grab(FDev, LIBEVDEV_MODE_GRAB);
    if r < 0 then
      LogFmt(llWarn, 'evdev: grab failed for %s (continuing without grab): errno %d', [FCfg.Id, -Integer(r)]);
  end;
  LogFmt(llInfo, 'evdev: opened %s (%s)', [FCfg.DeviceNode, FCfg.Id]);
  FBackoffMs := 1000;
  Result := True;
end;

function TEvdevInput.PollFd: cint;
begin
  if FFd >= 0 then
    Exit(FFd);
  Result := -1;
end;

procedure TEvdevInput.TickBackoff;
var
  nowt: QWord;
begin
  if FFd >= 0 then
    Exit;
  nowt := GetTickCount64;
  if nowt < FNextTryTick then
    Exit;
  if not TryOpen then
  begin
    FNextTryTick := nowt + FBackoffMs;
    FBackoffMs := Min(FBackoffMs * 2, 30000);
  end;
end;

function TEvdevInput.FormatEventJson(const ev: TInputEvent): string;
var
  o: TJSONObject;
  typNum, codeNum: Cardinal;
begin
  typNum := ev.ev_type;
  codeNum := ev.code;
  o := TJSONObject.Create;
  try
    o.Add('ts', Int64(DateTimeToUnix(Now, True)) * 1000);
    o.Add('inputId', FCfg.Id);
    o.Add('deviceNode', FCfg.DeviceNode);
    o.Add('source', 'evdev');
    if libevdev_event_type_get_name(typNum) = nil then
      o.Add('type', TJSONNull.Create)
    else
      o.Add('type', string(AnsiString(libevdev_event_type_get_name(typNum))));
    if libevdev_event_code_get_name(typNum, codeNum) = nil then
      o.Add('code', TJSONNull.Create)
    else
      o.Add('code', string(AnsiString(libevdev_event_code_get_name(typNum, codeNum))));
    o.Add('typeNum', Integer(typNum));
    o.Add('codeNum', Integer(codeNum));
    o.Add('value', ev.value);
    Result := o.FormatJSON([]);
  finally
    o.Free;
  end;
end;

procedure TEvdevInput.DrainEvents(ASender: TObject; OnPub: TEvdevPublishEvent);
var
  ev: TInputEvent;
  st: cint;
begin
  if FDev = nil then
    Exit;
  while True do
  begin
    st := libevdev_next_event(FDev, LIBEVDEV_READ_FLAG_NORMAL, @ev);
    if st < 0 then
    begin
      if (-Integer(st)) = ESysEAGAIN then
        Break;
      if (-Integer(st)) = ESysENODEV then
      begin
        LogFmt(llWarn, 'evdev: device removed for %s, reopening', [FCfg.Id]);
        CloseLocked;
        FNextTryTick := GetTickCount64 + 500;
        Break;
      end;
      LogFmt(llWarn, 'evdev: libevdev_next_event errno %d on %s', [-Integer(st), FCfg.Id]);
      Break;
    end;
    if (st = LIBEVDEV_READ_STATUS_SUCCESS) or (st = LIBEVDEV_READ_STATUS_SYNC) then
      OnPub(ASender, FCfg.MqttTopic, FormatEventJson(ev));
  end;
end;

{ TEvdevHub }

constructor TEvdevHub.Create;
begin
  inherited Create;
  FItems := TFPList.Create;
end;

destructor TEvdevHub.Destroy;
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do
    TEvdevInput(FItems[I]).Free;
  FItems.Free;
  inherited Destroy;
end;

procedure TEvdevHub.Clear;
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do
    TEvdevInput(FItems[I]).Free;
  FItems.Clear;
end;

procedure TEvdevHub.AddFromConfig(const Dev: TDevicesConfig);
var
  I: Integer;
  inp: TEvdevInput;
begin
  if not Dev.EvdevEnabled then
    Exit;
  for I := 0 to High(Dev.EvdevInputs) do
  begin
    inp := TEvdevInput.Create(Dev.EvdevInputs[I]);
    FItems.Add(inp);
  end;
end;

function TEvdevHub.Count: Integer;
begin
  Result := FItems.Count;
end;

function TEvdevHub.Item(I: Integer): TEvdevInput;
begin
  Result := TEvdevInput(FItems[I]);
end;

procedure TEvdevHub.TickAll;
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do
    TEvdevInput(FItems[I]).TickBackoff;
end;

procedure TEvdevHub.BuildPollFds(Fds: TFPList);
var
  I: Integer;
  fd: cint;
begin
  Fds.Clear;
  for I := 0 to FItems.Count - 1 do
  begin
    fd := TEvdevInput(FItems[I]).PollFd;
    if fd >= 0 then
      Fds.Add({%H-}Pointer(PtrUInt(fd)));
  end;
end;

procedure TEvdevHub.DrainFd(fd: cint; ASender: TObject; OnPub: TEvdevPublishEvent);
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do
    if TEvdevInput(FItems[I]).PollFd = fd then
    begin
      TEvdevInput(FItems[I]).DrainEvents(ASender, OnPub);
      Break;
    end;
end;

end.
