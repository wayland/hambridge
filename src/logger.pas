unit logger;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils;

type
  TLogLevel = (llDebug, llInfo, llWarn, llError);

procedure LogInit(ALevel: TLogLevel);
function LogLevelFromString(const S: string): TLogLevel;
procedure Log(const Level: TLogLevel; const Msg: string);
procedure LogFmt(const Level: TLogLevel; const Fmt: string; const Args: array of const);

implementation

var
  GLevel: TLogLevel = llInfo;

procedure LogInit(ALevel: TLogLevel);
begin
  GLevel := ALevel;
end;

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
