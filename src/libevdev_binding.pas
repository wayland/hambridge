unit libevdev_binding;

{$mode ObjFPC}{$H+}

interface

uses
  ctypes, BaseUnix;

type
  Plibevdev = Pointer;

  TInputEvent = packed record
    time: TTimeVal;
    ev_type: cuint16;
    code: cuint16;
    value: cint32;
  end;
  PInputEvent = ^TInputEvent;

const
  LIBEVDEV_MODE_GRAB = 3;
  LIBEVDEV_MODE_UNGRAB = 4;
  LIBEVDEV_READ_FLAG_NORMAL = 0;
  LIBEVDEV_READ_STATUS_SUCCESS = 1;
  LIBEVDEV_READ_STATUS_SYNC = 2;

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
