unit webservercgi;

{$mode delphi}

interface

uses
  Classes,
  SysUtils,
  contnrs,
  epollsockets,
  webserver,
  externalproc,
  fastcgi,
  fcgibridge,
  webserverhosts;

type
  { TWebserverCGIInstance }
  TWebserverCGIInstance = class
  private
    FClient: THTTPConnection;
    FProc: TExternalProc;
    FEnv: ansistring;
    procedure EnvCallback(const Name, Value: ansistring);
    procedure ClientDisconnect(Sender: TEPollSocket);
  protected
    procedure InputData(Sender: THTTPConnection; const Data: ansistring; finished: Boolean);
    procedure SendData(const Data: ansistring);
  public
    constructor Create(AParent: TEpollWorkerThread; AClient: THTTPConnection; Executable, Parameters: ansistring);
    destructor Destroy; override;
  end;

  { TWebserverFastCGIInstance }

  TWebserverFastCGIInstance = class
  private
    FClient: THTTPConnection;
    FFastCGI: TAbstractFastCGIBridge;
    FEnv: ansistring;
    procedure EnvCallback(const Name, Value: ansistring);
  protected
    procedure ClientDisconnect(Sender: TEPollSocket);
    procedure InputData(Sender: THTTPConnection; const Data: ansistring; finished: Boolean);
    procedure FCGIEvent(Header: PFCGI_Header; Data: Pointer; Length: Integer);
  public
    constructor Create(AParent: TEpollWorkerThread; AClient: THTTPConnection; Host, Port: ansistring);
    destructor Destroy; override;
  end;

implementation

{ TWebserverFastCGIInstance }

procedure TWebserverFastCGIInstance.EnvCallback(const Name, Value: ansistring);
begin
  if Value<>'' then
  FEnv:=FEnv + Chr(Length(Name))+Chr(Length(Value))+Name+Value;
end;

procedure TWebserverFastCGIInstance.ClientDisconnect(Sender: TEPollSocket);
begin
  Writeln('Disconnect');
end;

procedure TWebserverFastCGIInstance.InputData(Sender: THTTPConnection;
  const Data: ansistring; finished: Boolean);
begin
  Writeln('input');
end;

procedure TWebserverFastCGIInstance.FCGIEvent(Header: PFCGI_Header;
  Data: Pointer; Length: Integer);
begin
  Writeln('Data ', length);
end;

constructor TWebserverFastCGIInstance.Create(AParent: TEpollWorkerThread;
  AClient: THTTPConnection; Host, Port: ansistring);
var
  id: word;
begin
  FClient:=AClient;
  FClient.OnDisconnect:=ClientDisconnect;
  FClient.OnPostData:=InputData;
  FEnv:='';
  FClient.GetCGIEnvVars(EnvCallback);
  FFastCGI:=TFastCGIBridgeSocket.Create(AParent, Host, Port);
  FFastCGI.OnEvent:=FCGIEvent;

  id:=FFastCGI.BeginRequest;
  FFastCGI.SetParameters(id, FEnv);
  FFastCGI.SetParameters(id, '');
end;

destructor TWebserverFastCGIInstance.Destroy;
begin
  inherited Destroy;
end;

{ TWebserverCGIInstance }

procedure TWebserverCGIInstance.EnvCallback(const Name, Value: ansistring);
begin
  if Value = '' then
    Exit;

  if FEnv = '' then
    FEnv:=Name+'='+Value
  else
    FEnv:=FEnv + #13#10 + Name+'='+Value;
end;

procedure TWebserverCGIInstance.ClientDisconnect(Sender: TEPollSocket);
begin
  Free;
end;

procedure TWebserverCGIInstance.InputData(Sender: THTTPConnection;
  const Data: ansistring; finished: Boolean);
begin
  if Data <> '' then
    FProc.Write(@Data[1], Length(Data));
end;

procedure TWebserverCGIInstance.SendData(const Data: ansistring);
var
  i, j, k: Integer;
  s, s2, s3, status: ansistring;
begin
  s:=Data;
  status:='200 OK';


  // parse header-entries passed by script
  i:=1; // end position of line
  j:=1; // start position of line
  k:=0; // position of ":"
  while i+1<=Length(s) do
  begin
    if (s[i]=#13)and(s[i+1]=#10) then
    begin
      if k<>0 then
      begin
        s2:=Copy(s, j, k-j);
        s3:=Copy(s, k+1, i-(k+1));
        if s2='Status' then
          status:=s3
        else
          FClient.reply.header.Add(s2, s3);
      end else
      if i=j then
        Break
      else
      begin
        // invalid?
      end;

      k:=0;
      Inc(i);
      j:=i+1;
    end else
    if (s[i]=':')and(k=0) then
      k:=i;

    Inc(i);
  end;
  Delete(s, 1, i+1);

  (*
  while pos(#13#10, s)>0 do
  begin
    s2:=Copy(s, 1, pos(#13#10, s)-1);
    delete(s, 1, Length(s2)+2);
    if s2='' then
      Break;
    s3:=Copy(s2, Pos(': ', s2)+2, Length(s2));
    Setlength(s2, Length(s2)-(Length(s3)+2));
    if s2='Status' then
      status:=s3
    else
      freply.header.Add(s2, s3);
  end; *)
  FClient.Reply.header.Add('Content-Length', IntToStr(Length(s)));
  if FClient.Header.action = 'HEAD' then
    FClient.SendRaw(FClient.reply.build(status))
  else
    FClient.SendRaw(FClient.reply.build(status) + s);
  if not FClient.Keepalive then
    FClient.Close;
  Free;
end;

constructor TWebserverCGIInstance.Create(AParent: TEpollWorkerThread;
  AClient: THTTPConnection; Executable, Parameters: ansistring);
begin
  FClient:=AClient;
  FClient.OnDisconnect:=ClientDisconnect;
  FClient.OnPostData:=InputData;
  FEnv:='';
  FClient.GetCGIEnvVars(EnvCallback);
  FProc:=TExternalProc.Create(AParent, Executable, Parameters, FEnv);
  FProc.OnData:=SendData;
end;

destructor TWebserverCGIInstance.Destroy;
begin
  if Assigned(FProc) then
  begin
    FProc.OnData:=nil;
    FreeAndNil(FProc);
  end;
  if Assigned(FClient) then
  begin
    FClient.OnPostData:=nil;
    FClient.OnDisconnect:=nil;
  end;
  inherited Destroy;
end;

end.

