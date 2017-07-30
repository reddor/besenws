unit beseninstance;
{
 script instance for all besenws scripts

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
  Classes,
  SyncObjs,
  {$i besenunits.inc},
  filecache,
  //jaystore,
  webserverhosts,
  webserver;

type
  TBESENInstance = class;
  TBESENInstanceHandler = procedure of object;

  PBESENTimerEvent = ^TBESENTimerEvent;
  TBESENTimerEvent = record
    TimeStart,
    Timeout: Longword;
    Code: TBESENUTF8STRING;
    Obj: TBESENObjectFunction;
    ParentObj: TBESENValue;
  end;

  { TBESENTimerEvents }

  TBESENTimerEvents = class
  private
    FInstance: TBESENInstance;
    FItems: array of TBESENTimerEvent;
    function AddEvent: PBESENTimerEvent;
    function GetTime: longword;
  protected
    procedure Process;
  public
    constructor Create(AInstance: TBESENInstance);
    destructor Destroy; override;
    procedure Add(TimeOut: Integer; Code: TBESENUTF8STRING); overload;
    procedure Add(TimeOut: Integer; Func: TBESENObjectFunction; AParent: TBESENValue); overload;
  end;

  { TBESENSystemObject }

  TBESENSystemObject = class(TBESENNativeObject)
  private
    FSite: TWebserverSite;
    FOnTick: TBESENObjectFunction;
    FTimer: TBESENTimerEvents;
    procedure Process;
  public
    constructor Create(AParent: TBESENInstance; Site: TWebserverSite);
    destructor Destroy; override;
  published
    { log(message) - outputs a message in the global besenws log }
    procedure log(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { setTimeout(function, timeOut) - the same function as in javascript }
    procedure setTimeout(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { readFile(filename) - returns the contents of filename. "root" is the web directory of the current site. not implemented in configuration scripts }
    procedure readFile(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { writeFile(filename, content) - writes content into filename. file is only modified in cache! }
    procedure writeFile(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { load(jsonpath) - reads from the persistent JSON storage }
    procedure load(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    (* save(jsonpath, content) - saves something in the persistent JSON storage

      Example:
        system.save("test", {foo:"bar", numbers:[1, 2, 3]});

        system.load("test.foo") -> returns "bar"
        system.load("test.numbers") -> returns [1, 2, 3]
        system.load("test") -> returns the whole object

      does not work for configuration scripts!
    *)
    procedure save(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { eval(filename, data) - just like the regular eval() function, but with an additional filename parameter.
      if the script has an error, the resulting error will report "filename" as the source of the error }
    procedure eval(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { callback = function() - called at random intervals }
    property onTick: TBESENObjectFunction read FOnTick write FOnTick;
  end;

  { TBESENInstance }

  TBESENInstance = class(TBESEN)
  private
    FManager: TWebserverSiteManager;
    FSite: TWebserverSite;
    FFileNames: array of string;
    FHandlers: array of TBESENInstanceHandler;
    FSystemObject: TBESENSystemObject;
    FTicks: Integer;
    FThread: TThread;
    { importScripts(filename1, filename2, ...) - executes scripts }
    procedure NativeImportScripts(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
  public
    ShuttingDown: Boolean;
    constructor Create(Manager: TWebserverSiteManager; Site: TWebserverSite; Thread: TThread= nil);
    destructor Destroy; override;
    procedure ProcessHandlers;
    procedure AddEventHandler(Handler: TBESENInstanceHandler);
    procedure RemoveEventHandler(Handler: TBESENInstanceHandler);
    procedure OutputException(e: Exception; Section: ansistring = '');
    property Thread: TThread read FThread;
  end;

implementation

uses
  besenserverconfig,
  besenprocess,
  xmlhttprequest,
  besenevents,
  besendb,
  logging;

{ TBESENSystemObject }

procedure TBESENSystemObject.Process;
var
  AResult: TBESENValue;
begin
  if Assigned(FOnTick) then
  try
    FOnTick.Call(BESENObjectValue(Self), nil, 0, AResult);
  except
    on e: Exception do
      TBESENInstance(Instance).OutputException(e, 'system.onTick');
  end;
end;

constructor TBESENSystemObject.Create(AParent: TBESENInstance;
  Site: TWebserverSite);
begin
  FSite:=Site;
  FTimer:=TBESENTimerEvents.Create(AParent);
  AParent.AddEventHandler(Process);

  inherited Create(AParent);
  InitializeObject;
end;

destructor TBESENSystemObject.Destroy;
begin
  FTimer.Free;
  inherited Destroy;
end;

procedure TBESENSystemObject.log(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  s: ansistring;
  i: Integer;
begin
  ResultValue:=BESENUndefinedValue;
  if CountArguments<1 then
    Exit;

  s:='';
  for i:=0 to CountArguments-1 do
    s:=s + ansistring(TBESEN(Instance).ToStr(Arguments^[i]^));

  s:= '['+ExtractFilename(TBESENInstance(Instance).GetFilename)+':'+IntToStr(TBESENInstance(Instance).LineNumber)+'] '+s;
  if Assigned(FSite) then
    FSite.log(llDebug, s)
  else
    dolog(llDebug, '[script] '+s);
end;

procedure TBESENSystemObject.setTimeout(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  timeout: longword;
begin
  ResultValue:=BESENUndefinedValue;
  if CountArguments<2 then
    Exit;

  timeout:=TBESEN(Instance).ToInt(Arguments^[1]^);

  if Arguments^[0]^.ValueType = bvtOBJECT then
  begin
    if Arguments^[0]^.Obj is TBESENObjectFunction then
      FTimer.Add(timeout, TBESENObjectFunction(Arguments^[0]^.Obj), BESENObjectValue(Self))
    else
      raise EBESENError.Create('function expected');
  end else
    FTimer.Add(timeout, BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[0]^)));

  ResultValue:=BESENBooleanValue(True);
end;

procedure TBESENSystemObject.readFile(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  s: string;
  gzip: Boolean;
begin
  ResultValue:=BESENUndefinedValue;

  if CountArguments<1 then
    Exit;

  if not Assigned(FSite) then
    Exit;

  gzip:=False;
  if FSite.Files.GetFile(ansistring(TBESEN(Instance).ToStr(Arguments^[0]^)), s, gzip)>0 then
  begin
    ResultValue:=BESENStringValue(TBESENString(s));
  end;
end;

procedure TBESENSystemObject.writeFile(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
begin
  ResultValue:=BESENUndefinedValue;

  if CountArguments<2 then
    Exit;

  if not Assigned(FSite) then
    Exit;

  FSite.Files.AddFile(ansistring(TBESEN(Instance).ToStr(Arguments^[0]^)), ansistring(TBESEN(Instance).ToStr(Arguments^[1]^)), '');
end;

procedure TBESENSystemObject.load(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  v: TBESENValue;
  pv: PBESENValue;
  s, s2: TBESENString;
begin
  ResultValue:=BESENUndefinedValue;

  if CountArguments<1 then
    Exit;

  if not Assigned(FSite) then
    Exit;

  try
    s:=TBESEN(Instance).ToStr(Arguments^[0]^);
    s2:=BESENUTF8ToUTF16(FSite.GetStore(BESENUTF16ToUTF8(s)));
    v:=BESENStringValue(s2);
    pv:=@v;
    if s2<>'' then
      TBESEN(Instance).ObjectJSON.NativeParse(BESENObjectValue(TBESEN(Instance).ObjectJSON), @pv, 1, ResultValue);
  except
    on e: Exception do
    begin
      dolog(llError, 'Could not parse JSON storage: '+e.Message+' '+ansistring(s)+' "'+ansistring(s2)+'"');
      ResultValue:=BESENUndefinedValue;
    end;
  end;
end;

procedure TBESENSystemObject.save(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  s: TBESENValue;
  arglist: PBESENValue;
begin
  ResultValue:=BESENUndefinedValue;

  if CountArguments<2 then
    Exit;

  if not Assigned(FSite) then
    Exit;

  arglist:=Arguments^[1];


  TBESEN(Instance).ObjectJSON.NativeStringify(BESENObjectValue(TBESEN(Instance).ObjectJSON), @arglist, 1, s);

  if FSite.PutStore(BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[0]^)), BESENUTF16ToUTF8(TBESEN(Instance).ToStr(s))) then
    ResultValue:=BESENBooleanValue(True);
end;

procedure TBESENSystemObject.eval(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  lf: longword;
begin
  ResultValue:=BESENUndefinedValue;

  if CountArguments<2 then
    Exit;

  lf:=TBESENInstance(Instance).FilenameSet;
  TBESENInstance(Instance).SetFilename(BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[0]^)));
  try
    resultValue:=TBESEN(Instance).Eval(BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[1]^)), BESENUndefinedValue);
  finally
    TBESENInstance(Instance).FilenameSet:=lf;
  end;
end;

{ TBESENTimerEvents }

function TBESENTimerEvents.AddEvent: PBESENTimerEvent;
var
  i: Integer;
begin
  i:=Length(FItems);
  Setlength(FItems, i+1);
  result:=@FItems[i];
  result^.TimeStart:=GetTime;
end;

function TBESENTimerEvents.GetTime: longword;
begin
  result:=longword(GetTickCount64);
end;

constructor TBESENTimerEvents.Create(AInstance: TBESENInstance);
begin
  FInstance:=AInstance;
  FInstance.AddEventHandler(Process);
end;

destructor TBESENTimerEvents.Destroy;
begin
  FInstance.RemoveEventHandler(Process);
  inherited Destroy;
end;

procedure TBESENTimerEvents.Add(TimeOut: Integer; Code: TBESENUTF8STRING);
var
  p: PBESENTimerEvent;
begin
  p:=AddEvent;
  p^.Timeout:=TimeOut;
  p^.Code:=Code;
  p^.Obj:=nil;
end;

procedure TBESENTimerEvents.Add(TimeOut: Integer; Func: TBESENObjectFunction;
  AParent: TBESENValue);
var
  p: PBESENTimerEvent;
begin
  p:=AddEvent;
  p^.Timeout:=TimeOut;
  p^.Code:='';
  p^.Obj:=Func;
  p^.ParentObj:=AParent;
  FInstance.GarbageCollector.Protect(p^.Obj);
  if (p^.ParentObj.ValueType = bvtOBJECT) and Assigned(p^.ParentObj.Obj) then
    FInstance.GarbageCollector.Protect(TBESENGarbageCollectorObject(p^.ParentObj.Obj));
end;

procedure TBESENTimerEvents.Process;
var
  time: Longword;
  i: Integer;
  p: PBESENTimerEvent;
  AResult: TBESENValue;
begin
  time:=GetTime;
  i:=0;
  while i<Length(FItems) do
  begin
    p:=@FItems[i];
    if (time - p^.TimeStart)>=(p^.Timeout) then
    begin
      if p^.Code <> '' then
      begin
        try
          FInstance.Execute(p^.Code)
        except
          on e: Exception do
          FInstance.OutputException(e, 'timer event');
        end;
      end
      else if Assigned(p^.Obj) then
      begin
        try
          p^.Obj.Call(p^.ParentObj, nil, 0, AResult);
        except
          on e: Exception do
            FInstance.OutputException(e, 'timer event');
        end;
        FInstance.GarbageCollector.UnProtect(p^.Obj);
        if (p^.ParentObj.ValueType = bvtOBJECT) and Assigned(p^.ParentObj.Obj) then
          FInstance.GarbageCollector.Protect(TBESENGarbageCollectorObject(p^.ParentObj.Obj));
      end;
      FItems[i]:=FItems[Length(FItems)-1];
      Setlength(FItems, Length(FItems)-1);
    end else
    begin
      inc(i);
    end;
  end;
end;

{ TBESENInstance }

procedure TBESENInstance.NativeImportScripts(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  i: Integer;
  s, data: ansistring;
  gzip: Boolean;
  oldfile: integer;
begin
  resultValue:=BESENUndefinedValue;
  oldfile:=FilenameSet;
  for i:=0 to CountArguments-1 do
  begin
    gzip:=False;
    s:=BESENUTF16ToUTF8(ToStr(Arguments^[i]^));
    if Pos('./', s)=1 then
      Delete(s, 1, 1);

    SetFilename(s);
    if Assigned(FSite) and (FSite.Files.GetFile(s, data, gzip)>0) then
    begin
      Execute(data);
    end else
    if FManager.SharedScripts.GetFile(s, data, gzip)>0 then
    begin
      Execute(data);
    end;
  end;
  FilenameSet:=oldfile;
end;

constructor TBESENInstance.Create(Manager: TWebserverSiteManager;
  Site: TWebserverSite; Thread: TThread);
begin
  inherited Create(COMPAT_JS);
  ShuttingDown:=False;
  FManager:=Manager;
  FSystemObject:=TBESENSystemObject.Create(Self, Site);
  GarbageCollector.Protect(FSystemObject);
  Setlength(FFileNames, 1);
  FFileNames[0]:='Unknown';
  FSite:=Site;
  FThread:=Thread;

  ObjectGlobal.put('system', BESENObjectValue(FSystemObject), false);
  RegisterNativeObject('EventList', TBESENEventListener);
  RegisterNativeObject('DatabaseConnection', TBESENDatabaseConnection);
  RegisterNativeObject('XMLHTTPRequest', TBESENXMLHttpRequest);
  RegisterNativeObject('Process', TBESENProcess);

  ObjectGlobal.RegisterNativeFunction('importScripts',NativeImportScripts,0,[]);
  ObjectGlobal.RegisterNativeFunction('setTimeout',FSystemObject.setTimeout,0,[]);
end;

destructor TBESENInstance.Destroy;
begin
  ShuttingDown:=True;
  inherited Destroy;
  Setlength(FHandlers, 0);
end;

procedure TBESENInstance.ProcessHandlers;
var
  i: Integer;
begin
  Inc(FTicks);
  for i:=0 to Length(FHandlers)-1 do
    FHandlers[i]();

  if FTicks mod 30 = 0 then
    GarbageCollector.Collect;
end;

procedure TBESENInstance.AddEventHandler(Handler: TBESENInstanceHandler);
var
  i: Integer;
begin
  i:=Length(FHandlers);
  Setlength(FHandlers, i+1);
  FHandlers[i]:=Handler;
end;

procedure TBESENInstance.RemoveEventHandler(Handler: TBESENInstanceHandler);
var
  i: Integer;
begin
  for i:=0 to Length(FHandlers)-1 do
  begin
    if @FHandlers[i] = @Handler then
    begin
      FHandlers[i]:=FHandlers[Length(FHandlers)-1];
      Setlength(FHandlers, Length(FHandlers)-1);
      Exit;
    end;
  end;
end;

procedure TBESENInstance.OutputException(e: Exception; Section: ansistring);
var
  s: ansistring;
begin
  s:='['+StripBasePath(GetFilename)+':'+IntToStr(LineNumber)+'] '+e.Message;
  if Section <> '' then
    s:='['+Section+'] '+s;

  if Assigned(FSite) then
    s:='['+FSite.Name+'] '+s;

  dolog(llError, s);
end;

end.

