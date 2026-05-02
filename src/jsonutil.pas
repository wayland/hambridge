unit jsonutil;

{
  Case-insensitive helpers for TJSONObject: JSON keys from files use camelCase while BRIDGE_*
  env overrides map to lowercase segments — SameText avoids mismatches.
}

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils, fpjson;

{ Returns the first member whose name matches Key case-insensitively, or nil. }
function ObjFindCI(Obj: TJSONObject; const Key: string): TJSONData;
{ Removes every member whose name matches Key case-insensitively (reverse scan so indices stay valid). }
procedure ObjDeleteCI(Obj: TJSONObject; const Key: string);
{ Like ObjFindCI but returns child object only if the value is a JSON object. }
function ObjGetObjectCI(Obj: TJSONObject; const Key: string): TJSONObject;

implementation

function ObjFindCI(Obj: TJSONObject; const Key: string): TJSONData;
var
  I: Integer;
begin
  for I := 0 to Obj.Count - 1 do
    if SameText(Obj.Names[I], Key) then
      Exit(Obj.Items[I]);
  Result := nil;
end;

procedure ObjDeleteCI(Obj: TJSONObject; const Key: string);
var
  I: Integer;
begin
  for I := Obj.Count - 1 downto 0 do
    if SameText(Obj.Names[I], Key) then
      Obj.Delete(I); // by index
end;

function ObjGetObjectCI(Obj: TJSONObject; const Key: string): TJSONObject;
var
  D: TJSONData;
begin
  D := ObjFindCI(Obj, Key);
  if (D <> nil) and (D is TJSONObject) then
    Exit(TJSONObject(D));
  Result := nil;
end;

end.
