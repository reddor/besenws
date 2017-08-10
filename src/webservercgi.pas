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
  webserverhosts;

type
  TWebserverCGIHandler = class;

  { TWebserverCGIInstance }
  TWebserverCGIInstance = class
  private
    FClient: THTTPConnection;
    FProc: TExternalProc;
    procedure ClientDisconnect(Sender: TEPollSocket);
  protected
    procedure SendData(const Data: ansistring);
  public
    constructor Create(AParent: TWebserverCGIHandler; AClient: THTTPConnection; Proc: ansistring);
  end;

  { TWebserverCGIHandler }

  TWebserverCGIHandler = class(TEpollWorkerThread)
  private
    FSite: TWebserverSite;
    FProcs: TFPObjectHashTable;
    FHandler: ansistring;
  protected
    procedure ThreadTick; override;
    procedure AddConnection(Client: TEPollSocket);
  public
    constructor Create(aParent: TWebserver; ASite: TWebserverSite; Handler: ansistring);
  end;


implementation

{ TWebserverCGIInstance }

procedure TWebserverCGIInstance.ClientDisconnect(Sender: TEPollSocket);
begin

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
end;

constructor TWebserverCGIInstance.Create(AParent: TWebserverCGIHandler;
  AClient: THTTPConnection; Proc: ansistring);
begin
  FClient:=AClient;
  FClient.OnDisconnect:=ClientDisconnect;
  FProc:=TExternalProc.Create(AParent, Proc, '', '');
  FProc.OnData:=SendData;
end;

{ TWebserverCGIHandler }

procedure TWebserverCGIHandler.ThreadTick;
begin
  inherited ThreadTick;
end;

procedure TWebserverCGIHandler.AddConnection(Client: TEPollSocket);
begin
  TWebserverCGIInstance.Create(Self, THTTPConnection(Client), FHandler);
end;

constructor TWebserverCGIHandler.Create(aParent: TWebserver;
  ASite: TWebserverSite; Handler: ansistring);
begin
  FSite:=ASite;
  OnConnection:=AddConnection;
  FHandler:=Handler;
  inherited Create(aParent);
end;

end.

