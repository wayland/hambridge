unit logger;

{
  Minimal stdout logger for a headless daemon: level filter, timestamp prefix, no syslog yet.
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils;

type
  { Severity ordering matches Ord() for filtering: only messages >= GLevel are printed. }
  TLogLevel = (llDebug, llInfo, llWarn, llError);

{ Sets global minimum level from bridge.json "log.level" after startup. }
procedure LogInit(ALevel: TLogLevel);
{ Maps bridge.json string (debug/info/warn/error) to TLogLevel; unknown -> info. }
function LogLevelFromString(const S: string): TLogLevel;
{ Writes one line to stdout if Level is enabled. }
procedure Log(const Level: TLogLevel; const Msg: string);
{ Format-style wrapper around Log. }
procedure LogFmt(const Level: TLogLevel; const Fmt: string; const Args: array of const);

implementation

var
  GLevel: TLogLevel = llInfo;

procedure LogInit(ALevel: TLogLevel);
begin
  GLevel := ALevel;
end;

{ Used at config load time before LogInit may run with file-derived level. }
function LogLevelFromString(const S: string): TLogLevel;
var
  L: string;
begin
  L := LowerCase(Trim(S));
  if L = 'debug' then
    Exit(llDebug);
  if L = 'info' then
    Exit(llInfo);
  if L = 'warn' then
    Exit(llWarn);
  if L = 'error' then
    Exit(llError);
  Result := llInfo;
end;

{ Ordinal compare so we can filter "is this message at least as severe as configured?". }
function LevelOrd(L: TLogLevel): Integer;
begin
  Result := Ord(L);
end;

procedure Log(const Level: TLogLevel; const Msg: string);
const
  Tags: array[TLogLevel] of string = ('DEBUG', 'INFO', 'WARN', 'ERROR');
begin
  if LevelOrd(Level) < LevelOrd(GLevel) then
    Exit;
  WriteLn(FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now), ' [', Tags[Level], '] ', Msg);
end;

procedure LogFmt(const Level: TLogLevel; const Fmt: string; const Args: array of const);
begin
  Log(Level, Format(Fmt, Args));
end;

end.
