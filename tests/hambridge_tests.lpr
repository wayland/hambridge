program hambridge_tests;

{$mode ObjFPC}{$H+}

{
  FPCUnit console runner (Specification.md §10.2). Built as ./build/hambridge_tests.
  `make test` runs this with `--all --format=plain`. For manual runs: ./build/hambridge_tests --all
}

uses
  consoletestrunner,
  test_devicesconfig,
  test_viscamapping;

var
  App: TTestRunner;
begin
  App := TTestRunner.Create(nil);
  try
    App.Initialize;
    App.Run;
  finally
    App.Free;
  end;
end.
