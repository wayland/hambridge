unit evdevreader;

{
  Opens Linux evdev nodes via libevdev, exposes fds for poll(2), turns each input_event into
  plan §3.1.2 JSON and delivers it through a caller-supplied callback (typically MQTT publish).
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils, Classes, ctypes, BaseUnix, Unix, fpjson,
  devicesconfig, libevdev_binding, logger;

type
  { Callback invoked for each decoded kernel event (topic + JSON payload). }
  TEvdevPublishEvent = procedure(Sender: TObject; const Topic, Json: string) of object;

  { One configured input device: holds libevdev context, handles open/reopen with backoff. }
  TEvdevInput = class
  private
    FCfg: TEvdevInputConfig;  { Copy of hambridge.yaml endpoints[] controller/evdev row for this input }
    FDev: Plibevdev;          { Opaque libevdev handle; nil when closed }
    FFd: cint;                { Non-blocking O_RDONLY fd for poll; -1 when closed }
    FBackoffMs: Cardinal;     { Current reopen delay; doubles on failure up to cap }
    FNextTryTick: QWord;      { Earliest tick (GetTickCount64) to attempt TryOpen again }
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

  { Owns all TEvdevInput instances created from hambridge.yaml; aggregates fds for the main loop. }
  TEvdevHub = class
  private
    FItems: TFPList;  { List of TEvdevInput pointers }
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    procedure AddFromConfig(const Dev: TDevicesConfig);
    function Count: Integer;  { Number of TEvdevInput objects in the hub }
    function Item(I: Integer): TEvdevInput;  { Zero-based index into FItems }
    procedure TickAll;
    { Clears Fds then appends each open PollFd as Pointer(PtrUInt(fd)); caller supplies empty list. }
    procedure BuildPollFds(Fds: TFPList);
    procedure DrainFd(fd: cint; ASender: TObject; OnPub: TEvdevPublishEvent);
  end;

implementation

uses
  Math, DateUtils;

{ Stores config and initialises closed state; open happens on first TickBackoff or poll prep. }
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
  { Tear down libevdev and the kernel fd. }
  CloseLocked;
  inherited Destroy;
end;

{ Releases libevdev and closes the fd; safe to call repeatedly. }
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

{ Opens deviceNode, creates libevdev, optional grab; on failure logs and leaves self closed. }
function TEvdevInput.TryOpen: Boolean;
var
  r: cint;
begin
  Result := False;
  CloseLocked;
  FFd := fpOpen(PChar(FCfg.DeviceNode), O_RDONLY or O_NONBLOCK);
  if FFd < 0 then
  begin
    LogFmt(llWarn, 'evdev: cannot open %s for input %s: %s', [FCfg.DeviceNode, FCfg.Slug, SysErrorMessage(fpgeterrno)]);
    Exit;
  end;
  FDev := libevdev_new;
  if FDev = nil then
  begin
    LogFmt(llError, 'evdev: libevdev_new failed for %s', [FCfg.Slug]);
    FpClose(FFd);
    FFd := -1;
    Exit;
  end;
  r := libevdev_set_fd(FDev, FFd);
  if r < 0 then
  begin
    LogFmt(llWarn, 'evdev: libevdev_set_fd failed for %s: errno %d', [FCfg.Slug, -Integer(r)]);
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
      LogFmt(llWarn, 'evdev: grab failed for %s (continuing without grab): errno %d', [FCfg.Slug, -Integer(r)])
    else
      LogFmt(llInfo, 'evdev: exclusive grab active for %s', [FCfg.Slug]);
  end;
  LogFmt(llInfo, 'evdev: opened %s (%s)', [FCfg.DeviceNode, FCfg.Slug]);
  FBackoffMs := 1000;
  Result := True;
end;

{ Returns the fd to pass to poll(), or -1 if not currently open (hub skips dead entries). }
function TEvdevInput.PollFd: cint;
begin
  if FFd >= 0 then
    Exit(FFd);
  Result := -1;
end;

{ If closed, retries TryOpen on a doubling backoff so unplugged devices do not spin the CPU. }
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

{ Builds one JSON object per plan §3.1.2 (timestamps, type/code names + numeric ids, value). }
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
    o.Add('slug', FCfg.Slug);
    o.Add('inputSlug', FCfg.Slug);
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

{ Reads every available event from libevdev in a tight loop; calls OnPub per event; handles EAGAIN and device removal. }
procedure TEvdevInput.DrainEvents(ASender: TObject; OnPub: TEvdevPublishEvent);
var
  ev: TInputEvent;
  st: cint;

  procedure HandleNegSt;
  begin
    if (-Integer(st)) = ESysEAGAIN then
      Exit;
    if (-Integer(st)) = ESysENODEV then
    begin
      LogFmt(llWarn, 'evdev: device removed for %s, reopening', [FCfg.Slug]);
      CloseLocked;
      FNextTryTick := GetTickCount64 + 500;
      Exit;
    end;
    LogFmt(llWarn, 'evdev: libevdev_next_event errno %d on %s', [-Integer(st), FCfg.Slug]);
  end;

begin
  if FDev = nil then
    Exit;
  while True do
  begin
    st := libevdev_next_event(FDev, LIBEVDEV_READ_FLAG_NORMAL, @ev);
    if st < 0 then
    begin
      HandleNegSt;
      Break;
    end;
    if st = LIBEVDEV_READ_STATUS_SYNC then
    begin
      { SYN_DROPPED (or similar): emit the marker event, then drain state with READ_FLAG_SYNC. }
      OnPub(ASender, FCfg.MqttTopic, FormatEventJson(ev));
      while True do
      begin
        st := libevdev_next_event(FDev, LIBEVDEV_READ_FLAG_SYNC, @ev);
        if st < 0 then
        begin
          if (-Integer(st)) <> ESysEAGAIN then
            LogFmt(llWarn, 'evdev: sync drain errno %d on %s', [-Integer(st), FCfg.Slug]);
          Break;
        end;
        if st = LIBEVDEV_READ_STATUS_SYNC then
          OnPub(ASender, FCfg.MqttTopic, FormatEventJson(ev));
      end;
      Continue;
    end;
    if st = LIBEVDEV_READ_STATUS_SUCCESS then
      OnPub(ASender, FCfg.MqttTopic, FormatEventJson(ev));
  end;
end;

{ TEvdevHub }

constructor TEvdevHub.Create;
begin
  inherited Create;
  { Plain pointer list: items are TEvdevInput instances freed in Destroy/Clear. }
  FItems := TFPList.Create;
end;

destructor TEvdevHub.Destroy;
var
  I: Integer;
begin
  { Free every TEvdevInput we own before releasing the list container. }
  for I := 0 to FItems.Count - 1 do
    TEvdevInput(FItems[I]).Free;
  FItems.Free;
  inherited Destroy;
end;

{ Frees every input and clears the list (e.g. before rebuilding config — not used at startup today). }
procedure TEvdevHub.Clear;
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do
    TEvdevInput(FItems[I]).Free;
  FItems.Clear;
end;

{ Creates one TEvdevInput per controller/evdev endpoint (endpoints[]). }
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

{ Number of configured inputs (includes not-yet-open devices). }
function TEvdevHub.Count: Integer;
begin
  Result := FItems.Count;
end;

{ Unchecked index: caller must use 0 .. Count-1 (matches mainloop iteration pattern). }
function TEvdevHub.Item(I: Integer): TEvdevInput;
begin
  Result := TEvdevInput(FItems[I]);
end;

{ Gives every input a chance to reopen after hotplug or permission fix. }
procedure TEvdevHub.TickAll;
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do
    TEvdevInput(FItems[I]).TickBackoff;
end;

{ Clears Fds then appends each open PollFd as Pointer(PtrUInt(fd)) for fpPoll. Caller owns Fds. }
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

{ After poll() marks a fd readable, routes to the matching TEvdevInput.DrainEvents. }
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
