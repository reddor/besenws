unit datautils;
{
 hashtable & sparse list implementations

 Copyright (C) 2016 Simon Ley

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published
 by the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU Lesser General Public License
 along with this program.  If not, see <http://www.gnu.org/licenses/>.
}

{$i besenws.inc}

interface

uses
  Classes,
  Math;

type
  KString = string;
  DataString = string;

  PHashtableEntry = ^THashtableEntry;
  THashtableEntry = record
    Data: Pointer;
    HashedIndex: Cardinal;
    Index: KString;
    Prev,
    Next: PHashtableEntry;
    NextGlobal,
    PrevGlobal: PHashtableEntry;
  end;

  TKeyList = array of PHashtableEntry;
  THashtableIterationProc = procedure(Key: Kstring; Data: Pointer; var Continue: Boolean) of object;

  { THashtable }

  THashtable = class
  private
    FCount: Integer;
    FList: TKeyList;
    FFirst,
    FLast: PHashtableEntry;
    FEnumPos: PHashtableEntry;
    function CreateEntry(const Index: KString; IndexHash: Cardinal): PHashtableEntry;
    function FindHash(const Index: KString; CreateIfRequired: Boolean = false): PHashtableEntry;
    function GetHash(const Index: KString): Cardinal;
    procedure Grow;
  protected
  public
    constructor Create;
    destructor Destroy; override;
    procedure First;
    procedure CheckCollisions;
    procedure Iterate(Proc: THashtableIterationProc);
    function Get(Index: KString): Pointer;
    procedure Add(Index: KString; const Value: Pointer);
    function Find(Index: KString; var Data: Pointer): Boolean;
    function GetNext(var Hash: KString; var Data: Pointer): Boolean;
    function DeleteKey(const Index: KString): Boolean;
    property Key[Index: KString]: Pointer read Get write Add; default;
  end;

  PStringHashtableEntry = ^TStringHashtableEntry;
  TStringHashtableEntry = record
    Data: DataString;
    HashedIndex: Cardinal;
    Index: KString;
    Prev,
    Next: PStringHashtableEntry;
    NextGlobal,
    PrevGlobal: PStringHashtableEntry;
  end;
  TStringKeyList = array of PStringHashtableEntry;
  TStringHashtableIterationProc = procedure(Key: Kstring; Data: DataString; var Continue: Boolean) of object;

  { TStringHashtable }

  TStringHashtable = class
  protected
    FCount: Integer;
    FList: TStringKeyList;
    FFirst,
    FLast: PStringHashtableEntry;
    FEnumPos: PStringHashtableEntry;
    function CreateEntry(const Index: KString; IndexHash: Cardinal): PStringHashtableEntry;
    function FindHash(const Index: KString; CreateIfRequired: Boolean = false): PStringHashtableEntry;
    function GetHash(const Index: KString): Cardinal;
    procedure Grow;
  public
    constructor Create;
    destructor Destroy; override;
    procedure First;
    procedure Iterate(Proc: TStringHashtableIterationProc);
    function Get(Index: KString): DataString;
    procedure Add(Index: KString; const Value: DataString);
    function Find(Index: KString; var Data: DataString): Boolean;
    function GetNext(var Hash: KString; var Data: DataString): Boolean;
    function DeleteKey(const Index: KString): Boolean;
    property Key[Index: KString]: DataString read Get write Add; default;
  end;

  TSparseListItem = record
    Index: Int64;
    Data: Pointer;
  end;

  { TSparseList }

  { A sorted list that can have abritary index numbers. Items are found using
    binary search }
  TSparseList = class
    FCount: Integer;
    FList: array of TSparseListItem;
    FMin, FMax: Int64;
    function FindItem(Index: Int64; CreateIfRequired: Boolean = false): Integer;
  private
    function GetCount: Integer;
    function GetItem(Index: Int64): Pointer;
    function GetRawItem(Items: Integer): TSparseListItem;
    procedure SetItem(Index: Int64; const Value: Pointer);
  public
    { adds an entry at the end of the list, returns index }
    function Push(Data: Pointer): Int64;
    { returns the last item and removes it from the list }
    function Pop: Pointer;
    { deletes the item at index }
    function Delete(Index: Integer): Boolean;
    property Count: Integer read FCount;
    property Items[Index: Int64]: Pointer read GetItem write SetItem; default;
    property RawCount: Integer read GetCount;
    property RawItems[Items: Integer]: TSparseListItem read GetRawItem;
  end;

