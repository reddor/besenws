unit xmlhttprequest;

{$mode delphi}

interface

uses
  Classes,
  SysUtils,
  {$i besenunits.inc},
  blcksock,
  beseninstance,
  besenevents,
  epollsockets,
  webserverhosts,
  httprequest,
  httphelper,
  webserver;

type
  { TBESENXMLHttpRequest }

  TBESENXMLHttpRequest = class(TBESENNativeObject)
  private
    FRequest: THTTPRequestThread;
    FOnReadyStateChange: TBESENObjectFunction;
    FReadyState: Longword;
    FParentThread: TEpollWorkerThread;
    FResponse: TBESENString;
    FStatus: longword;
    FStatusText: TBESENString;
    FTimeout: longword;
    procedure RequestError(Sender: TObject; ErrorType: THTTPRequestError; const Message: ansistring);
    procedure RequestResponse(Sender: TObject; const ResponseCode, data: ansistring);
    function RequestForward(Sender: TObject; var newUrl: ansistring): Boolean;
    function RequestSent(Sender: TObject; Socket: TTCPBlockSocket): Boolean;
    function RequestHeadersReceived(Sender: TObject): Boolean;
    function RequestLoading(Sender: TObject): Boolean;
    function RequestConnect(Sender: TObject; Host, Port: ansistring): Boolean;
  protected
    procedure DoFire(Func: TEPollCallbackProc);
    procedure FireReadyChange;
    procedure FireReadyChangeOpened;
    procedure FireReadyChangeHeadersReceived;
    procedure FireReadyChangeLoading;
    procedure FireReadyChangeDone;

    procedure InitializeObject; override;
    function DoConnect(Method, Url: ansistring): Boolean;
  public
    destructor Destroy; override;
  published
    procedure abort(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    procedure getAllResponseHeaders(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    procedure getResponseHeader(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    procedure open(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    procedure overrideMimeType(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    procedure send(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    procedure setRequestHeader(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);

    property onreadystatechange: TBESENObjectFunction read FOnReadyStateChange write FOnReadyStateChange;
    property readyState: Longword read FReadyState;
    property response: TBESENString read FResponse;
    property responseText: TBESENString read FResponse;
    property status: longword read FStatus;
    property statusText: TBESENString read FStatusText;
    property timeout: longword read FTimeout write FTimeout;
  end;

implementation

uses
  baseunix,
  unix,
  linux,
  sockets;

{ TBESENXMLHttpRequest }


function TBESENXMLHttpRequest.DoConnect(Method, Url: ansistring): Boolean;
begin
  result:=False;
  if Assigned(FRequest) then
    Exit;

  FRequest:=THTTPRequestThread.Create(Method, url, True);
  FRequest.OnError:=RequestError;
  FRequest.OnForward:=RequestForward;
  FRequest.OnResponse:=RequestResponse;
  FRequest.OnRequestSent:=RequestSent;
  FRequest.OnHeadersReceived:=RequestHeadersReceived;
  FRequest.OnLoading:=RequestLoading;
  FRequest.OnConnect:=RequestConnect;

  if FTimeout = 0 then
    FRequest.TimeOut:=60000
  else
    FRequest.TimeOut:=FTimeout;

  FRequest.Start;
  if not Assigned(FParentThread) then
  begin

  end else
    TBESEN(Instance).GarbageCollector.Protect(Self);
end;

destructor TBESENXMLHttpRequest.Destroy;
begin
  if Assigned(FRequest) then
  begin
    FRequest.OnError:=nil;
    FRequest.OnForward:=nil;
    FRequest.OnResponse:=nil;
    if not FRequest.Finished then
    begin
      FRequest.FreeOnTerminate:=True;
    end else
      FRequest.Free;
    FRequest:=nil;
  end;
  inherited Destroy;
end;

procedure TBESENXMLHttpRequest.RequestError(Sender: TObject;
  ErrorType: THTTPRequestError; const Message: ansistring);
begin
  FStatusText:=TBESENString(Message);
  TBESEN(Instance).GarbageCollector.Unprotect(Self);
end;

procedure TBESENXMLHttpRequest.RequestResponse(Sender: TObject;
  const ResponseCode, data: ansistring);
begin
  FStatus:=StrToIntDef(Copy(ResponseCode, 1, Pos(' ', ResponseCode)-1), 0);
  FStatusText:=TBESENString(ResponseCode);
  FResponse:=TBESENString(Data);
  DoFire(FireReadyChangeDone);
end;

function TBESENXMLHttpRequest.RequestForward(Sender: TObject;
  var newUrl: ansistring): Boolean;
begin
  result:=True;
end;

function TBESENXMLHttpRequest.RequestSent(Sender: TObject;
  Socket: TTCPBlockSocket): Boolean;
begin
  result:=True;
end;

function TBESENXMLHttpRequest.RequestHeadersReceived(Sender: TObject): Boolean;
begin
  DoFire(FireReadyChangeHeadersReceived);
  result:=True;
end;

function TBESENXMLHttpRequest.RequestLoading(Sender: TObject): Boolean;
begin
  DoFire(FireReadyChangeLoading);
  result:=True;
end;

function TBESENXMLHttpRequest.RequestConnect(Sender: TObject; Host,
  Port: ansistring): Boolean;
begin
  DoFire(FireReadyChangeOpened);
  result:=True;
end;

procedure TBESENXMLHttpRequest.DoFire(Func: TEPollCallbackProc);
begin
  if Assigned(FParentThread) then
    FParentThread.Callback(Func)
  else
    Func();
end;

procedure TBESENXMLHttpRequest.FireReadyChange;
var
  AResult: TBESENValue;
begin
  try
    if Assigned(FOnReadyStateChange) then
      FOnReadyStateChange.Call(BESENObjectValue(Self), nil, 0, AResult);
  except
    on e: Exception do
    begin
      TBESENInstance(Instance).OutputException(e, 'XMLHTTPRequest.onreadystatechange');
    end;
  end;
end;

procedure TBESENXMLHttpRequest.FireReadyChangeOpened;
begin
  FReadyState:=1;
  FireReadyChange;
end;

procedure TBESENXMLHttpRequest.FireReadyChangeHeadersReceived;
begin
  FReadyState:=2;
  FireReadyChange;
end;

procedure TBESENXMLHttpRequest.FireReadyChangeLoading;
begin
  FReadyState:=3;
  FireReadyChange;
end;

procedure TBESENXMLHttpRequest.FireReadyChangeDone;
begin
  FReadyState:=4;
  FireReadyChange;
  TBESEN(Instance).GarbageCollector.Unprotect(Self);
end;

procedure TBESENXMLHttpRequest.InitializeObject;
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
end;

procedure TBESENXMLHttpRequest.abort(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
begin
  if Assigned(FRequest) then
    FRequest.Abort;
end;

procedure TBESENXMLHttpRequest.getAllResponseHeaders(
  const ThisArgument: TBESENValue; Arguments: PPBESENValues;
  CountArguments: integer; var ResultValue: TBESENValue);
begin
  if (FReadyState>=2) and Assigned(FRequest) then
    ResultValue:=BESENStringValue(TBESENString(FRequest.GetAllResponseHeaders))
  else
    ResultValue:=BESENNullValue;
end;

procedure TBESENXMLHttpRequest.getResponseHeader(
  const ThisArgument: TBESENValue; Arguments: PPBESENValues;
  CountArguments: integer; var ResultValue: TBESENValue);
begin
  if (FReadyState>=2) and Assigned(FRequest) and (CountArguments>0) then
    ResultValue:=BESENStringValue(TBESENString(FRequest.GetResponseHeader(ansistring(TBESEN(Instance).ToStr(Arguments^[0]^)))))
  else
    ResultValue:=BESENNullValue;
end;

procedure TBESENXMLHttpRequest.open(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
begin
  resultValue:=BESENNullValue;
  if CountArguments<2 then
    Exit;

  DoConnect(ansistring(TBESEN(Instance).ToStr(Arguments^[0]^)), ansistring(TBESEN(Instance).ToStr(Arguments^[1]^)));
  resultValue:=BESENBooleanValue(True);
end;

procedure TBESENXMLHttpRequest.overrideMimeType(
  const ThisArgument: TBESENValue; Arguments: PPBESENValues;
  CountArguments: integer; var ResultValue: TBESENValue);
begin

end;

procedure TBESENXMLHttpRequest.send(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
begin
  if (FReadyState<=1) and Assigned(FRequest) then
  begin
    if CountArguments>0 then
      FRequest.Send(ansistring(TBESEN(Instance).ToStr(Arguments^[0]^)))
    else
      FRequest.Send('');
    if not Assigned(FParentThread) then
      FRequest.WaitFor;
  end;
end;

procedure TBESENXMLHttpRequest.setRequestHeader(
  const ThisArgument: TBESENValue; Arguments: PPBESENValues;
  CountArguments: integer; var ResultValue: TBESENValue);
begin
  if (FReadyState<=1) and Assigned(FRequest) and (CountArguments>1) then
    FRequest.SetRequestHeader(
      ansistring(TBESEN(Instance).ToStr(Arguments^[0]^)),
      ansistring(TBESEN(Instance).ToStr(Arguments^[1]^)));
end;

end.

