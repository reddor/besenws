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
    FBroken: Boolean;
    FClient: THTTPConnection;
    FFastCGI: TAbstractFastCGIBridge;
    FEnv: ansistring;
    FId: word;
    FBacklog: ansistring;
    FHeaderSent: Boolean;
    procedure EnvCallback(const Name, Value: ansistring);
  protected
    procedure SendData(const Data: ansistring);
    procedure ClientDisconnect(Sender: TEPollSocket);
    procedure InputData(Sender: THTTPConnection; const Data: ansistring; finished: Boolean);
    procedure FCGIEvent(Header: PFCGI_Header; Data: ansistring);
  public
    constructor Create(AParent: TEpollWorkerThread; AClient: THTTPConnection; Host, Port: ansistring);
    destructor Destroy; override;
    property Broken: Boolean read FBroken;
  end;

implementation

uses
  Math,
  logging;

{ TWebserverFastCGIInstance }

procedure TWebserverFastCGIInstance.EnvCallback(const Name, Value: ansistring);

  function EncodeLength(Length: Integer): ansistring;
  begin
    if Length>127 then
    begin
      result:=Chr(128 + ((Length shr 24) and 127)) + Chr(Length shr 16) + Chr(Length shr 8) + Chr(Length);
    end else
      result:=Chr(Length);
  end;

begin
  if Value<>'' then
  FEnv:=FEnv + EncodeLength(Length(Name))+EncodeLength(Length(Value))+Name+Value;
end;

procedure TWebserverFastCGIInstance.SendData(const Data: ansistring);
var
  status, s2, s3: ansistring;
  i, j, k: Integer;
begin
  if not FHeaderSent then
  begin
    FBacklog:=FBacklog + Data;
    if Pos(#13#10#13#10, FBacklog)>0 then
    begin
      // parse header-entries passed by script
      i:=1; // end position of line
      j:=1; // start position of line
      k:=0; // position of ":"
      while i+1<=Length(FBacklog) do
      begin
        if (FBacklog[i]=#13)and(FBacklog[i+1]=#10) then
        begin
          if k<>0 then
          begin
            s2:=Copy(FBacklog, j, k-j);
            s3:=Copy(FBacklog, k+1, i-(k+1));
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
        if (FBacklog[i]=':')and(k=0) then
          k:=i;

        Inc(i);
      end;
      Delete(FBacklog, 1, i+1);
      FHeaderSent:=True;
      FClient.Reply.header.Add('Transfer-Encoding', 'chunked');
      FClient.SendRaw(FClient.reply.build(status));
      if FClient.Header.action = 'HEAD' then
        FFastCGI.OnEvent:=nil;

      if Length(FBacklog)>0 then
      begin
        FClient.SendRaw(IntToHex(Length(FBacklog), 1)+#13#10 + FBacklog + #13#10);
        FBacklog:='';
      end;
    end;
    Exit;
  end;
  FClient.SendRaw(IntToHex(Length(Data), 1)+#13#10 + Data + #13#10);
end;

procedure TWebserverFastCGIInstance.ClientDisconnect(Sender: TEPollSocket);
begin
  Free;
end;

procedure TWebserverFastCGIInstance.InputData(Sender: THTTPConnection;
  const Data: ansistring; finished: Boolean);
var
  i, j: Integer;
begin
  if Length(Data)>0 then
  begin
    if Length(Data)>65535 then
    begin
      i:=0;
      while Length(Data)-i>0 do
      begin
        j:=Min(65535, Length(Data)-i);
        FFastCGI.SendRequest(FCGI_STDIN, FId, @Data[1+i], j);
        Inc(i, j);
      end;
    end else
    FFastCGI.SendRequest(FCGI_STDIN, FId, @Data[1], Length(Data));
  end;
  if finished then
    FFastCGI.SendRequest(FCGI_STDIN, FId, nil, 0);
end;

procedure TWebserverFastCGIInstance.FCGIEvent(Header: PFCGI_Header;
  Data: ansistring);
begin
  case Header^.reqtype of
    FCGI_STDOUT: SendData(Data);
    FCGI_STDERR: dolog(llError,'FCGI-error: '+Data);
    FCGI_END_REQUEST:
      begin
        if FFastCGI.Broken then
        begin
          FClient.OnPostData:=nil;
          FClient.OnDisconnect:=nil;
          if not FHeaderSent then
            FClient.SendStatusCode(502)
          else
            FClient.Close;
        end else
          SendData('');
        Free;
      end;
  end;
end;

constructor TWebserverFastCGIInstance.Create(AParent: TEpollWorkerThread;
  AClient: THTTPConnection; Host, Port: ansistring);
begin
  FClient:=AClient;
  FClient.OnDisconnect:=ClientDisconnect;
  FClient.OnPostData:=InputData;
  FEnv:='';
  FClient.GetCGIEnvVars(EnvCallback);
  FFastCGI:=TFastCGIBridgeSocket.Create(AParent, Host, Port);
  FFastCGI.OnEvent:=FCGIEvent;

  FBroken:=FFastCGI.Broken;
  if FBroken then
  begin
    FClient.OnDisconnect:=nil;
    FClient.OnPostData:=nil;
    FClient.SendStatusCode(502);
  end else
  begin
    FId:=FFastCGI.BeginRequest;
    FFastCGI.SetParameters(FId, FEnv);
    FFastCGI.SetParameters(FId, '');
  end;
end;

destructor TWebserverFastCGIInstance.Destroy;
begin
  FClient.OnDisconnect:=nil;
  FClient.OnPostData:=nil;
  FFastCGI.DelayedFree;
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
    FProc.DelayedFree;
    FProc:=nil;
  end;
  if Assigned(FClient) then
  begin
    FClient.OnPostData:=nil;
    FClient.OnDisconnect:=nil;
  end;
  inherited Destroy;
end;

end.