implementation

{ TStringHashtable }

function TStringHashtable.CreateEntry(const Index: KString; IndexHash: Cardinal
  ): PStringHashtableEntry;
begin
  GetMem(result, SizeOf(THashtableEntry));
  FillChar(result^, SizeOf(THashtableEntry), #0);
  Result^.Index:=Index;
  Result^.HashedIndex:=IndexHash;
  Result^.PrevGlobal:=FLast;

  inc(FCount);
  if FCount>(2*Length(FList)) div 3 then
    Grow;

  if not Assigned(FFirst) then
  begin
    FFirst:=Result;
    FLast:=Result;
  end else
  begin
    FLast.NextGlobal:=Result;
    FLast:=Result;
  end;
end;

function TStringHashtable.FindHash(const Index: KString;
  CreateIfRequired: Boolean): PStringHashtableEntry;
var
  Hash, CroppedHash: Cardinal;
  e: PStringHashtableEntry;
begin
  if Length(FList)=0 then
  begin
    result:=nil;
    Exit;
  end;

  Hash := GetHash(Index);
  CroppedHash := Hash mod Cardinal(Length(FList));
  e := FList[CroppedHash];
  if Assigned(e) then
  begin
    while Assigned(e) do
    begin
      if(e.HashedIndex = Hash)and(e.Index = Index) then
      begin
        result := e;
        Exit;
      end;
      if CreateIfRequired and (not Assigned(e.Next)) then
      begin
        e.Next:=CreateEntry(Index, Hash);
//        e.Next:=e;
        e.Next.Prev:=e;
        result := e.Next;
        Exit;
      end;
      e:=e.Next;
    end;
  end else if CreateIfRequired then
  begin
    FList[CroppedHash]:=CreateEntry(Index, Hash);
    result := FList[CroppedHash];
    Exit;
  end;
  result:=nil;
end;

function TStringHashtable.GetHash(const Index: KString): Cardinal;
var
  i: Cardinal;
begin
  result := $1234321;
  for i:=1 to Length(Index) do
    result:=((result shl 2) + Ord(Index[i])*i);
end;

procedure TStringHashtable.Grow;
var
  i, NewSize, OldSize: Cardinal;
  h: Cardinal;
  b: Boolean;
  e, e2: PStringHashtableEntry;
begin
  OldSize := Length(FList);
  NewSize := Max(97, (OldSize*4)div 3);

  // find a new prime number
  repeat
    b := True;
    if NewSize mod 2 = 0 then
    begin
      inc(NewSize);
      b := False;
    end else if NewSize mod 3 = 0 then
    begin
      inc(NewSize, 2);
      b := False;
    end else
    for i:=2 to (floor(sqrt(NewSize))+1) div 2 do
    if NewSize mod (i*2 + 1) = 0 then
    begin
      b := False;
      inc(NewSize, 4);
      Break;
    end;
  until b;
  Setlength(FList, 0);
  FList:=nil;

  Setlength(FList, NewSize);

  e:=FFirst;
  while Assigned(e) do
  begin
    h := e.HashedIndex mod NewSize;
    if not Assigned(FList[h]) then
    begin
      FList[h]:=e;
      e.Next:=nil;
      e.Prev:=nil;
    end else
    begin
      e2 := FList[h];
      while Assigned(e2.Next) do
        e2:=e2.Next;
      e2.Next:=e;
      e.Prev:=e2;
      e.Next:=nil;
    end;
    e:=e.NextGlobal;
  end;

end;

constructor TStringHashtable.Create;
begin
  Grow;
end;

destructor TStringHashtable.Destroy;
var
  a,b: PStringHashtableEntry;
  i, j: integer;
begin
  j:=0;
  for i:=0 to Length(FList)-1 do
  begin
    a:=FList[i];
    while Assigned(a) do
    begin
      b:=a.Next;
      a.Index:='';
      a.Data:='';
      inc(j);
      FreeMem(a);
      a:=b;
    end;
  end;
  Setlength(FList, 0);
  inherited;
end;

procedure TStringHashtable.First;
begin
  FEnumPos:=FFirst;
end;

procedure TStringHashtable.Iterate(Proc: TStringHashtableIterationProc);
var
  Hash: KString;
  Data: DataString;
  Continue: Boolean;
begin
  First;
  Continue:=True;
  While GetNext(Hash, Data) and Continue do
    Proc(Hash, Data, Continue);
end;

function TStringHashtable.Get(Index: KString): DataString;
var
  e: PStringHashtableEntry;
begin
  e := FindHash(Index);

  if Assigned(e) then
    result := e.Data
  else
    result := '';
end;

procedure TStringHashtable.Add(Index: KString; const Value: DataString);
var
  e: PStringHashtableEntry;
begin
  e := FindHash(Index, True);
  e.Data := Value;
end;

function TStringHashtable.Find(Index: KString; var Data: DataString): Boolean;
var
  foo: PStringHashtableEntry;
begin
  foo:=FindHash(Index, false);
  if Assigned(Foo) then
    Data:=foo.Data;
  result:=Foo<>nil;
end;

function TStringHashtable.GetNext(var Hash: KString; var Data: DataString
  ): Boolean;
begin
  if Assigned(FEnumPos) then
  begin
    result:=True;
    Hash:=FEnumPos.Index;
    Data:=FEnumPos.Data;
    FEnumPos:=FEnumPos.NextGlobal;
  end else
  begin
    result:=False;
  end;
end;

function TStringHashtable.DeleteKey(const Index: KString): Boolean;
var
  Key: PStringHashtableEntry;
begin
  Key:=FindHash(Index);
  if Assigned(Key) then
  begin
    if Assigned(Key.Prev) then
      Key.Prev.Next:=Key.Next
    else
      FList[Key.HashedIndex mod Cardinal(Length(FList))]:=Key.Next;
    if Assigned(Key.Next) then
      Key.Next.Prev:=Key.Prev;

    if Assigned(Key.PrevGlobal) then
      Key.PrevGlobal.NextGlobal:=Key.NextGlobal
    else
      FFirst:=Key.NextGlobal;

    if Assigned(Key.NextGlobal) then
      Key.NextGlobal:=Key.PrevGlobal
    else
      FLast:=Key.PrevGlobal;

    FreeMem(Key);
    result := True;

    dec(FCount);
  end else
    result:=False;
end;

{ TKeyStore }

constructor THashtable.Create;
begin
  Grow;
end;

function THashtable.CreateEntry(const Index: KString; IndexHash: Cardinal): PHashtableEntry;
begin
  GetMem(result, SizeOf(THashtableEntry));
  FillChar(result^, SizeOf(THashtableEntry), #0);
  Result^.Index:=Index;
  Result^.HashedIndex:=IndexHash;
  Result^.PrevGlobal:=FLast;
  Inc(FCount);

  if not Assigned(FFirst) then
  begin
    FFirst:=Result;
    FLast:=Result;
  end else
  begin
    FLast.NextGlobal:=Result;
    FLast:=Result;
  end;
end;

function THashtable.DeleteKey(const Index: KString): Boolean;
var
  Key: PHashtableEntry;
begin
  Key:=FindHash(Index);
  if Assigned(Key) then
  begin
    if Assigned(Key.Prev) then
      Key.Prev.Next:=Key.Next
    else
      FList[Key.HashedIndex mod Cardinal(Length(FList))]:=Key.Next;
    if Assigned(Key.Next) then
      Key.Next.Prev:=Key.Prev;

    if Assigned(Key.PrevGlobal) then
      Key.PrevGlobal.NextGlobal:=Key.NextGlobal
    else
      FFirst:=Key.NextGlobal;

    if Assigned(Key.NextGlobal) then
      Key.NextGlobal:=Key.PrevGlobal
    else
      FLast:=Key.PrevGlobal;

    FreeMem(Key);
    result := True;

    dec(FCount);
  end else
    result:=False;
end;

destructor THashtable.Destroy;
var
  a, b: PHashtableEntry;
  i, j: integer;
begin
  j:=0;
  for i:=0 to Length(FList)-1 do
  begin
    a:=FList[i];
    while Assigned(a) do
    begin
      b:=a.Next;
      a.Index:='';
      inc(j);
      FreeMem(a);
      a:=b;
    end;
  end;

  Setlength(FList, 0);
  inherited;
end;

function THashtable.Find(Index: KString; var Data: Pointer): Boolean;
var
  foo: PHashtableEntry;
begin
  foo:=FindHash(Index, false);
  if Assigned(Foo) then
    Data:=foo.Data;
  result:=Foo<>nil;
end;

function THashtable.FindHash(const Index: KString;
  CreateIfRequired: Boolean): PHashtableEntry;
var
  Hash, CroppedHash: Cardinal;
  e: PHashtableEntry;
begin
  if Length(FList)=0 then
  begin
    result:=nil;
    Exit;
  end;

  Hash := GetHash(Index);
  CroppedHash := Hash mod Cardinal(Length(FList));
  e := FList[CroppedHash];
  if Assigned(e) then
  begin
    while Assigned(e) do
    begin
      if(e.HashedIndex = Hash)and(e.Index = Index) then
      begin
        result := e;
        Exit;
      end else
      if CreateIfRequired and (not Assigned(e.Next)) then
      begin
        e.Next:=CreateEntry(Index, Hash);
//        e.Next:=e;
        e.Next.Prev:=e;
        result := e.Next;
        Exit;
      end;
      //Writeln(e.Index);
      e:=e.Next;
    end;
  end else if CreateIfRequired then
  begin
    FList[CroppedHash]:=CreateEntry(Index, Hash);
    result := FList[CroppedHash];
    Exit;
  end;
  result:=nil;
end;

procedure THashtable.First;
begin
  FEnumPos:=FFirst;
end;

procedure THashtable.CheckCollisions;
var
  i, j, count, coll: Integer;
  p: PHashtableEntry;
begin
  count:=0;
  coll:=0;
  for i:=0 to Length(FList)-1 do
  if Assigned(FList[i]) then
  begin
    Inc(Count);
    p:=FList[i];
    j:=0;
    while Assigned(p^.Next) do
    begin
      Inc(Count);
      Inc(Coll);
      p:=p^.Next;
      inc(j);
    end;
  end;
  Writeln('Items: ', Count, ' Collisions: ', Coll, ' Size: ', Length(FList));
end;

procedure THashtable.Iterate(Proc: THashtableIterationProc);
var
  Hash: KString;
  Data: Pointer;
  Continue: Boolean;
begin
  First;
  Continue:=True;
  While GetNext(Hash, Data) and Continue do
    Proc(Hash, Data, Continue);
end;

function THashtable.GetHash(const Index: KString): Cardinal;
var i: Cardinal;
begin

  result := 2166136261;
  for i:=1 to Length(Index) do
   result:=(result * 16777619) xor (Byte(Index[i]) + Byte(Index[i])*$7f00);



  result := $1234321;
  for i:=1 to Length(Index) do
    result:=((result shl 2) + Ord(Index[i])*i);

end;

function THashtable.Get(Index: KString): Pointer;
var
  e: PHashtableEntry;
begin
  e := FindHash(Index);

  if Assigned(e) then
    result := e.Data
  else
    result := nil;
end;

function THashtable.GetNext(var Hash: KString; var Data: Pointer): Boolean;
begin
  if Assigned(FEnumPos) then
  begin
    result:=True;
    Hash:=FEnumPos.Index;
    Data:=FEnumPos.Data;
    FEnumPos:=FEnumPos.NextGlobal;
  end else
  begin
    result:=False;
  end;
end;

procedure THashtable.Grow;
var
  i, NewSize, OldSize: Cardinal;
  h: Cardinal;
  b: Boolean;
  e, e2: PHashtableEntry;
begin
  OldSize := Length(FList);
  NewSize := Max(97, (OldSize*4)div 3);

  // find a new prime number
  repeat
    b := True;
    if NewSize mod 2 = 0 then
    begin
      inc(NewSize);
      b := False;
    end else if NewSize mod 3 = 0 then
    begin
      inc(NewSize, 2);
      b := False;
    end else
    for i:=2 to (floor(sqrt(NewSize))+1) div 2 do
    if NewSize mod (i*2 + 1) = 0 then
    begin
      b := False;
      inc(NewSize, 4);
      Break;
    end;
  until b;
  Setlength(FList, 0);
  FList:=nil;

  Setlength(FList, NewSize);

  e:=FFirst;
  while Assigned(e) do
  begin
    h := e.HashedIndex mod NewSize;
    if not Assigned(FList[h]) then
    begin
      FList[h]:=e;
      e.Next:=nil;
      e.Prev:=nil;
    end else
    begin
      e2 := FList[h];
      while Assigned(e2.Next) do
      begin
        e2:=e2.Next;
      end;
      e2.Next:=e;
      e.Prev:=e2;
      e.Next:=nil;
    end;
    e:=e.NextGlobal;
  end;
end;

procedure THashtable.Add(Index: KString; const Value: Pointer);
var
  e: PHashtableEntry;
begin
  e := FindHash(Index, True);
  e.Data := Value;

  if FCount>(2*Length(FList)) div 3 then
    Grow;
end;

{ TSparseList }

function TSparseList.Delete(Index: Integer): Boolean;
var i, j: Integer;
begin
  i:=FindItem(Index);
  result:=False;
  if(i<0)or(i>=Length(FList)) then
    Exit;

  for j:=i to Length(FList)-1 do
    FList[j]:=FList[j+1];

  Setlength(FList, Length(FList)-1);
  FCount:=Length(FList);
  result:=True;
end;

function TSparseList.FindItem(Index: Int64; CreateIfRequired: Boolean): Integer;
var a, b, i: Integer;
begin
  a:=0;
  b:=Length(FList);

  if b = 0 then
   if CreateIfRequired then
   begin
     Setlength(FList, 1);
     FCount:=1;
     FList[0].Index:=Index;
     FMin:=Index;
     FMax:=Index;
     result:=0;
     Exit;
   end
  else begin
    result:=-1;
    Exit;
  end;

  if Index>=FMax then
   result:=Length(FList)-1
  else if Index<=FMin then
   result:=0
  else
   result:=((Index-FMin)*b) div (FMax-FMin+1);

  while (FList[result].Index<>Index)and(a<b) do
  begin
    if FList[result].Index>Index then
      b:=result-1
    else
      a:=result+1;

    result:=(a + b) div 2;
  end;
  if CreateIfRequired and ((Length(FList)>=result)or(FList[result].Index <> Index)) then
  begin
    if result>=length(FList) then
     result:=Length(FList)-1;
    Setlength(FList, Length(FList)+1);
    FCount:=Length(FList);
    if FList[result].Index<Index then
      inc(result);

    for i:=Length(FList)-2 downto result do
      FList[i+1]:=FList[i];

    FList[result].Index:=Index;

    if FMin>Index then
     FMin:=Index;
    if FMax<Index then
     FMax:=Index;
  end;
end;

function TSparseList.GetCount: Integer;
begin
  result:=Length(FList);
end;

function TSparseList.GetItem(Index: Int64): Pointer;
var i: Integer;
begin
  result:=nil;
  i:=FindItem(Index);
  if(i<0)or(i>=Length(FList)) then
    Exit;
  if FList[i].Index = Index then
    result:=FList[i].Data;
end;

function TSparseList.GetRawItem(Items: Integer): TSparseListItem;
begin
  result:=FList[Items];
end;

function TSparseList.Pop: Pointer;
begin
  result:=nil;
end;

function TSparseList.Push(Data: Pointer): Int64;
begin
  if Length(FList)=0 then
    Items[FMax]:=Data
  else
    Items[FMax+1]:=Data;
  result:=FMax;
  Inc(FCount);
end;

procedure TSparseList.SetItem(Index: Int64; const Value: Pointer);
var
  i: Integer;
begin
  i:=FindItem(Index, True);
  FList[i].Data:=Value;
end;
(*

function ParseValue(item: PStoreItem; Value: KString): PStoreItem;

 procedure ClearItem(aType: TStoreType);
 begin
   if aType <> stObject then
   begin
     if Assigned(result.ObjReference) then
       result.ObjReference.Free;
     result.ObjReference:=nil;
   end else if aType <> stList then
   begin
     if Assigned(result.ListReference) then
       result.ListReference.Free;
     result.ListReference:=nil;
   end else if aType <> stString then
   begin
     result.StrData:='';
   end;

   result.Kind:=aType;
 end;

begin
  result:=item;

  if Length(Value)<1 then
    Exit;

  if not Assigned(result) then
  begin
    GetMem(result, SizeOf(TStoreItem));
    FillChar(result^, SizeOf(TStoreItem), #0);
  end else
    result := item;

  if Value[1]='"' then
  begin
    clearItem(stString);
    result.StrData:=Copy(Value, 2, Length(Value)-2);
  end else if Value[1]='{' then
  begin
    clearItem(stObject);
    if not Assigned(result.ObjReference) then
      result.ObjReference:=TStoreObject.Create;
    result.ObjReference.ParseJSON(Value);
  end else if Value[1]='[' then
  begin
    clearItem(stList);
    if not Assigned(result.ListReference) then
      result.ListReference:=TStoreList.Create;
    result.ListReference.ParseJSON(Value);
  end else ; // integer, double, reference
end;
{ TStoreObject }
{
constructor TStoreObject.Create;
begin
  FTable:=THashtable.Create;
end;

destructor TStoreObject.Destroy;
begin
  FTable.Free;
  inherited;
end;

function TStoreObject.GetJSON: KString;
var el: PHashtableEntry;
begin
  el:=FTable.FFirst;
  result:='{';
  while Assigned(el) do
  begin
    result:=result+el.Index+':';
    case PStoreItem(el.Data).Kind of
      stString: result:=result+'"'+PStoreItem(el.Data).StrData+'"';
      stObject: result:=result+PStoreItem(el.Data).ObjReference.GetJSON;
      stList: result:=result+PStoreItem(el.Data).ListReference.GetJSON;
    end;
    el:=el.NextGlobal;
    if Assigned(el) then
      result:=result+',';
  end;
  result:=result+'}';
end;

procedure TStoreObject.JSONValue(Key, Value: KString);
begin
  FTable[key]:=ParseValue(PStoreItem(FTable[key]), Value);;
end;

function TStoreObject.ParseJSON(JSONStr: KString): Boolean;
begin
  json.ParseJSON(JSONStr, JSONValue);
end;

{ TStoreList }

constructor TStoreList.Create;
begin
  FList:=TSparseList.Create;
end;

destructor TStoreList.Destroy;
begin
  FList.Free;
  inherited;
end;

function TStoreList.GetJSON: KString;
var i: Integer;
begin
  result:='[';
  for i:=0 to Length(FList.FList)-1 do
    case PStoreItem(FList.FList[i].Data).Kind of
      stString: result:=result+'"'+PStoreItem(FList.FList[i].Data).StrData+'"';
      stObject: result:=result+PStoreItem(FList.FList[i].Data).ObjReference.GetJSON;
      stList: result:=result+PStoreItem(FList.FList[i].Data).ListReference.GetJSON;
    end;
    if i<>Length(FList.FList)-1 then
      result:=result+',';

  result:=result+']';
end;

procedure TStoreList.JSONValue(Key, Value: KString);
begin
  if Key<>'' then
  begin
    // we are a list, not an object!
    Exit;
  end;
  FList.Push(ParseValue(nil, Value));
end;

function TStoreList.ParseJSON(JSONStr: KString): Boolean;
begin
  json.ParseJSON(JSONStr, JSONValue);
end; *)

end.
