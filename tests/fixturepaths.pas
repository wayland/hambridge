unit fixturepaths;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils;

{ Resolve tests/fixtures/<Rel> from the test binary path (./build/hambridge_tests → ../tests/fixtures/). }
function FixturePath(const Rel: string): string;

implementation

function FixturePath(const Rel: string): string;
var
  BinDir: string;
begin
  BinDir := ExtractFilePath(ParamStr(0));
  Result := ExpandFileName(IncludeTrailingPathDelimiter(BinDir) + '..' + PathDelim + 'tests' +
    PathDelim + 'fixtures' + PathDelim + Rel);
end;

end.
