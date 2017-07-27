unit xmlhttprequest;

{$mode delphi}

interface

uses
  Classes,
  SysUtils,
  {$i besenunits.inc},
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
    procedure RequestError(ErrorType: THTTPRequestError; const Message: ansistring);
    procedure RequestResponse(const ResponseCode, data: ansistring);
    function RequestForward(var newUrl: ansistring): Boolean;
  protected
    procedure FireReadyChange;
    procedure InitializeObject; override;
    function DoConnect(Url: ansistring): Boolean;
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
    property readyState: Longword read FReadyState write FReadyState;
    property response: TBESENString read FResponse;
    property responseText: TBESENString read FResponse;
    property status: longword read FStatus;
    property statusText: TBESENString read FStatusText;
    property timeout: longword read FTimeout write FTimeout;


  end;

implementation

uses
  blcksock,
  baseunix,
  unix,
  linux,
  sockets;

{ TBESENXMLHttpRequest }


function TBESENXMLHttpRequest.DoConnect(Url: ansistring): Boolean;
begin
  result:=False;
  if Assigned(FRequest) then
    Exit;

  FRequest:=THTTPRequestThread.Create(url);
  FRequest.OnError:=RequestError;
  FRequest.OnForward:=RequestForward;
  FRequest.OnResponse:=RequestResponse;

  if FTimeout = 0 then
    FRequest.TimeOut:=60000
  else
    FRequest.TimeOut:=FTimeout;
  readyState:=0;
  FRequest.Start;
  if not Assigned(FParentThread) then
  begin
    FRequest.WaitFor;
    FireReadyChange;
  end else
    TBESEN(Instance).GarbageCollector.Protect(Self);
end;

destructor TBESENXMLHttpRequest.Destroy;
begin
  if Assigned(FRequest) then
  begin
    if not FRequest.Finished then
    begin
      FRequest.FreeOnTerminate:=True;
    end else
      FRequest.Free;
    FRequest:=nil;
  end;
  inherited Destroy;
end;

procedure TBESENXMLHttpRequest.RequestError(ErrorType: THTTPRequestError;
  const Message: ansistring);
begin
  FStatusText:=TBESENString(Message);
  TBESEN(Instance).GarbageCollector.Unprotect(Self);
end;

procedure TBESENXMLHttpRequest.RequestResponse(const ResponseCode,
  data: ansistring);
begin
  FStatus:=StrToIntDef(Copy(ResponseCode, 1, Pos(' ', ResponseCode)-1), 0);
  FStatusText:=TBESENString(ResponseCode);
  FResponse:=TBESENString(Data);
  readyState:=3;
  TBESEN(Instance).GarbageCollector.Unprotect(Self);
  if Assigned(FParentThread) then
    FParentThread.Callback(FireReadyChange)
end;

function TBESENXMLHttpRequest.RequestForward(var newUrl: ansistring): Boolean;
begin
  result:=True;
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

end;

procedure TBESENXMLHttpRequest.getAllResponseHeaders(
  const ThisArgument: TBESENValue; Arguments: PPBESENValues;
  CountArguments: integer; var ResultValue: TBESENValue);
begin

end;

procedure TBESENXMLHttpRequest.getResponseHeader(
  const ThisArgument: TBESENValue; Arguments: PPBESENValues;
  CountArguments: integer; var ResultValue: TBESENValue);
begin

end;

procedure TBESENXMLHttpRequest.open(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
begin
  if CountArguments<1 then
    Exit;

  DoConnect(ansistring(TBESEN(Instance).ToStr(Arguments^[0]^)));
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

end;

procedure TBESENXMLHttpRequest.setRequestHeader(
  const ThisArgument: TBESENValue; Arguments: PPBESENValues;
  CountArguments: integer; var ResultValue: TBESENValue);
begin

end;

end.

