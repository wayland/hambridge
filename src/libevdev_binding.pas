unit libevdev_binding;

{
  Thin cdecl imports for libevdev.so.2 (see Linux input.h + libevdev docs). Linked via Makefile
  -l:libevdev.so.2; no Pascal package dependency.
}

{$mode ObjFPC}{$H+}

interface

uses
  ctypes, BaseUnix;

type
  { Opaque struct libevdev* from C. }
  Plibevdev = Pointer;

  { Linux kernel struct input_event as consumed by libevdev_next_event (see linux/input.h). }
  TInputEvent = packed record
    time: TTimeVal;   { Event timestamp from kernel }
    ev_type: cuint16; { EV_* category (e.g. EV_KEY) }
    code: cuint16;    { Code within category (e.g. KEY_A) }
    value: cint32;    { Meaning depends on type (0/1 for keys, delta for rel, etc.) }
  end;
  PInputEvent = ^TInputEvent;

const
  LIBEVDEV_MODE_GRAB = 3;   { libevdev_grab: exclusive input grab }
  LIBEVDEV_MODE_UNGRAB = 4;
  LIBEVDEV_READ_FLAG_NORMAL = 0;
  LIBEVDEV_READ_STATUS_SUCCESS = 1; { Event read OK }
  LIBEVDEV_READ_STATUS_SYNC = 2;    { Force-synced state after SYN_DROPPED }

{
  The following declarations mirror libevdev C API: allocate context, attach fd, read events,
  resolve type/code names to stable strings for JSON logging.
}
function libevdev_new: Plibevdev; cdecl; external name 'libevdev_new';
procedure libevdev_free(dev: Plibevdev); cdecl; external name 'libevdev_free';
function libevdev_set_fd(dev: Plibevdev; fd: cint): cint; cdecl; external name 'libevdev_set_fd';
function libevdev_grab(dev: Plibevdev; mode: cint): cint; cdecl; external name 'libevdev_grab';
function libevdev_next_event(dev: Plibevdev; flags: cuint; ev: PInputEvent): cint; cdecl; external name 'libevdev_next_event';
function libevdev_event_type_get_name(typ: cuint): PAnsiChar; cdecl; external name 'libevdev_event_type_get_name';
function libevdev_event_code_get_name(typ: cuint; code: cuint): PAnsiChar; cdecl; external name 'libevdev_event_code_get_name';

implementation

{ Link libevdev via Makefile (-k-L… -k-l:libevdev.so.2) so runtime .so.2 works without unversioned -dev symlink. }

end.
