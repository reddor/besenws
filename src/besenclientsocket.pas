unit besenclientsocket;

{$mode delphi}

interface

uses
  Classes,
  SysUtils,
  baseunix,
  unix,
  linux,
  {$i besenunits.inc},
  blcksock,
  beseninstance,
  besenevents,
  epollsockets;

type
  TBESENClientSocket = class;

  { TSocketConnectThread }

  { a separate thread that does (blocking) connect and domain name lookup.
    This is kinda a lazy approach }

  TSocketConnectThread = class(TThread)
  private
    FParent: TBESENClientSocket;
    FHost, FPort: ansistring;
  protected
    procedure Execute; override;
  public
    constructor Create(Parent: TBESENClientSocket; const host, port: ansistring);
  end;

  { TBESENClientSocketDataHandler }

  TBESENClientSocketDataHandler = class(TCustomEpollHandler)
  private
    FParent: TBESENClientSocket;
    FSocket: THandle;
  protected
    function DataReady(Event: epoll_event): Boolean; override;
  public
    constructor Create(Parent: TBESENClientSocket);
    destructor Destroy; override;
  end;

  { TBESENClientSocket }

  TBESENClientSocket = class(TBESENNativeObject)
  private
    FOnConnect: TBESENObjectFunction;
    FOnDisconnect: TBESENObjectFunction;
    FSocket: TTCPBlockSocket;
    FOnData: TBESENObjectFunction;
    FParentThread: TEpollWorkerThread;
    FConnected: Boolean;
    FDataHandler: TBESENClientSocketDataHandler;
    FIsDisconnecting: Boolean;
    function GetLastErrorString: TBESENString;
  protected
    procedure InitializeObject; override;
    procedure FinalizeObject; override;
    procedure CheckDisconnect;

    procedure FireConnect;
    procedure FireDisconnect;
    procedure FireData(const data: ansistring);
  public
    { called from TSocketConnectThread when connection has been established }
    procedure ConnectionSuccess;
    { called from TSocketConnectThread when connection attempt failed }
    procedure ConnectionFail;
    property Socket: TTCPBlockSocket read FSocket;
    property ParentThread: TEpollWorkerThread read FParentThread;
  published
    { connect(host, port) - returns true or false in synchronous mode, or true in asynchronous mode.
      In asynchronous mode, onConnect will be fired on successful connect, otherwise onDisconnect }
    procedure connect(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { disconnect() - disconnects socket }
    procedure disconnect(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { send(...) - sends string(s) to socket. returns false if EWOULDBLOCK/EAGAIN is returned, otherwise true (even if socket has been disconnected) }
    procedure send(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { recv(length, timeOut) - reads string from socket. in synchronous mode it considers passed length and timeout parameters.
      in asynchronous mode it will return up to min(length, <available bytes on socket>), so nothing blocks }
    procedure recv(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { only fired in asynchronous mode when connection attempt succeeded }
    property onConnect: TBESENObjectFunction read FOnConnect write FOnConnect;
    { only fired in asynchronous mode when data is available - first argument is string with received data }
    property onData: TBESENObjectFunction read FOnData write FOnData;
    { fired when socket gets disconnected }
    property onDisconnect: TBESENObjectFunction read FOnDisconnect write FOnDisconnect;
    property lastError: TBESENString read GetLastErrorString;
  end;

implementation

uses
  Math,
  synsock;

{ TBESENClientSocketDataHandler }

function TBESENClientSocketDataHandler.DataReady(Event: epoll_event): Boolean;
var
  s: ansistring;
begin
  result:=True;
  if (Event.Events and EPOLLIN<>0) then
  begin
    s:=FParent.Socket.RecvBufferStr(1024 * 64, 0);
    FParent.FireData(s);
  end else
    FParent.ConnectionFail;
end;

constructor TBESENClientSocketDataHandler.Create(Parent: TBESENClientSocket);
begin
  FParent:=Parent;
  inherited Create(FParent.ParentThread);
  FSocket:=Parent.Socket.Socket;
  fpfcntl(FSocket, F_SetFl, fpfcntl(FSocket, F_GetFl, 0) or O_NONBLOCK);
  AddHandle(FSocket);
end;

destructor TBESENClientSocketDataHandler.Destroy;
begin
  RemoveHandle(FSocket);
  inherited Destroy;
end;

{ TSocketConnectThread }

procedure TSocketConnectThread.Execute;
begin
  FParent.Socket.Connect(FHost, FPort);
  if FParent.Socket.LastError = 0 then
    FParent.ParentThread.Callback(FParent.ConnectionSuccess)
  else
    FParent.ParentThread.Callback(FParent.ConnectionFail);
end;

constructor TSocketConnectThread.Create(Parent: TBESENClientSocket; const host,
  port: ansistring);
begin
  FParent:=Parent;
  FHost:=host;
  FPort:=port;

  FreeOnTerminate:=True;
  inherited Create(False);
end;

{ TBESENClientSocket }

function TBESENClientSocket.GetLastErrorString: TBESENString;
begin
  if FConnected and Assigned(FSocket) then
    result:=TBESENString(FSocket.LastErrorDesc)
  else
    result:='';
end;

procedure TBESENClientSocket.InitializeObject;
begin
  inherited InitializeObject;
  if Assigned(TBESENInstance(Instance).Thread) and
     (TBESENInstance(Instance).Thread is TEpollWorkerThread) then
  begin
    FParentThread:=TEpollWorkerThread(TBESENInstance(Instance).Thread)
  end
  else begin
    FParentThread:=nil;
  end;
  FSocket:=nil;
  FIsDisconnecting:=False;
end;

procedure TBESENClientSocket.FinalizeObject;
begin
  inherited FinalizeObject;
  if Assigned(FSocket) then
   FreeAndNil(FSocket);
  if Assigned(FDataHandler) then
    FreeAndNil(FDataHandler);
end;

procedure TBESENClientSocket.CheckDisconnect;
begin
  if FIsDisconnecting then
   Exit;
  FIsDisconnecting:=True;
  try
    if FConnected and Assigned(FSocket) then
    begin
      if (FSocket.LastError <> 0) and (FSocket.LastError <> WSAETIMEDOUT) and (FSocket.LastError <> WSAEWOULDBLOCK) then
      begin
        FireDisconnect;
        FreeAndNil(FSocket);
        FConnected:=False;
      end;
    end;
  finally
    FIsDisconnecting:=False;
  end;
end;

procedure TBESENClientSocket.FireConnect;
var
  AResult: TBESENValue;
begin
  try
    if Assigned(FOnConnect) then
      FOnConnect.Call(BESENObjectValue(Self), nil, 0, AResult);
  except
    on e: Exception do
    begin
      TBESENInstance(Instance).OutputException(e, 'ClientSocket.onConnect');
    end;
  end;
end;

procedure TBESENClientSocket.FireDisconnect;
var
  AResult: TBESENValue;
begin
  try
    if Assigned(FOnDisconnect) then
      FOnDisconnect.Call(BESENObjectValue(Self), nil, 0, AResult);
  except
    on e: Exception do
    begin
      TBESENInstance(Instance).OutputException(e, 'ClientSocket.onDisconnect');
    end;
  end;
end;

procedure TBESENClientSocket.FireData(const data: ansistring);
var
  AData: TBESENValue;
  PData: PBESENValue;
  AResult: TBESENValue;
begin
  PData:=@AData;
  AData:=BESENStringValue(TBESENString(data));
  try
    if Assigned(FOnData) then
      FOnData.Call(BESENObjectValue(Self), @PData, 1, AResult);
  except
    on e: Exception do
    begin
      TBESENInstance(Instance).OutputException(e, 'ClientSocket.onData');
    end;
  end;
end;

procedure TBESENClientSocket.ConnectionSuccess;
begin
  FConnected:=True;
  FDataHandler:=TBESENClientSocketDataHandler.Create(Self);
  TBESEN(Instance).GarbageCollector.Unprotect(Self);
  FireConnect;
end;

procedure TBESENClientSocket.ConnectionFail;
begin
  if FConnected and Assigned(FSocket) then
  begin
    FireDisconnect;
    FreeAndNil(FSocket);
    FConnected:=False;
    FreeAndNil(FDataHandler);
  end;
end;

procedure TBESENClientSocket.connect(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
begin
  ResultValue:=BESENBooleanValue(False);
  if Assigned(FSocket) then
    Exit;
  if CountArguments<2 then
    Exit;

  FSocket:=TTCPBlockSocket.Create;
  if Assigned(FParentThread) then
  begin
    // do asynchronous connect in thread
    FConnected:=False;
    TSocketConnectThread.Create(Self,
      ansistring(TBESEN(Instance).ToStr(Arguments^[0]^)),
      ansistring(TBESEN(Instance).ToStr(Arguments^[1]^)));
    ResultValue:=BESENBooleanValue(True);
    TBESEN(Instance).GarbageCollector.Protect(Self);
  end else
  begin
    FSocket.Connect(
      ansistring(TBESEN(Instance).ToStr(Arguments^[0]^)),
      ansistring(TBESEN(Instance).ToStr(Arguments^[1]^)));
    if FSocket.LastError = 0 then
    begin
      ResultValue:=BESENBooleanValue(True);
      FConnected:=True;
    end else
    begin
      FreeAndNil(FSocket);
    end;
  end;
end;

procedure TBESENClientSocket.disconnect(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
begin
  if FConnected and Assigned(FSocket) then
  begin
    FSocket.CloseSocket;
    FreeAndNil(FSocket);
    ResultValue:=BESENBooleanValue(true);
    FConnected:=False;
  end else
    ResultValue:=BESENBooleanValue(false);
end;

procedure TBESENClientSocket.send(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  i: Integer;
begin
  if FConnected and Assigned(FSocket) then
  begin
    for i:=0 to CountArguments-1 do
      FSocket.SendString(ansistring(TBESEN(Instance).ToStr(Arguments^[i]^)));

    ResultValue:=BESENBooleanValue(FSocket.LastError <> WSAEWOULDBLOCK);
    CheckDisconnect();
  end else
    ResultValue:=BESENBooleanValue(False);
end;

procedure TBESENClientSocket.recv(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  i, TimeOut: Integer;
  s: ansistring;
begin
  s:='';
  if FConnected and Assigned(FSocket) then
  begin
    if Assigned(FParentThread) then
    begin
      i:=FSocket.WaitingData;
      if CountArguments>0 then
        i:=Min(i, Max(0, TBESEN(Instance).ToInt(Arguments^[0]^)));
      if i>0 then
      begin
        s:=FSocket.RecvBufferStr(i, 0);
        CheckDisconnect;
      end;
    end else
    begin
      if CountArguments>0 then
      begin
        i:=Max(0, TBESEN(Instance).ToInt(Arguments^[0]^));
        if CountArguments>1 then
          TimeOut:=TBESEN(Instance).ToInt(Arguments^[1]^)
        else
          TimeOut:=30000;
        s:=FSocket.RecvBufferStr(i, TimeOut);
        CheckDisconnect;
      end;
    end;
  end;
  ResultValue:=BESENStringValue(TBESENString(s));
end;

end.

