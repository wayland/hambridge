unit mainloop;

{
  Single-threaded glue: poll evdev fds (optional), drain MQTT sync queue, tick VISCA command router,
  exit when WantStop becomes true (signal handler).
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils, Classes, ctypes, BaseUnix,
  evdevreader, mqttpublisher, commandrouter;

procedure RunHaMBridgeLoop(Hub: TEvdevHub; Mqtt: THaMqttPublisher; Router: TCommandRouter;
  ASender: TObject; OnEvdev: TEvdevPublishEvent; var WantStop: Boolean);

implementation

procedure RunHaMBridgeLoop(Hub: TEvdevHub; Mqtt: THaMqttPublisher; Router: TCommandRouter;
  ASender: TObject; OnEvdev: TEvdevPublishEvent; var WantStop: Boolean);
var
  List: TFPList;
  Fds: array of TPollfd;
  I, N, Pr: Integer;
  Fd: cint;
begin
  List := TFPList.Create;
  try
    while not WantStop do
    begin
      Mqtt.TickReconnect;
      Mqtt.ProcessSynchronize;
      if Router <> nil then
        Router.Tick;
      if Hub <> nil then
        Hub.TickAll;
      if Hub <> nil then
        Hub.BuildPollFds(List)
      else
        List.Clear;
      N := List.Count;
      SetLength(Fds, N);
      for I := 0 to N - 1 do
      begin
        Fd := cint(PtrUInt(List[I]));
        Fds[I].fd := Fd;
        Fds[I].events := POLLIN or POLLPRI;
        Fds[I].revents := 0;
      end;
      if N > 0 then
        Pr := fpPoll(@Fds[0], N, 50)
      else
      begin
        Sleep(50);
        Pr := 0;
      end;
      if (Pr > 0) and (Hub <> nil) then
      begin
        for I := 0 to N - 1 do
          if (Fds[I].revents and (POLLIN or POLLPRI)) <> 0 then
            Hub.DrainFd(Fds[I].fd, ASender, OnEvdev);
      end;
    end;
  finally
    List.Free;
  end;
end;

end.
