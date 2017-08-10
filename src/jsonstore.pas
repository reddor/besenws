unit jsonstore;
{
 experimental json storage

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
  SysUtils,
  dataUtils;

type
  TJSONStore = class;

  TJSONValueKind = (jkInvalid, jkList, jkObject, jkString);

  TJSONElement = class;
  TJSONObject = class;
  TJSONArray = class;

  PJSONValue = ^TJSONValue;
  TJSONValue = record
    Str: string;
    Kind: TJSONValueKind;
    List: TJSONElement;
    Obj: TJSONElement;
  end;

  PJSONChange = ^TJSONChange;
  TJSONChange = record
    target, value: string;
  end;

  { TJSONElement }

  TJSONElement = class
  private
    FParent: TJSONStore;
    FRefCounter: Integer;
//    FChanges: array[0..1023] of PJSONChange;
//    FChangePos: Integer;
  protected
    procedure ParseArrayElement(var JSON: PChar; var Length: Integer); virtual;
    procedure ParseObjectElement(Key: string; var JSON: PChar; var Length: Integer); virtual;
    function ParseJSON(Target: PJSONValue; var Input: PChar; var Length: Integer): PJSONValue;
    function toJSONLength: integer; virtual; abstract;
    procedure toJSONCopy(var Target: string; var Pos: Integer); virtual; abstract;
  public
    constructor Create(aParent: TJSONStore);

    function toJSON: string; virtual; abstract;
    function toJSON2: string; virtual;
    function DeleteEntry(location: string): Boolean; virtual; abstract;
    function Get(location: string): string; virtual; abstract;
    function GetObj(location: string): TJSONElement; virtual; abstract;
    function Put(location, data: string): Boolean; virtual; abstract;

    //function GetChange(var Index: Integer): PJSONChange;
    //procedure AddChange(Change: PJSONChange);
    procedure TryFree;
    procedure AddRef;
//    property ChangePos: Integer read FChangePos;
  end;

  { TJSONObject }

  TJSONObject = class(TJSONElement)
  private
    FTable: THashtable;
  protected
    procedure ParseObjectElement(Key: string; var JSON: PChar; var Length: Integer); override;
    function toJSONLength: integer; override;
    procedure toJSONCopy(var Target: string; var Pos: Integer); override;
  public
    constructor Create(aParent: TJSONStore);
    destructor Destroy; override;

    function toJSON: string; override;
    function DeleteEntry(location: string): Boolean; override;
    function Get(location: string): string; override;
    function GetObj(location: string): TJSONElement; override;
    function Put(location, data: string): Boolean; override;
  end;

  { TJSONArray }

  TJSONArray = class(TJSONElement)
  private
    FArray: array of PJSONValue;
    function GetItem(Index: Integer): PJSONValue;
  protected
    procedure ParseArrayElement(var JSON: PChar; var Length: Integer); override;
    function toJSONLength: integer; override;
    procedure toJSONCopy(var Target: string; var Pos: Integer); override;
  public
    destructor Destroy; override;
    procedure Clear;
    function toJSON: string; override;
    function Get(location: string): string; override;
    function GetObj(location: string): TJSONElement; override;
    function DeleteEntry(location: string): Boolean; override;
    function GetLength: Integer;
    function Put(location, data: string): Boolean; override;
    property Items[Index: Integer]: PJSONValue read GetItem;
  end;

  { TJSONStore }

  TJSONStore = class(TJSONObject)
  private
  public
    constructor Create;
    function Put(location, Data: string): Boolean; override;
  end;

function JSONValueToStr(Value: PJSONValue): string;
function unstringify(const s: string): string;

var ElCounter: Cardinal;

//function IsValidJSON(Const JSON: string; var Index: Integer): Boolean;

implementation

type
  TTokenData = record
    Data: Pchar;
    Length: Integer;
  end;

  (*
function IsValidJSON(Const JSON: string; var Index: Integer): Boolean;
label
  processArray;
begin
  while(Index<Length(JSON)) do
  begin
    if JSON[Index]=' ' then
      Inc(Index)
    else if JSON[Index]='[' then
    begin
      Inc(Index);
      result:=True;
      processArray:
      result:=result and IsValidJSON(JSON, Index);
      if(Index<=Length(JSON)) then
      begin
        while(Index<=Length(JSON)) do
        begin
          if JSON[Index]=' ' then
            inc(Index)
          else if JSON[Index]=',' then
          begin
            inc(Index);
            goto processArray;
          end else if JSON[Index]=']' then
          begin
            Break;
          end else
          begin
            result:=False;
            Break;
          end;
        end;
      end else
        result:=False;

      Exit;
    end else if JSON[Index]='{' then
    begin
      Inc(Index);
      result:=True;
      if Index<=Length(JSON) then
      begin
        while Index<=Lenght(JSON) do
        begin
          if JSON[Index]=' ' then
            inc(Index)
          else if JSON[Index]='
        end;
      end;
    end;
  end;
end;     *)

function JSONValueToStr(Value: PJSONValue): string;
begin
  if not Assigned(Value) then
    result:='null'
  else begin
    case Value.Kind of
      jkList: result:=Value.List.toJSON;
      jkObject: result:=Value.Obj.toJSON;
      jkString: result:=Value.Str;
      else
        result:='invalid';
    end;
  end;
end;


function unstringify(const s: string): string;
begin
  if (pos('"', s)=1) or (pos('''', s)=1) then
    result:=Copy(s, 2, Length(s)-2)
  else
    result:=s;
end;

procedure JSONValueToStrCopy(Value: PJSONValue; var Target: string; var Pos: Integer);
const NullValue: string = 'null';
      InvalidValue: string = 'invalid';
begin
  if not Assigned(Value) then
  begin
    Move(NullValue[1], Target[Pos], Length(NullValue)*SizeOf(NullValue[1]));
    Inc(Pos, Length(NullValue));
  end else begin
    case Value.Kind of
      jkObject: Value.Obj.ToJSONCopy(Target, Pos);
      jkList: Value.List.ToJSONCopy(Target, Pos);
      jkString:
      begin
        Move(Value.Str[1], Target[Pos], Length(Value.Str)*SizeOf(NullValue[1]));
        Inc(Pos, Length(Value.Str));
      end;
      jkInvalid:
      begin
        Move(InvalidValue[1], Target[Pos], Length(InvalidValue)*SizeOf(NullValue[1]));
        Inc(Pos, Length(InvalidValue));
      end;
    end;
  end;
end;

function JSONGetLength(Value: PJSONValue): Integer;
begin
  if not Assigned(Value) then
    result:=4
  else
  case Value.Kind of
    jkObject: result:=Value.Obj.toJSONLength;
    jkList: result:=Value.List.toJSONLength;
    jkString: result:=Length(Value.Str);
    jkInvalid: result:=7;
    else result:=-1;
  end;
end;

{ TJSONStore }

constructor TJSONStore.Create;
begin
  inherited Create(Self);
end;

function TJSONStore.Put(location, Data: string): Boolean;
begin
  //Writeln('Store.put: ', location, ' ', Data);
  //FChanges[FChangePos].target:=location;
  //FChanges[FChangePos].value:=data;
  if data<>'' then
    result:=inherited Put(location, data)
  else
    result:=False;
  //FChangePos:=(FChangePos+1) mod 1024;
end;

{ TJSONElement }

procedure TJSONElement.ParseArrayElement(var JSON: PChar; var Length: Integer);
begin

end;

procedure TJSONElement.ParseObjectElement(Key: string; var JSON: PChar;
  var Length: Integer);
begin

end;

function TJSONElement.ParseJSON(Target: PJSONValue; var Input: PChar; var Length: Integer): PJSONValue;
var
  c: Char;
  key: string;
 function GetChar(IgnoreSpaces: Boolean = True): Char;
 begin
   if Length>0 then
     result:=Input^
   else
      result:=#0;

    dec(Length);
    Inc(Input);

    if IgnoreSpaces and (pos(result, ' '#9#13#10)>0) then
     result:=GetChar;
//    if (pos(result, #9#13#10)>0) then
//     result:=GetChar;
  end;

  function GetToken: TTokenData;
  var c: Char;
      a: Integer;
  begin
    c:=GetChar(True);
    result.Data:=Input;
    Dec(result.Data);
    result.Length:=1;
    if Pos(c, '[]{}')>0 then
      Exit;

    if c = '"' then begin
      //a:=pos-1;
      c:=GetChar(False);
      while system.Pos(c, string('"'#0))=0 do
      begin
        //result:=result+c;
        if c='\' then
        begin
         inc(Input);
         Dec(Length);
        end;
        c:=GetChar(False);
      end;
    end else
    begin
      a:=length-1;
      while system.Pos(GetChar(False), string(' :,]}"'#0#9#13#10))=0 do ;
      if(length-1<>a) then
      begin
        dec(Input);
        Inc(Length);
      end;
    end;
    result.Length:=(PtrUInt(Input) - PtrUInt(Result.Data)) div SizeOf(Char);
  end;

  function TokenToStr(Token: TTokenData): KString;
  begin
    Setlength(result, Token.Length);
    Move(Token.Data^, result[1], Token.Length*SizeOf(result[1]));
  end;

 procedure ClearItem(aType: TJSONValueKind);
 begin
   if aType <> jkObject then
   begin
     if Assigned(result.Obj) then
       result.Obj.TryFree;
     result.Obj:=nil;
   end else if aType <> jkList then
   begin
     if Assigned(result.List) then
       result.List.TryFree;
     result.List:=nil;
   end else if aType <> jkString then
   begin
     result.Str:='';
   end;

   result.Kind:=aType;
 end;

begin
  if not Assigned(Target) then
  begin
    GetMem(result, SizeOf(TJSONValue));
    FillChar(result^, SizeOf(TJSONValue), #0);
    result.Kind:=jkInvalid;
    inc(ElCounter);
  end else
    result:=Target;

  case GetChar(True) of
    '[': begin
      ClearItem(jkList);
      c:=',';
      if not Assigned(result.List) then
        result.List:=TJSONArray.Create(FParent);

      repeat
        if(c<>',')then
          Exit;
        //Value:=TokenToStr(GetToken);
        //callback('', Value);
        //ParseJSON(Input, Length);
        result.List.ParseArrayElement(Input, Length);
        c:=GetChar;
      until (c=#0)or(c=']');
      if c=#0 then
       Exit;
    end;
    '{': begin
      if not (result.Obj is TJSONStore) then
        ClearItem(jkObject);
      if not Assigned(result.Obj) then
        result.Obj:=TJSONObject.Create(FParent);

       c:=',';
      repeat
        if(c<>',') then
          Exit;
        Key:=unstringify(TokenToStr(GetToken));
        if GetChar<>':' then
          Exit;
        //Writeln(Key);
        result.Obj.ParseObjectElement(Key, Input, Length);
        c:=GetChar;
      until (c=#0)or(c='}');
      if c=#0 then
        Exit;
    end;
    else begin
      ClearItem(jkString);
      dec(Input);
      inc(Length);
      result.Kind:=jkString;
      //GetToken;
      result.Str:=TokenToStr(GetToken);
    end;
  end;
end;

constructor TJSONElement.Create(aParent: TJSONStore);
begin
  FParent:=aParent;
end;

function TJSONElement.toJSON2: string;
var Pos: Integer;
begin
  Setlength(Result, toJSONLength);
  Pos:=1;
  toJSONCopy(Result, Pos);
end;
(*
function TJSONElement.GetChange(var Index: Integer): PJSONChange;
begin
  if Index<>FChangePos then
  begin
    result:=FChanges[Index];
    Index:=(Index + 1) mod 1024;
  end else
    result:=nil;
end;

procedure TJSONElement.AddChange(Change: PJSONChange);
begin
  if FChanges[(FChangePos+1023) mod 1024] = Change then
    Exit;

  FChanges[FChangePos]:=Change;
  FChangePos:=(FChangePos+1) mod 1024;
end; *)

procedure TJSONElement.TryFree;
begin
  if FRefCounter<=0 then
    Free
  else
    Dec(FRefCounter);
end;

procedure TJSONElement.AddRef;
begin
  inc(FRefCounter);
end;

{ TJSONObject }

constructor TJSONObject.Create(aParent: TJSONStore);
begin
  inherited Create(aParent);
  FTable:=THashtable.Create;
end;

destructor TJSONObject.Destroy;
var
  Name: string;
  p: PJSONValue;
begin
  FTable.First;
  while FTable.GetNext(Name, Pointer(P)) do
  begin
    case P.Kind of
      jkInvalid: ;
      jkList: p.List.Free;
      jkObject: p.Obj.Free;
      jkString: p.Str:='';
    end;
    FreeMem(P);
  end;
  FTable.Free;
  inherited;
end;

function TJSONObject.Get(location: string): string;
var
  i, j: Integer;
  s: string;
  P: PJSONValue;
begin
  if location='' then
  begin
    result:=toJSON2;
  end;

  i:=Pos('.', location);
  j:=Pos('[', location);
  if(j>0) then
  begin
    if(i>0)and(i<j) then
    begin
      s:=Copy(location, 1, i-1);
      Delete(location, 1, i);
    end else
    begin
      s:=Copy(location, 1, j-1);
      Delete(location, 1, j-1);
    end;
  end else if (i>0) then
  begin
    s:=Copy(location, 1, i-1);
    Delete(location, 1, i);
  end else
  begin
    s:=location;
    location:='';
  end;

  P:=FTable[s];
  if(Assigned(P)) then
  begin
    case P.Kind of
      jkList: result:=P.List.Get(Location);
      jkObject: result:=P.Obj.Get(Location);
      jkString: result:=unstringify(P.Str);
    end;
  end;
end;

function TJSONObject.GetObj(location: string): TJSONElement;
var
  i, j: Integer;
  s: string;
  P: PJSONValue;
begin
  result:=nil;
  if location='' then
  begin
    result:=self;
    Exit;
  end;

  i:=Pos('.', location);
  j:=Pos('[', location);
  if(j>0) then
  begin
    if(i>0)and(i<j) then
    begin
      s:=Copy(location, 1, i-1);
      Delete(location, 1, i);
    end else
    begin
      s:=Copy(location, 1, j-1);
      Delete(location, 1, j-1);
    end;
  end else if (i>0) then
  begin
    s:=Copy(location, 1, i-1);
    Delete(location, 1, i);
  end else
  begin
    s:=location;
    location:='';
  end;

  P:=FTable[s];
  if(Assigned(P)) then
  begin
    case P.Kind of
      jkList: result:=P.List.GetObj(Location);
      jkObject: result:=P.Obj.GetObj(Location);
      jkString: result:=nil;
    end;
  end;
end;

function TJSONObject.Put(location, data: string): Boolean;
var
  i, j: Integer;
  s: string;
  Temp: TJSONValue;
  Temp2: PJSONValue;
  P: PChar;
  Len: Integer;
begin
//  AddChange(FParent.LastChange);
//  Writeln('a');
  if location='' then
  begin
    Temp.Kind:=jkObject;
    Temp.Obj:=Self;
    Len:=Length(data);
    P:=@data[1];
    ParseJSON(@Temp, P, Len);
    Exit;
  end;

//  Writeln('b');
  i:=Pos('.', location);
  j:=Pos('[', location);
  if(j>0) then
  begin
    if (i>0)and(i<j) then
    begin
      s:=Copy(location, 1, i-1);
      delete(location, 1, i);
    end else
    begin
      s:=Copy(location, 1, j-1);
      delete(location, 1, j);
    end;
  end else
  if (i>0) then
  begin
    s:=Copy(location, 1, i-1);
    delete(location, 1, i);
  end else
  begin
    s:=location;
    location:='';
  end;

  if location<>'' then
  begin
    Temp2:=FTable[unstringify(s)];
    if Assigned(Temp2) then
    case Temp2.Kind of
      jkInvalid: result:=False;
      jkList: result:=Temp2.List.Put(location, data);
      jkObject: result:=Temp2.Obj.Put(location, data);
      jkString: result:=False;
    end else
    begin
      result:=False;
    end;
  end else
  begin
    s:=unstringify(s);
    Len:=Length(data);
    if Len>0 then
    begin
      P:=@data[1];
      ParseObjectElement(s, P, Len);
      result:=True;
    end else
      result:=False;
  end;
end;

procedure TJSONObject.ParseObjectElement(Key: string; var JSON: PChar;
  var Length: Integer);
begin
  FTable[Key]:=ParseJSON(PJSONValue(FTable[key]), JSON, Length);
end;

function TJSONObject.toJSON: string;
var foo: PJSONValue;
  hash: string;
begin
  result:='{';
  FTable.First;
  while FTable.GetNext(hash, Pointer(foo)) do
  begin
    result:=result+hash+':'+JSONValueToStr(foo)+',';
  end;
  if Length(Result)>1 then
    result[length(result)]:='}'
  else result:=result+'}';
end;

function TJSONObject.DeleteEntry(location: string): Boolean;
var
  i, j: Integer;
  s: string;
  p: PJSONValue;
begin
  result:=False;
  if location='' then
  begin
    Exit;
  end;

  i:=Pos('.', location);
  j:=Pos('[', location);
  if(j>0) then
  begin
    if(i>0)and(i<j) then
    begin
      s:=Copy(location, 1, i-1);
      Delete(location, 1, i);
    end else
    begin
      s:=Copy(location, 1, j-1);
      Delete(location, 1, j-1);
    end;
  end else if (i>0) then
  begin
    s:=Copy(location, 1, i-1);
    Delete(location, 1, i);
  end else
  begin
    s:=location;
    P:=FTable[s];
    if Assigned(P) then
    begin
      case P^.Kind of
        jkList: p^.List.Free;
        jkObject: p^.Obj.Free;
        jkString: p^.Str:='';
      end;
      FreeMem(p);
      result:=True;
    end;
  end;

  P:=FTable[s];
  if(Assigned(P)) then
  begin
    case P.Kind of
      jkList: result:=P.List.DeleteEntry(Location);
      jkObject: result:=P.Obj.DeleteEntry(Location);
      jkString: result:=False;
    end;
  end;
end;

procedure TJSONObject.toJSONCopy(var Target: string; var Pos: Integer);
var foo: PJSONValue;
  hash: string;
begin
  FTable.First;
  if FTable.GetNext(hash, Pointer(foo)) then
  begin
    Target[Pos]:='{';
    Inc(pos);
    Target[Pos]:='"';
    Inc(pos);
    Move(hash[1], Target[Pos], Length(hash)*SizeOf(char));
    Inc(Pos, Length(hash));
    Target[Pos]:='"';
    Inc(pos);
    Target[Pos]:=':';
    Inc(Pos);
    JSONValueToStrCopy(foo, Target, Pos);
    while FTable.GetNext(hash, Pointer(foo)) do
    begin
      Target[Pos]:=',';
      Inc(Pos);
      Target[Pos]:='"';
      Inc(pos);
      Move(hash[1], Target[Pos], Length(hash)*SizeOf(char));
      Inc(Pos, Length(hash));
      Target[Pos]:='"';
      Inc(pos);
      Target[Pos]:=':';
      Inc(Pos);
      JSONValueToStrCopy(foo, Target, Pos);
    end;
    Target[Pos]:='}';
    Inc(pos);
  end else
  begin
    Target[Pos]:='{';
    inc(Pos);
    Target[Pos]:='}';
    inc(Pos);
  end;
end;

function TJSONObject.toJSONLength: integer;
var foo: PJSONValue;
  hash: string;
begin
  FTable.First;
  if FTable.GetNext(hash, Pointer(foo)) then
  begin
    result:=Length(Hash)+5+JSONGetLength(foo); // {"<name>":<value>}
    while FTable.GetNext(hash, Pointer(foo)) do
      result:=result+4+Length(Hash)+JSONGetLength(foo); // ,"<name>":<value>
  end else
    result:=2; // {}
end;

{ TJSONArray }

function TJSONArray.Get(location: string): string;
var
  i: Integer;
  s: string;
  P: PJSONValue;
begin
  if location='' then
  begin
    result:=toJSON2;
  end;

  i:=Pos('[', location);

  if (i=1) then
  begin
    s:=Copy(location, 2, pos(']', location)-2);
    Delete(location, 1, pos(']', location));

    i:=StrToIntDef(s, -1);
    if (i>=0)and(i<Length(FArray)) then
      P:=FArray[i]
    else begin
      P:=nil;
      result:='';
    end;
  end else
  begin
    p:=nil;
    result:='';
  end;

  if(Assigned(P)) then
  begin
    case P.Kind of
      jkList: result:=P.List.Get(Location);
      jkObject: result:=P.Obj.Get(Location);
      jkString: result:=unstringify(P.Str);
    end;
  end;
end;

function TJSONArray.GetObj(location: string): TJSONElement;
var
  i: Integer;
  s: string;
  P: PJSONValue;
begin
  result:=nil;
  if location='' then
  begin
    result:=Self;
  end;

  i:=Pos('[', location);

  if (i=1) then
  begin
    s:=Copy(location, 2, pos(']', location)-2);
    Delete(location, 1, pos(']', location));

    i:=StrToIntDef(s, -1);
    if (i>=0)and(i<Length(FArray)) then
      P:=FArray[i]
    else P:=nil;
  end else
    p:=nil;

  if(Assigned(P)) then
  begin
    case P.Kind of
      jkList: result:=P.List.GetObj(Location);
      jkObject: result:=P.Obj.GetObj(Location);
      jkString: result:=nil;
    end;
  end;
end;

function TJSONArray.DeleteEntry(location: string): Boolean;
var
  i: Integer;
  s: string;
  P: PJSONValue;
begin
  result:=False;
  if location='' then
  begin
    Exit;
  end;

  i:=Pos('[', location);

  if (i=1) then
  begin
    s:=Copy(location, 2, pos(']', location)-2);
    Delete(location, 1, pos(']', location));

    i:=StrToIntDef(s, -1);
    if (i>=0)and(i<Length(FArray)) then
      P:=FArray[i]
    else P:=nil;
  end else
    p:=nil;

  if Location = '' then
  begin
    if Assigned(P) then
    begin
      case P^.Kind of
        jkList: p^.List.Free;
        jkObject: p^.Obj.Free;
        jkString: p^.Str:='';
      end;
      FreeMem(p);
      result:=True;
    end;
    Exit;
  end;

  if(Assigned(P)) then
  begin
    case P.Kind of
      jkList: result:=P.List.DeleteEntry(Location);
      jkObject: result:=P.Obj.DeleteEntry(Location);
      jkString: result:=False;
    end;
  end;
end;

function TJSONArray.GetItem(Index: Integer): PJSONValue;
begin
  result:=FArray[Index];
end;

function TJSONArray.GetLength: Integer;
begin
  result:=Length(FArray);
end;

function TJSONArray.Put(location, data: string): Boolean;
begin
  result:=False;
  raise Exception.Create('Not implemented');
end;

procedure TJSONArray.ParseArrayElement(var JSON: PChar; var Length: Integer);
var i: Integer;
begin
  i:=system.Length(FArray);
  setlength(FArray, i+1);
  FArray[i]:=ParseJSON(nil, JSON, Length);
end;

function TJSONArray.toJSON: string;
var i: Integer;
begin
  result:='[';
  for i:=0 to length(FArray)-1 do
  Result:=result+JSONValueToStr(PJSONValue(FArray[i]))+',';
  if Length(Result)>1 then
    result[length(result)]:=']'
  else result:=result+']';

end;

procedure TJSONArray.toJSONCopy(var Target: string; var Pos: Integer);
var i: Integer;
begin
  Target[Pos]:='[';
  inc(Pos);
  for i:=0 to length(FArray)-1 do
  begin
    JSONValueToStrCopy(FArray[i], Target, Pos);
    if i<>Length(FArray)-1 then
    begin
      Target[Pos]:=',';
      Inc(Pos);
    end;
  end;
  Target[Pos]:=']';
  Inc(pos);
end;

destructor TJSONArray.Destroy;
begin
  Clear;
  inherited Destroy;
end;

procedure TJSONArray.Clear;
var
  i: Integer;
begin
  for i:=0 to Length(FArray)-1 do
    if Assigned(FArray[i]) then
    begin
      case FArray[i].Kind of
        jkInvalid: ;
        jkList: FArray[i].List.Free;
        jkObject: FArray[i].Obj.Free;
        jkString: FArray[i].Str:='';
      end;
      FreeMem(FArray[i]);
    end;
  Setlength(FArray, 0);
end;

function TJSONArray.toJSONLength: integer;
var i: Integer;
begin
  result:=1;
  for i:=0 to length(FArray)-1 do
  Result:=result+JSONGetLength(PJSONValue(FArray[i]))+1;
  if Result=1 then
    inc(result);
end;

{ TJSONStore }
(*
procedure TJSONStore.Parse(Data: string);
var
  P: PWideChar;
  Len: Integer;
begin
  P:=@Data[1];
  Len:=Length(Data);
  FValue:=ParseJSON(FValue, P, Len);
end;
*)

(*
function TJSONStore.toJSON: string;
begin
  result:=JSONValueToStr(FValue);
end;

function TJSONStore.toJSON2: string;
var L, Pos: Integer;
begin
  Pos:=1;
  L:=JSONGetLength(FValue);
  Setlength(Result, L);
  JSONValueToStrCopy(FValue, result, Pos);
end;
*)

end.
