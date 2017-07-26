unit besenwebsocket;
{
 asynchronous besen classes for websockets (and regular http requests)

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
  beseninstance,
  besenevents,
  epollsockets,
  webserverhosts,
  webserver;

type
  { TBESENWebsocketClient }

  { client object - this is created automatically for each new connection and
    passed to the script via global handler object callbacks.

    for regular http clients, .disconnect() must be called after the request
    has been processed. Otherwise the client will never receive a response
  }
  TBESENWebsocketClient = class(TBESENNativeObject)
  private
    FIsRequest: Boolean;
    FReply: TBESENString;
    FConnection: THTTPConnection;
    function GetHostname: string;
    function GetLag: Integer;
    function GetPingTime: Integer;
    function GetPongTime: Integer;
    function GetPostData: string;
    procedure SetPingTime(AValue: Integer);
    procedure SetPongTime(AValue: Integer);
  protected
   procedure InitializeObject; override;
   procedure FinalizeObject; override;
  published
    { send(data) - sends data to client }
    procedure send(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { disconnect() - disconnects the client }
    procedure disconnect(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { getHeader(item) - returns an entry from the http request header }
    procedure getHeader(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { redirect(url) - perform a redirect (if not websocket) }
    procedure redirect(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { the remote client ip }
    property host: string read GetHostname;
    { client lag - only measured/updated during idle pings }
    property lag: Integer read GetLag;
    { raw http post data (for regular http requests) }
    property postData: string read GetPostData;
    { ping interval for client connection (only sent when idle), in seconds }
    property pingTime: Integer read GetPingTime write SetPingTime;
    { maximum timeframe for a ping-reply before the connection is dropped }
    property maxPongTime: Integer read GetPongTime write SetPongTime;
  end;

  { TBESENWebsocketHandler }

  { global "handler" object for websocket scripts }
  TBESENWebsocketHandler = class(TBESENNativeObject)
  private
    FOnConnect: TBESENObjectFunction;
    FOnData: TBESENObjectFunction;
    FOnDisconnect: TBESENObjectFunction;
    FOnRequest: TBESENObjectFunction;
    FUrl: TBESENString;
  published
    { onRequest = function(client) - callback function for an incoming regular http request }
    property onRequest: TBESENObjectFunction read FOnRequest write FOnRequest;
    { onConnect = function(client) - callback function for new incoming websocket connection }
    property onConnect: TBESENObjectFunction read FOnConnect write FOnConnect;
    { onData = function(client, data) - callback function for incoming websocket client data }
    property onData: TBESENObjectFunction read FOnData write FOnData;
    { onDisconnect = function(client) - callback function when a client disconnects }
    property onDisconnect: TBESENObjectFunction read FOnDisconnect write FOnDisconnect;
    property url: TBESENString read FUrl;
  end;

  { TBESENWebsocket }

  TBESENWebsocket = class(TEPollWorkerThread)
  private
    FFilename: string;
    FSite: TWebserverSite;
    FInstance: TBESENInstance;
    FHandler: TBESENWebsocketHandler;
    FClients: array of TBESENWebsocketClient;
    FIdleTicks: Integer;
    FUrl: TBESENString;
  protected
    procedure LoadBESEN;
    procedure UnloadBESEN;
    function GetClient(AClient: THTTPConnection): TBESENWebsocketClient;
    procedure ThreadTick; override;
    procedure AddConnection(Client: TEPollSocket);
    procedure ClientData(Sender: THTTPConnection; data: ansistring);
    procedure ClientDisconnect(Sender: TEPollSocket);
  public
    constructor Create(aParent: TWebserver; ASite: TWebserverSite; AFile: string; Url: TBESENString);
    destructor Destroy; override;
  end;

implementation

uses
  logging;

{ TBESENWebsocketHandler }

constructor TBESENWebsocket.Create(aParent: TWebserver; ASite: TWebserverSite;
  AFile: string; Url: TBESENString);
begin
  FSite:=ASite;
  OnConnection:=AddConnection;
  FFilename:=ASite.Path+AFile;
  FInstance:=nil;
  FURL:=Url;
  LoadBESEN;
  inherited Create(aParent);
end;

destructor TBESENWebsocket.Destroy; 
begin
  inherited; 
  UnloadBESEN;
end;

procedure TBESENWebsocket.LoadBESEN;
begin
  dolog(llDebug, 'Loading BESEN Websocket '+FFilename);
  if Assigned(FInstance) then
    Exit;

  FInstance:=TBESENInstance.Create(FSite.Parent, FSite, self);
  FHandler:=TBESENWebsocketHandler.Create(FInstance);
  FHandler.InitializeObject;
  FHandler.FUrl:=FUrl;

  FInstance.GarbageCollector.Add(TBESENObject(FHandler));
  FInstance.GarbageCollector.Protect(TBESENObject(FHandler));

  FInstance.ObjectGlobal.put('handler', BESENObjectValue(FHandler), false);
  FInstance.SetFilename(FFilename);
  try
    FInstance.Execute(BESENGetFileContent(FFilename));
  except
    on e: Exception do
      dolog(llDebug, 'Error executing websocket script '+FFilename+','+IntToStr(FInstance.LineNumber)+': '+e.Message);
  end;
end;

procedure TBESENWebsocket.UnloadBESEN;
var
  conn: THTTPConnection;
begin
  if FInstance = nil then
    Exit;

  dolog(llDebug, 'Unloading BESEN Websocket '+FFilename);

  while Length(FClients)>0 do
  begin
    conn:=FClients[0].FConnection;
    ClientDisconnect(conn);
    TWebserver(Parent).FreeConnection(conn);
  end;

  FInstance.GarbageCollector.UnProtect(TBESENObject(FHandler));

  FInstance.Free;
  FInstance:=nil;
  FHandler:=nil;
end;

procedure TBESENWebsocket.ClientData(Sender: THTTPConnection; data: ansistring);
var
  client: TBESENWebsocketClient;
  a: array[0..1] of PBESENValue;
  v,v2, AResult: TBESENValue;
begin
  client:=GetClient(Sender);
  a[0]:=@v;
  a[1]:=@v2;

  v:=BESENObjectValue(client);

  v2:=BESENStringValue(BESENUTF8ToUTF16(data));
  try
    if Assigned(FHandler.onData) then
      FHandler.onData.Call(BESENObjectValue(FHandler), @a, 2, AResult)
    else
     dolog(llDebug, 'No Data handler');
  except
    on e: Exception do
      FSite.log(llError, '[script] ['+FInstance.GetFilename+':'+IntToStr(FInstance.LineNumber)+': '+ e.Message);
  end;
end;

procedure TBESENWebsocket.ClientDisconnect(Sender: TEPollSocket);
var
  client: TBESENWebsocketClient;
  a: array[0..0] of PBESENValue;
  v, AResult: TBESENValue;
  i: Integer;
begin
  if not (Sender is THTTPConnection) then
    Exit;

  client:=GetClient(THTTPConnection(Sender));
  if not Assigned(client) then
    Exit;

  a[0]:=@v;
  v:=BESENObjectValue(client);

  if not client.FIsRequest then
  begin
    if Assigned(FHandler.onDisconnect) then
    try
      FHandler.onDisconnect.Call(BESENObjectValue(FHandler), @a, 1, AResult);
    except
      on e: Exception do
        dolog(llError, 'Script error in line '+IntToStr(FInstance.LineNumber)+': '+ e.Message);
    end;
  end;
  FInstance.GarbageCollector.UnProtect(TBESENObject(client));

  for i:=0 to Length(FClients)-1 do
    if FClients[i] = client then
    begin
      FClients[i]:=FClients[Length(FClients)-1];
      Setlength(FClients, Length(FClients)-1);
      Break;
   end;

  FInstance.GarbageCollector.Collect;
end;

function TBESENWebsocket.GetClient(AClient: THTTPConnection): TBESENWebsocketClient;
var
  i: Integer;
begin
  result:=nil;
  for i:=0 to Length(FClients)-1 do
    if FClients[i].FConnection = AClient then
    begin
      result:=FClients[i];
      Exit;
    end;
end;

procedure TBESENWebsocket.AddConnection(Client: TEPollSocket);
var
  i: Integer;
  a: PBESENValue;
  v: TBESENValue;
  AResult: TBESENValue;
  aclient: TBESENWebsocketClient;
begin
  if not (Client is THTTPConnection) then
    Exit;

  if not Assigned(FInstance) then
    LoadBESEN;

  aclient:=TBESENWebsocketClient.Create(FInstance);
  FInstance.GarbageCollector.Add(TBESENObject(aclient));
  FInstance.GarbageCollector.Protect(TBESENObject(aclient));

  aclient.InitializeObject;
  aclient.FConnection:=THTTPConnection(Client);
  aclient.FConnection.OnData:=ClientData;
  aclient.FConnection.OnDisconnect:=ClientDisconnect;

  a:=@v;
  i:=Length(FClients);
  Setlength(FClients, i+1);
  FClients[i]:=aClient;
  v:=BESENObjectValue(aClient);

  aclient.FIsRequest:=not aclient.FConnection.CanWebsocket;
  if aclient.FIsRequest then
  begin
    try
      if Assigned(FHandler.onRequest) then
        FHandler.onRequest.Call(BESENObjectValue(FHandler), @a, 1, AResult);
    except
      on e: Exception do
        dolog(llError, 'Script error in line '+IntToStr(FInstance.LineNumber)+': '+ e.Message);
    end;
  end else
  begin
    aclient.FConnection.UpgradeToWebsocket;
    try
      if Assigned(FHandler.onConnect) then
        FHandler.onConnect.Call(BESENObjectValue(FHandler), @a, 1, AResult);
    except
      on e: Exception do
        dolog(llError, 'Script error in line '+IntToStr(FInstance.LineNumber)+': '+ e.Message);
    end;
  end;
end;

procedure TBESENWebsocket.ThreadTick;
begin
  if Assigned(FInstance) then
  begin
    FInstance.GarbageCollector.Collect;
    if (Length(FClients)>0) then
      FIdleTicks:=0
    else begin
      if FIdleTicks>1000 then
        UnloadBESEN
      else
        inc(FIdleTicks);
    end;
  end;
  inherited;
end;

{ TBESENWebsocketClient }

procedure TBESENWebsocketClient.InitializeObject;
begin
  FReply:='';
  FIsRequest:=False;
  inherited; 
end;

procedure TBESENWebsocketClient.FinalizeObject;
begin
  inherited;
end;

procedure TBESENWebsocketClient.send(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
begin
  if CountArguments<=0 then
    Exit;

  if not Assigned(FConnection) then
    Exit;

  if FIsRequest then
  begin
    // for a normal http request, we cache the reply and send it out at once
    FReply:=FReply + TBESEN(Instance).ToStr(Arguments^[0]^)
  end else
  begin
    { BUG: Calling OpenSSL functions from a native script callback function
      can cause weird exceptions (from within OpenSSL). Nobody really knows why.
      As a workaround you can disable BESEN JIT.

      My plan for a better workaround is a separate thread from which the
      openssl-send function is called. }
    FConnection.SendWS(BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[0]^)));
  end;
end;

procedure TBESENWebsocketClient.getHeader(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
begin
  if CountArguments>0 then
    if(Assigned(FConnection)) then
      ResultValue:=BESENStringValue(BESENUTF8ToUTF16(FConnection.Header.header[BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[0]^))]));
end;

procedure TBESENWebsocketClient.redirect(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  url: ansistring;
begin
  if Assigned(FConnection) then
  begin
    if (CountArguments>0) and FIsRequest then
    begin
      url:=BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[0]^));
      FConnection.Reply.header.Add('Location', url);
      FConnection.SendContent('text/html', '<html><body>Content has been moved to <a href="'+url+'">'+url+'</a></body></html>', '302 Found');
      FConnection.Close;
    end;
  end;
end;


procedure TBESENWebsocketClient.disconnect(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
begin
  if Assigned(FConnection) then
  begin
    if FIsRequest then
    begin
      FConnection.SendContent('text/html', BESENUTF16ToUTF8(FReply));
    end;
    FConnection.Close;
  end;
end;

function TBESENWebsocketClient.GetLag: Integer;
begin
  if Assigned(FConnection) then
    result:=FConnection.Lag
  else
    result:=-1;
end;

function TBESENWebsocketClient.GetPingTime: Integer;
begin
  result:=FConnection.WebsocketPingIdleTime;
end;

function TBESENWebsocketClient.GetPongTime: Integer;
begin
  result:=FConnection.WebsocketMaxPongTime;
end;

function TBESENWebsocketClient.GetPostData: string;
begin
  result:='';
end;

procedure TBESENWebsocketClient.SetPingTime(AValue: Integer);
begin
  if AValue>1 then
    FConnection.WebsocketPingIdleTime:=AValue
  else
    FConnection.WebsocketPingIdleTime:=1
end;

procedure TBESENWebsocketClient.SetPongTime(AValue: Integer);
begin
  if AValue>1 then
    FConnection.WebsocketMaxPongTime:=AValue
  else
    FConnection.WebsocketMaxPongTime:=1
end;

function TBESENWebsocketClient.GetHostname: string;
begin
  if Assigned(FConnection) then
    result:=FConnection.GetRemoteIP
  else
    result:='';
end;

end.

