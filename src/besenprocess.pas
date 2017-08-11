unit besenprocess;

{$mode delphi}

interface

uses
  Classes,
  SysUtils,
  Linux,
  {$i besenunits.inc},
  beseninstance,
  webserverhosts,
  epollsockets,
  Process;

type
  TBESENProcess = class;

  { TBESENProcessDataHandler }

  TBESENProcessDataHandler = class(TCustomEpollHandler)
  private
    FTarget: TBESENProcess;
    FDataHandle: THandle;
  protected
    procedure DataReady(Event: epoll_event); override;
  public
    constructor Create(Target: TBESENProcess; Parent: TEpollWorkerThread);
    procedure SetDataHandle(Handle: THandle);
    destructor Destroy; override;
  end;

  { TBESENProcess }

  TBESENProcess = class(TBESENNativeObject)
  private
    FHasTerminated: Boolean;
    FOnData: TBESENObjectFunction;
    FOnTerminate: TBESENObjectFunction;
    FParentThread: TEpollWorkerThread;
    FParentSite: TWebserverSite;
    FProcess: TProcess;
    FDataHandler: TBESENProcessDataHandler;
  protected
    procedure ConstructObject(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer); override;
    procedure FinalizeObject; override;
    procedure StopProcess;
  public
    destructor Destroy; override;
  published
    procedure start(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    procedure stop(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    procedure addEnvironment(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    procedure write(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    procedure writeln(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    procedure isTerminated(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    property onData: TBESENObjectFunction read FOnData write FOnData;
    property onTerminate: TBESENObjectFunction read FOnTerminate write FOnTerminate;
  end;

implementation

uses
  baseunix,
  unix,
  besenwebsocket,
  termio,
  logging;

{ TBESENProcessDataHandler }

procedure TBESENProcessDataHandler.DataReady(Event: epoll_event);
var
  buf: ansistring;
  AResult, AArg: TBESENValue;
  Arg: PBESENValue;

begin
  if (Event.Events and EPOLLIN<>0) then
  begin
    setlength(buf, FTarget.FProcess.Output.NumBytesAvailable);
    FTarget.FProcess.Output.Read(buf[1], Length(buf));
    if Assigned(FTarget.onData) then
    begin
      Aarg:=BESENStringValue(TBESENString(buf));
      Arg:=@Aarg;
      try
        FTarget.onData.Call(BESENObjectValue(FTarget), @Arg, 1, AResult);
      except
        on e: Exception do
          TBESENInstance(FTarget.Instance).OutputException(e, 'Process.onData');
      end;
    end;
  end else
  begin
    FTarget.StopProcess;
  end;
end;

constructor TBESENProcessDataHandler.Create(Target: TBESENProcess;
  Parent: TEpollWorkerThread);
begin
  inherited Create(Parent);
  FTarget:=Target;
  FDataHandle:=0;
end;

procedure TBESENProcessDataHandler.SetDataHandle(Handle: THandle);
begin
  if FDataHandle = 0 then
    FDataHandle:=Handle
  else
    Exit;
  fpfcntl(FDataHandle, F_SetFl, fpfcntl(FDataHandle, F_GetFl, 0) or O_NONBLOCK);
  AddHandle(FDataHandle);
end;

destructor TBESENProcessDataHandler.Destroy;
begin
  if FDataHandle <>0 then
    RemoveHandle(FDataHandle);
  inherited Destroy;
end;

{ TBESENProcess }


procedure TBESENProcess.ConstructObject(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer);
var
  i: Integer;
  s: ansistring;
begin
  inherited ConstructObject(ThisArgument, Arguments, CountArguments);
  if CountArguments<1 then
    raise EBESENError.Create('Argument expected in constructor');

  FParentThread:=nil;
  FParentSite:=nil;

  FHasTerminated:=True;

  if Instance is TBESENInstance then
  begin
    if Assigned(TBESENInstance(Instance).Thread) and
       (TBESENInstance(Instance).Thread is TEpollWorkerThread) then
    begin
      FParentThread:=TEpollWorkerThread(TBESENInstance(Instance).Thread);
      if FParentThread is TBESENWebsocket then
        FParentSite:=TBESENWebsocket(FParentThread).Site;
    end;
  end;

  s:=ansistring(TBESEN(Instance).ToStr(Arguments^[0]^));

  if Assigned(FParentSite) then
  begin
    if(pos('/', s)<>1) then
      s:=FParentSite.Path+'bin/'+s;

    if not FParentSite.IsProcessWhitelisted(s) then
      raise EBESENError.Create('This executable may not be started from this realm');

  end;


  FProcess:=TProcess.Create(nil);
  FProcess.Executable:=s;
  FProcess.CurrentDirectory:=ExtractFilePath(s);
  for i:=1 to CountArguments-1 do
    FProcess.Parameters.Add(ansistring(TBESEN(Instance).ToStr(Arguments^[i]^)));
end;

procedure TBESENProcess.FinalizeObject;
begin
  FOnTerminate:=nil;
  StopProcess;
  inherited FinalizeObject;

  if Assigned(FProcess) then
    FreeAndNil(FProcess);
end;

procedure TBESENProcess.StopProcess;
var
  AResult: TBESENValue;
begin
  if Assigned(FProcess) then
  begin
    if Assigned(FDataHandler) then
      FreeandNil(FDataHandler);

    if FHasTerminated then
      Exit;

    dolog(llDebug, 'Terminating process '+FProcess.Executable);
    FProcess.Terminate(0);
    FHasTerminated:=True;

    if Assigned(FOnTerminate) then
    try
      FOnTerminate.Call(BESENObjectValue(Self), nil, 0, AResult);
    except
      on e: Exception do
        TBESENInstance(Instance).OutputException(e, 'Process.onTerminate');
    end;
  end;
end;

destructor TBESENProcess.Destroy;
begin
  inherited Destroy;
  if Assigned(FProcess) then
    FreeAndNil(FProcess);
end;

procedure TBESENProcess.start(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
begin
  if Assigned(FProcess) then
  begin
    if FProcess.Running then
      Exit;

    dolog(llDebug, 'Starting process '+FProcess.Executable);
    if Assigned(FParentThread) then
    begin
      FDataHandler:=TBESENProcessDataHandler.Create(Self, FParentThread);
      FProcess.Options:=[poUsePipes, poStderrToOutPut];
    end;

    FProcess.Execute;
    FHasTerminated:=False;

    if Assigned(FDataHandler) then
    begin
      FDataHandler.SetDataHandle(FProcess.Output.Handle);
    end;
  end;
end;

procedure TBESENProcess.stop(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
begin
  StopProcess;
end;

procedure TBESENProcess.addEnvironment(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  i: Integer;
begin
  if Assigned(FProcess) then
    for i:=0 to CountArguments-1 do
      FProcess.Environment.Add(ansistring(TBESEN(Instance).ToStr(Arguments^[i]^)));
end;

procedure TBESENProcess.write(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  i: Integer;
  s: ansistring;
begin
  if (not Assigned(FProcess)) or (not Assigned(FDataHandler))or(CountArguments=0) then
    Exit;

  s:='';
  for i:=0 to CountArguments-1 do
  begin
    if i>0 then s:=s+' ';
    s:=s + ansistring(TBESEN(Instance).ToStr(Arguments^[i]^));
  end;
  if s<>'' then
    FProcess.Input.WriteBuffer(s[1], Length(s));
end;

procedure TBESENProcess.writeln(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  i: Integer;
  s: ansistring;
begin
  if (not Assigned(FProcess)) or (not Assigned(FDataHandler))then
    Exit;

  s:='';
  for i:=0 to CountArguments-1 do
  begin
    if i>0 then s:=s+' ';
    s:=s + ansistring(TBESEN(Instance).ToStr(Arguments^[i]^));
  end;
  s:=s+#10;
  FProcess.Input.WriteBuffer(s[1], Length(s));
end;

procedure TBESENProcess.isTerminated(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
begin
  if Assigned(FProcess) then
    resultValue:=BESENBooleanValue(not FProcess.Running)
  else
    resultValue:=BESENBooleanValue(True);
end;

end.

