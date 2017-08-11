unit webserver;
{
 the webserver core

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
  Classes,
  SysUtils,
  SyncObjs,
  synsock,
  blcksock,
  epollsockets,
  baseunix,
  unix,
  linux,
  sockets,
  httphelper,
  DateUtils,
  mimehelper,
  contnrs,
  MD5,
  filecache,
  webserverhosts,
  sslclass,
  logging;

const
  { maximum number of cached THTTPConnection classes }
  ConnectionCacheSize = 2048;

type
  TWebsocketVersion = (wvNone, wvUnknown, wvHixie76, wvHybi07, wvHybi10, wvRFC);
  TWebsocketMessageType = (wsConnect, wsData, wsDisconnect, wsError);

  TWebsocketFrame = record
    fin, RSV1, RSV2, RSV3: Boolean;
    opcode: Byte;
    masked: Boolean;
    Length: Int64;
    Mask: array[0..3] of Byte;
  end;

  TWebserver = class;
  THTTPConnection = class;
  THTTPConnectionDataReceived = procedure(Sender: THTTPConnection; const Data: ansistring) of object;
  THTTPConnectionPostDataReceived = procedure(Sender: THTTPConnection; const Data: ansistring; finished: Boolean) of object;
  TCGIEnvCallback = procedure(const Name, Value: ansistring) of object;

  { THTTPConnection }
  THTTPConnection = class(TEPollSocket)
  private
    FInBuffer: ansistring;
    FIdent: ansistring;
    FPathUrl: ansistring;
    FMaxPongTime: Integer;
    FOnPostData: THTTPConnectionPostDataReceived;
    FOnWebsocketData: THTTPConnectionDataReceived;
    FPingIdleTime: Integer;
    FHeader: THTTPRequest;
    FReply: THTTPReply;
    fkeepalive: Boolean;
    FTag: Pointer;
    FVersion: TWebsocketVersion;
    FIdletime: Integer;
    hassegmented: Boolean;
    target, FWSData: ansistring;
    FLag: Integer;
    FServer: TWebserver;
    FHost: TWebserverSite;
    FContentLength: Integer;
    FGotHeader: Boolean;
    FLastPing: longint;
    FPostData: ansistring;
    procedure CheckMessageBody;
    function GotCompleteRequest: Boolean;
    function IsExternalScript: Boolean;
    procedure ProcessHixie76;
    function ReadRFCWebsocketFrame(out header: TWebsocketFrame; out HeaderSize: Integer): Boolean;
    procedure ProcessRFC;
    procedure WebscriptPostHandler(Sender: THTTPConnection; const Data: ansistring; finished: Boolean);
  protected
    procedure ProcessData(const Buffer: Pointer; BufferLength: Integer); override;
    procedure ProcessRequest;
    procedure ProcessWebsocket;
    procedure SendReply;
    function ExecuteScript(const Target: ansistring; const StatusCode: ansistring = ''): Boolean;
  public
    constructor Create(Server: TWebserver; Socket: TSocket);
    destructor Destroy; override;
    procedure Cleanup; override;
    procedure Dispose; override;
    function CanWebsocket: Boolean;
    procedure UpgradeToWebsocket;
    function CheckTimeout: Boolean; override;
    procedure GetCGIEnvVars(Callback: TCGIEnvCallback);
    procedure SendStatusCode(const Code: Word);
    procedure SendWS(data: ansistring; Flush: Boolean = True);
    procedure SendContent(mimetype, data: ansistring; result: ansistring = '200 OK');
    property wsVersion: TWebsocketVersion read FVersion write FVersion;
    property OnWebsocketData: THTTPConnectionDataReceived read FOnWebsocketData write FOnWebsocketData;
    property OnPostData: THTTPConnectionPostDataReceived read FOnPostData write FOnPostData;
    property Header: THTTPRequest read FHeader;
    property Lag: Integer read FLag write FLag;
    property WebsocketPingIdleTime: Integer read FPingIdleTime write FPingIdleTime;
    property WebsocketMaxPongTime: Integer read FMaxPongTime write FMaxPongTime;
    property Reply: THTTPReply read FReply;
    property KeepAlive: Boolean read fkeepalive;
  end;

  { TWebserverListener }

  TWebserverListener = class(TThread)
  private
    FParent: TWebserver;
    FIP: ansistring;
    FPort: ansistring;
    FSSLContext: TAbstractSSLContext;
    FSSL: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(Parent: TWebserver; IP, Port: ansistring);
    destructor Destroy; override;
    procedure EnableSSL(PrivateKeyFile, CertificateFile, CertPassword: ansistring);
    property IP: ansistring read FIP;
    property Port: ansistring read FPort;
    property Parent: TWebserver read FParent;
    property SSLContext: TAbstractSSLContext read FSSLContext;
    property SSL: Boolean read FSSL;
  end;

  { TWebserverWorkerThread }
  TWebserverWorkerThread = class(TEpollWorkerThread)
  protected
    procedure Initialize; override;
  end;

  { TWebserver }
  TWebserver = class
  private
    FCS: TCriticalSection;
    FTestMode: Boolean;
    FWorkerCount: Integer;
    FWorker: array of TWebserverWorkerThread;
    FSiteManager: TWebserverSiteManager;
    FCachedConnectionCount: Integer;
    FCachedConnections: array[0..ConnectionCacheSize] of THTTPConnection;
    FListener: array of TWebserverListener;
    fcurrthread: Integer;
    FTotalRequests: Int64;
  protected
    procedure AddWorkerThread(AThread: TWebserverWorkerThread);
  public
    constructor Create(const BasePath: ansistring; IsTestMode: Boolean = False);
    destructor Destroy; override;
    function SetThreadCount(Count: Integer): Boolean;
    function AddListener(IP, Port: ansistring): TWebserverListener;
    function RemoveListener(Listener: TWebserverListener): Boolean;
    procedure Accept(Sock: TSocket; IsSSL: Boolean; SSLContext: TAbstractSSLContext);
    procedure FreeConnection(Connection: THTTPConnection);
    property SiteManager: TWebserverSiteManager read FSiteManager;
    property TestMode: Boolean read FTestMode;
  end;

implementation

uses
  IniFiles,
  buildinfo,
{$ifdef OPENSSL_SUPPORT}
  opensslclass,
{$ENDIF}
  sha1,
  BESENStringUtils,
  besenwebsocket,
  besenwebscript,
  webservercgi,
  base64;

function ProcessHandshakeString(const Input: ansistring): ansistring;
var
  SHA1: TSHA1Context;
  hash: ansistring;

  procedure ShaUpdate(s: ansistring);
  begin
    SHA1Update(SHA1, s[1], length(s));
  end;

type
  PSHA1Digest = ^TSHA1Digest;

begin
  SHA1Init(SHA1);
  Setlength(hash, 20);

  ShaUpdate(Input+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11');

  SHA1Final(SHA1, PSHA1Digest(@hash[1])^);
  result:=EncodeStringBase64(hash);
end;

function ProcessHandshakeStringV0(const Input: ansistring): ansistring;
// concatenates numbers found in input and divides the resulting number by the number of spaces
// returns a 4 byte ansistring
var
  i,j,k: cardinal;
  s: ansistring;
begin
  result := '';
  j := 0;
  s := '';

  for i:=1 to Length(Input) do
  if (Input[i]>#47)and(Input[i]<#58) then
    s := s + (Input[i])
  else
  if Input[i]=#32 then
    inc(j);

  // IntToStr() doesnt work with numbers > 2^31
  // todo: check length(s)

  k := 0;
  for i:=1 to length(s) do
  k := k*10 + cardinal(ord(s[i])-48);

  // todo: check if (k mod j) = 0
  if j>0 then
    j := k div j
  else
    j := k; // wtf

  for i:=0 to 3 do
  result := result + AnsiChar(PByteArray(@j)^[3-i]);
end;

function MD5ofStr(str: ansistring): ansistring;
type
  TDigestString = array[0..15] of Char;
var
  tempstr: TDigestString;
begin
  tempstr:=TDigestString(MDString(str, MD_VERSION_5));
  result:=tempstr;
end;

function CreateHeader(opcode: Byte; Length:Int64): ansistring;
begin
  if Length>125 then
    SetLength(Result, 4)
  else
    setlength(Result, 2);

  result[1] := AnsiChar(128 + (opcode and 15));
  if Length<126 then
  begin
    result[2] := AnsiChar(Length);
  end else
  if Length < 65536 then
  begin
    result[2] := #126;
    result[3] := AnsiChar(Length div $100);
    result[4] := AnsiChar(Length mod $100);
  end else
  begin
    Setlength(result, 10);
    result[2] := #127;
    PInt64(@result[3])^:=Length;
  end;
end;

{ TWebserverWorkerThread }

procedure TWebserverWorkerThread.Initialize;
begin
  inherited Initialize;
end;

{ TWebserverListener }

procedure TWebserverListener.Execute;
var
  ClientSock: TSocket;
  FSock: TTCPBlockSocket;
  x: Integer;
begin
  FSock:=TTCPBlockSocket.Create;
  with FSock do
  begin
    FSock.EnableReuse(True);
    CreateSocket;
    FSock.EnableReuse(True);
    SetLinger(true, 1000);
    bind(FIP, FPort);
    listen;
    x:=0;
    repeat
      try
      if canread(500) then
      begin
        ClientSock:=accept;
        if (LastError = 0)and(ClientSock>=0) then
        begin
          x := fpfcntl(ClientSock, F_GETFL, 0);
          if x<0 then
          begin
            dolog(llError, FIP+':'+FPort+': Could not F_GETFL for '+IntToStr(ClientSock));
            continue;
          end else begin
            x := fpfcntl(ClientSock, F_SetFl, x or O_NONBLOCK);
            if x<0 then 
            begin
              dolog(llError, FIP+':'+FPort+': Could not set NONBLOCK!');
              continue;
            end;
          end;
          FParent.Accept(ClientSock, FSSL, FSSLContext);
        end else
          dolog(llWarning, FIP+':'+FPort+': Could not accept incoming connection');
      end;
      except
        on e: Exception do dolog(llError, e.Message);
      end;
    until Terminated;
    FSock.CloseSocket;
    dolog(llNotice, 'Stopped listening to '+FIP+':'+FPort);
  end;
  FSock.Free;
end;

constructor TWebserverListener.Create(Parent: TWebserver; IP, Port: ansistring);
begin
  FIP:=IP;
  FParent:=Parent;
  FPort:=Port;
  FSSL:=False;
  {$IFDEF OPENSSL_SUPPORT}
  FSSLContext:=TOpenSSLContext.Create;
  {$ENDIF}
  inherited Create(False);
end;

destructor TWebserverListener.Destroy; 
begin
  inherited Destroy;
  {$IFDEF OPENSSL_SUPPORT}
  FSSLContext.Free;
  {$ENDIF}
end;

procedure TWebserverListener.EnableSSL(PrivateKeyFile, CertificateFile, CertPassword: ansistring);
begin
  if (not Assigned(FSSLContext)) or (FSSL) then
    Exit;

  FSSL:=FSSLContext.Enable(PrivateKeyFile, CertificateFile, CertPassword);
end;

{ THTTPConnection }

procedure THTTPConnection.ProcessRequest;
var
  p: TEpollWorkerThread;
  newtarget: string;
begin
  try
    if FGotHeader then
    begin
      FGotHeader:=False;
      // FContentLength:=-1;

      FReply.Clear(FHeader.version);

      Freply.header.Add('Server', FullServerName);

      Freply.header.Add('Date', DateTimeToHTTPTime(Now));
      fkeepalive := Pos('KEEP-ALIVE', Uppercase(Fheader.header['Connection']))>0;
      if fkeepalive then
        Freply.header.Add('Connection', 'keep-alive');

      if (FHeader.version <> 'HTTP/1.0')and(FHeader.version <> 'HTTP/1.1') then
      begin
        // unknown version
        fkeepalive:=False;
        SendStatusCode(505);
        Exit;
      end;

      if (FHeader.version = 'HTTP/1.1') and (FHeader.header['Host']='') then
      begin
        // http/1.1 without Host is not allowed
        fkeepalive:=False;
        SendStatusCode(400);
        Exit;
      end;

      FHost:=FServer.SiteManager.GetSite(FHeader.header['Host']);

      if not Assigned(FHost) then
      begin
        SendStatusCode(500);
        Exit;
      end;

      FHost.ApplyResponseHeader(FReply);

      {
      if (FHeader.action <> 'GET')and(FHeader.action <> 'HEAD')and(FHeader.action <> 'POST') then
      begin
        // method not allowed, this server has no POST implementation
        fkeepalive:=False;
        SendStatusCode(405);
        Exit;
      end; }
      target := StringReplace(FHeader.url, '/./', '/', [rfReplaceAll]);
      target := StringReplace(target, '//', '/', [rfReplaceAll]);

      if (length(Target)>0)and ( (Target[1] <> '/')or(pos('/../', target)>0)) then
      begin
        fkeepalive:=False;
        SendStatusCode(400);
        Exit;
      end;

      if FHost.IsForward(target, newtarget) then
      begin
        FReply.header.Add('Location', newtarget);
        SendStatusCode(301);
        Exit;
      end;

      p:=TEpollWorkerThread(FHost.GetCustomHandler(FHeader.url));
      if Assigned(p) then
      begin
        Relocate(p);
      end else
      if CanWebsocket then
      begin
        // ProcessWebsocket
        SendStatusCode(405);
      end
      else
        SendReply;
    end else
    begin
      fkeepalive:=false;
      SendStatusCode(400);
      Exit;
    end;
  except
    on E: Exception do
    begin
      dolog(llError, GetPeerName+': Exception in ProcessRequest: '+ E.Message);
      Close;
    end;
  end;
end;

procedure THTTPConnection.ProcessWebsocket;
var
  p: TEpollWorkerThread;
begin
  p:=TEpollWorkerThread(FHost.GetCustomHandler(FHeader.url));

  if Assigned(p) then
  begin
    UpgradeToWebsocket;
    Relocate(p);
  end else
  begin
    dolog(llDebug, 'Trying websocket but none is avail '+FHeader.url);
    SendStatusCode(404);
  end;
end;

procedure THTTPConnection.UpgradeToWebsocket;
var
  s,s2: ansistring;

begin
  fkeepalive:=False;

  s := FHeader.header['Sec-WebSocket-Version'];

  Freply.header.add('Upgrade', 'WebSocket');
  Freply.header.add('Connection', 'Upgrade');

  s2 := FHeader.header['Sec-WebSocket-Protocol'];
  if pos(',', s2)>0 then
    Freply.header.Add('Sec-WebSocket-Protocol', Copy(s2, 1, pos(',', s2)-1))
  else if length(s2)>0 then
    Freply.header.Add('Sec-WebSocket-Protocol', s2);

  wsVersion := wvUnknown;
  if s = '' then
  begin
    // draft-ietf-hybi-thewebsocketprotocol-00 / hixie76 ?
    dolog(llNotice, GetPeerName+': Legacy Websocket Connect (Hixie76)');

    if (FHeader.header.Exists('Sec-WebSocket-Key1')<>-1) and
       (FHeader.header.Exists('Sec-WebSocket-Key2')<>-1) then
    begin
      wsVersion := wvHixie76; // yes.

      if FHeader.header.Exists('Origin')<>-1 then
        FReply.Header.Add('Sec-WebSocket-Origin', FHeader.header['Origin']);

      if FHeader.header.Exists('Host')<>-1 then
        if FHeader.parameters<>'' then
          FReply.Header.Add('Sec-WebSocket-Location', 'ws://' +FHeader.header['Host']+FHeader.url+'?'+FHeader.parameters)
        else
          FReply.Header.Add('Sec-WebSocket-Location', 'ws://' +FHeader.header['Host']+FHeader.url);

      if FHeader.Header.Exists('Sec-WebSocket-Protocol')<>-1 then
        FReply.Header.Add('Sec-WebSocket-Protocol', FHeader.header['Sec-WebSocket-Protocol']);

      s := MD5ofStr(ProcessHandshakeStringV0(FHeader.header['Sec-WebSocket-Key1']) +
                      ProcessHandshakeStringV0(FHeader.header['Sec-WebSocket-Key2']) + Copy(FInBuffer, 1, 8));

      s := FReply.Build('101 Switching protocols') + s;
      SendRaw(s);
      Delete(FInBuffer, 1, 8);
    end else
    begin
      dolog(llNotice, GetPeerName+': Unknown websocket handshake');
      Close;
    end;
  end else
  if s = '7' then
  begin
    // draft-ietf-hybi-thewebsocketprotocol-07
    dolog(llNotice, GetPeerName+': Legacy Websocket Connect (Hybi07)');
    wsVersion := wvHybi07;
  end else
  if s = '8' then
  begin
    // draft-ietf-hybi-thewebsocketprotocol-10
    dolog(llNotice, GetPeerName+': Legacy Websocket Connect (Hybi10)');
    wsVersion := wvHybi10;
  end else
  if s = '13' then
  begin
    // rfc6455
    wsVersion := wvRFC;
  end else
  begin
    dolog(llNotice, GetPeerName+': Unknown Websocket Version '+s+', dropping.');
    Close;
  end;

  { there are only minor differences between version 7, 8 & 13, it's basically
    the same handshake }
  if not (wsVersion in [wvUnknown, wvHixie76]) then
  begin
    Freply.header.Add('Sec-WebSocket-Accept', ProcessHandshakeString(FHeader.header['Sec-WebSocket-Key']));
    if FHeader.header.Exists('Sec-WebSocket-Protocol')<>-1 then
       Freply.header.Add('Sec-WebSocket-Protocol', FHeader.header['Sec-WebSocket-Protocol']);

    SendRaw(FReply.Build('101 Switching protocols'));
    dolog(llDebug, GetPeerName+': 101 Switching protocols '+FHeader.url);
  end;
end;

procedure THTTPConnection.SendReply;
var
  s, params: ansistring;
  Len: Integer;
  Data: Pointer;
  LastModified: TDateTime;
  ARangeStart, ARangeLen: Cardinal;
  FFile: PFileCacheItem;
begin
  FPathUrl:='';

  if FHost.IsScriptDir(target, s, params) then
  begin
    target:=s;
    if FHeader.parameters<>'' then
      FHeader.parameters:=params + '?' + FHeader.parameters
    else
      FHeader.parameters:=params;
  end;

  FFile:=FHost.Files.Find(target);

  if Assigned(FFile) and (FFile^.Filelength = -1) then
  begin
    // directory
    FHost.Files.Release(FFile);
    FReply.header.Add('Location', target+'/');
    SendStatusCode(301);
    Exit;
  end;

  if (not Assigned(FFile))and(target[Length(Target)]='/') then
  begin
    FFile:=FHost.GetIndexPage(target);
  end;

  if not Assigned(FFile) then
  begin
    // this is some trickery to find the right script for requests like GET /script.php/param
    FFile:=FHost.Files.FindPathUrl(target, FPathUrl);

    if Assigned(FFile) then
    begin
      Fhost.Files.Release(FFile);
      if not FHost.IsExternalScript(target, Self) then
        SendStatusCode(404);
      Exit;
    end else
    begin
      SendStatusCode(404);
      Exit;
    end;
  end;

  // IsExternalScript will invoke the script processor by itself
  if FHost.IsExternalScript(target, Self) then
  begin
    FHost.Files.Release(FFile);
    Exit;
  end;

  if Lowercase(ExtractFileExt(target)) = '.jsp' then
  begin
    FHost.Files.Release(FFile);
    if FContentLength>0 then
    begin
      // post size limit, as we keep everything in memory
      if FContentLength > 1024 * 1024 then
      begin
        SendStatusCode(413);
        FKeepAlive:=False;
        Exit;
      end;
      // we got a message body which we have not yet read.. we now have to register
      // a POSTdata handler to read all of it...
      FOnPostData:=WebscriptPostHandler;
      // we might already have received the complete message body, better check
      CheckMessageBody;
      Exit;
    end;
    if not ExecuteScript(Target) then
      SendStatusCode(500);
    Exit;
  end;

  LastModified := FFile.LastModified;
  Freply.header.Add('Last-Modified', DateTimeToHTTPTime(LastModified));

  if FHeader.header.Exists('If-Modified-Since')<>-1 then
  begin
    if HTTPTimeToDateTime(FHeader.header['If-Modified-Since']) = LastModified then
    begin
      Freply.header.Add('Expires', DateTimeToHTTPTime(IncSecond(Now, FFile.CacheLength)));
      FHost.Files.Release(FFile);
      SendRaw(Freply.Build('304 Not Modified'));
      Exit;
    end;
  end;

  if FHeader.action <> 'GET' then
  begin
    if Assigned(FFile) then
      FHost.Files.Release(FFile);
    SendStatusCode(500);
  end;

  s := '';

  if Assigned(FFile) then
  begin
    if (pos('gzip', FHeader.header['Accept-Encoding'])>0)and(Assigned(FFile.Gzipdata)) and
       (FHeader.RangeCount=0) then
    begin
      len:=FFIle.GZiplength;
      Data:=FFile.Gzipdata;
      FReply.Header.Add('Accept-Ranges', 'bytes');
      FReply.Header.Add('Vary', 'Accept-Encoding');
      FReply.Header.Add('Content-Encoding', 'gzip');
    end else
    begin
      len:=FFile.Filelength;
      Data:=FFile.Filedata;
    end;

    ARangeStart := 0;
    ARangeLen := len;

    if FHeader.RangeCount=1 then
    begin
      ARangeStart := FHeader.Range[0].min;
      ARangeLen := FHeader.Range[0].max;
      Freply.Header.Add('Content-range', 'bytes '+IntToStr(ARangeStart)+'-'+IntToStr(ARangeLen)+'/'+IntToStr(FFile.Filelength-1));

      if (ARangeStart>=FFile.Filelength) then
        ARangeStart:=FFile.FileLEngth-1;

      if ARangeStart+ARangeLen>FFile.FileLength then
        ARangeLen:=FFile.FileLength - ARangeStart;
    end;

    Setlength(s, ARangeLen - (ARangeStart));

    Move(PByteArray(Data)[ARangeStart], s[1], Length(s));

    Freply.header.Add('Expires', DateTimeToHTTPTime(IncSecond(Now, FFile.CacheLength)));
    if FHeader.RangeCount=1 then
      SendContent(FFile^.mimetype, s, '206 Partial Content')
    else
      SendContent(FFile^.mimetype, s);

    FHost.Files.Release(FFile);
  end else
  begin
    SendStatusCode(403);
    Exit;
  end;
end;

function THTTPConnection.ExecuteScript(const Target: ansistring;
  const StatusCode: ansistring): Boolean;
var
  FScript: TBESENWebscript;
begin
  result:=False;
  FScript:=TBESENWebscript.Create(FServer.SiteManager, FHost);
  try
    if StatusCode <> '' then
      FScript.ResultCode:=BESENUTF8ToUTF16(StatusCode);
    result:=FScript.Execute(ExtractFileDir(target), ExtractFileName(target), Self);
    if Result then
      SendContent(BESENUTF16ToUTF8(FScript.MimeType), BESENUTF16ToUTF8(FScript.Result), BESENUTF16ToUTF8(FScript.ResultCode));
  finally
    FScript.Destroy;
  end;
end;

procedure THTTPConnection.SendStatusCode(const Code: Word);
var
  s, Title, Description, Host: ansistring;
  gzip: Boolean;
begin
  GetHTTPStatusCode(Code, Title, Description);
  Title:=IntToStr(Code)+' '+Title;
  if Assigned(FHost) then
    s:=FHost.GetCustomStatusPage(Code)
  else
    s:='';

  if s<>'' then
  begin
    gzip:=False;
    if LowerCase(ExtractFileExt(s))='.jsp' then
    begin
      if ExecuteScript(s, Title) then
        Exit
      else
      Description:=Description+
        'Also a 404 error occured while generating the error page.';
    end else
    if FHost.Files.GetFile(s, s, gzip)>0 then
    begin
      SendContent('text/html', s, Title);
      Exit;
    end else
    begin
      Description:=Description+
        'Also a 404 error occured while generating the error page.';
    end;
  end;

  Host:=FHeader.header['Host'];
  if Host = '' then
    Host:='besenws';

  if Description = '' then
    Description:='No information available';

  SendContent('text/html', '<!DOCTYPE html>'#13#10+'<html>'#13#10+' <head>'#13#10+'  <title>'+Title+'</title>'#13#10+' </head>'#13#10+' <body>'#13#10+
              '  <h1>'+Title+'</h1>'#13#10+'  <p>'+Description+'</p>'+#13#10+
              '  <hr>'#13#10+'  <i>'+Host +' Server</i>'+
              ' </body>'#13#10+'</html>', Title);

end;


constructor THTTPConnection.Create(Server: TWebserver; Socket: TSocket);
begin
  inherited Create(Socket);
  FHeader:=THTTPRequest.Create;
  FReply:=THTTPReply.Create;
  FContentLength:=-1;
  FGotHeader:=False;

  FPingIdleTime:=15; // seconds until ping is sent
  FMaxPongTime:=15; // seconds until connection is closed with no pong reply
  FInBuffer:='';
  FServer:=Server;
end;

destructor THTTPConnection.Destroy;
begin
  Cleanup;
  FHeader.Free;
  FReply.Free;
  inherited Destroy;
end;

procedure THTTPConnection.Cleanup;
begin
  inherited;
  fkeepalive:=False;
  FIdletime:=0;
  target:='';
  FWSData:='';
  FIdent:='';
  FContentLength:=-1;
  FPostData:='';
  FPathUrl:='';
  FGotHeader:=False;
  FOnWebsocketData:=nil;
  FOnPostData:=nil;
  FVersion:=wvNone;
  FTag:=nil;
  FWSData:='';
  FInBuffer:='';
end;

procedure THTTPConnection.Dispose;
begin
  if Assigned(FServer) then
    FServer.FreeConnection(Self)
end;

function THTTPConnection.CanWebsocket: Boolean;
begin
  result:=(FHeader.Action = 'GET')and(FHeader.version = 'HTTP/1.1') and
          (((Pos('UPGRADE', UpperCase(FHeader.header['Connection']))>0) and
          (Uppercase(FHeader.header['Upgrade'])='WEBSOCKET')));
end;

function THTTPConnection.CheckTimeout: Boolean;
var s: string;
begin
  case FVersion of
    wvNone, wvUnknown:
    begin
      inc(FIdletime);
      if FIdletime>50 then
        Close;
    end;
    wvHixie76:
    begin
      begin
        inc(FIdletime);
{$IFDEF HIXIE76_PING}
        if FIdletime = FPingIdleTime then
          SendWS('PING '+IntToStr(DateTimeToTimeStamp (Now).time));
        if FIdletime>=FPingIdleTime + FMaxPongTime then
          FWantclose:=True;
{$ELSE}
       if FIdletime>600 then
         Close;
{$ENDIF}
      end;
    end;
    else
    begin
      inc(FIdletime);
      if FIdletime=FPingIdleTime then
      begin
        if FLastPing = 0 then
          FLastPing:=DateTimeToTimeStamp(Now).Time;
        s:=IntToStr(FLastPing);
        SendRaw(CreateHeader(9, length(s))+s);
      end;
    end;
    if FIdleTime>=FPingIdleTime + FMaxPongTime then
      Close;
  end;
  result:=Wantclose;
end;

function THTTPConnection.GotCompleteRequest: Boolean;
var
  i: Integer;
begin
  result:=False;
  if (not FGotHeader) and (FContentLength <= 0) then
  begin
    for i:=Length(FInBuffer) downto 4 do
    if(FInBuffer[i]=#10)and(FInBuffer[i-1]=#13)and(FInBuffer[i-2]=#10)and(FInBuffer[i-3]=#13) then
    begin
      result:=True;
      FGotHeader:=FHeader.readstr(FInBuffer);
      if FGotHeader then
        FContentLength:=StrToIntDef(FHeader.header['Content-Length'], 0);
      Exit;
    end;
  end else
  begin
    if FContentLength = -1 then
      FContentLength:=StrToIntDef(FHeader.header['Content-Length'], 0);
    if FContentLength>0 then
    begin
      CheckMessageBody;
      if FContentLength = 0 then
        result:=GotCompleteRequest;
    end else
      result:=True;
  end;
end;

function THTTPConnection.IsExternalScript: Boolean;
begin
  result:=False;
end;

procedure THTTPConnection.ProcessHixie76;
var
  i: Integer;
  s: ansistring;
begin
  while Length(FInBuffer)>0 do
  begin
    if FInbuffer[1]=#0 then
    begin
      i:=Pos(#255, FInBuffer);
      if i=0 then
        Exit;

      s:=Copy(FInBuffer, 2, i-2);
      Delete(FInBuffer, 1, i);
{$IFDEF HIXIE76_PING}
      if Pos('PONG ', s)=1 then
      begin
        Delete(s, 1, pos(' ', s));
        try
          FLag:=longword(DateTimeToTimeStamp(Now).time - (StrToInt(s)));
        except
        end;
      end else
{$ENDIF}
      if Assigned(FOnWebsocketData) then
        FOnWebsocketData(Self, s);
    end else
    begin
      dolog(llDebug, GetPeerName+': closing, Invalid packet');
      Close;
      Exit;
    end;
  end;
end;

function THTTPConnection.ReadRFCWebsocketFrame(out header: TWebsocketFrame; out
  HeaderSize: Integer): Boolean;
begin
  result:=False;
  HeaderSize:=2;
  header.fin := Ord(FInbuffer[1]) and 128 <> 0;
  header.RSV1 := Ord(FInbuffer[1]) and 64 <> 0;
  header.RSV2 := Ord(FInbuffer[1]) and 32 <> 0;
  header.RSV3 := Ord(FInbuffer[1]) and 16 <> 0;
  header.opcode := Ord(FInbuffer[1]) and 15;
  header.masked := Ord(FInbuffer[2]) and 128 <> 0;
  header.length := Ord(FInbuffer[2]) and 127;

  if header.length = 126 then
  begin
    if Length(FInbuffer)<2+HeaderSize then
      Exit;
    header.length:=Ord(FInbuffer[4])+Ord(FInbuffer[3])*256;
    HeaderSize:=4;
  end else if header.length = 127 then
  begin
    if Length(FInbuffer)<8+HeaderSize then
      Exit;
     header.length:=PInt64(@FInbuffer[3])^;
     HeaderSize:=10;
  end;
  if header.Masked then
  begin
    if Length(FInBuffer)<4+HeaderSize then
      Exit;
    header.Mask[0]:=Ord(FInbuffer[HeaderSize+1]);
    header.Mask[1]:=Ord(FInbuffer[HeaderSize+2]);
    header.Mask[2]:=Ord(FInbuffer[HeaderSize+3]);
    header.Mask[3]:=Ord(FInbuffer[HeaderSize+4]);
    inc(HeaderSize, 4);
  end;

  if header.opcode = 255 then
  begin
    Delete(FInbuffer, 1, HeaderSize);
    Exit;
  end;

  if Length(FInbuffer)<HeaderSize+header.Length then
    Exit;
  result:=True;
end;

procedure THTTPConnection.ProcessRFC;
var
  i, j: Integer;
  s: ansistring;
  header: TWebsocketFrame;
begin
  while Length(FInBuffer)>1 do
  begin
    if not ReadRFCWebsocketFrame(header, j) then
      Exit;

    s:=Copy(FInBuffer, j+1, header.length);
    Delete(FInBuffer, 1, j+header.length);

    if header.Masked then
    begin
      for i:=1 to header.Length do
        s[i]:=AnsiChar(Byte(s[i]) xor header.mask[(i-1) mod 4]);
    end else
    begin
      // only accept masked frames
      Close;
      Exit;
    end;

    case header.opcode of
      254:
      begin
        // 254 error, 8 connection close
        Close;
        Exit;
      end;
      0:
      begin
        // continuation frame
        if not hassegmented then
        begin
          Close;
          Exit;
        end;

        FWSData:=FWSData  + Copy(FInBuffer, j+1, header.Length);

        if header.fin then
        begin
          hassegmented:=false;
          if Assigned(FOnWebsocketData) then
            FOnWebsocketData(Self, FWSDAta);
          fwsdata:='';
          // data received!
        end;
      end;
      1, 2:
      begin
        // 1 = text, 2 = binary
        if not header.fin then
        begin
          if hasSegmented then
            Close;
          FWSData:=s;
          hasSegmented := true;
        end else
        begin
          // data received
          if Assigned(FOnWebsocketData) then
            FOnWebsocketData(Self, s);
        end;
      end;
      8:
      begin
        SendRaw(CreateHeader(header.opcode, Length(s)) + s);
        Close;
      end;
      9: SendRaw(CreateHeader(10, Length(s)) + s);
      10:
      begin
        // pong
        try
          // edge doesn't include ping string?
          if s<>'' then
            FLag:=longword(DateTimeToTimeStamp (Now).time - (StrToInt(s)))
          else if FLastPing <> 0 then
            FLag:=DateTimeToTimeStamp(Now).Time - FLastPing;
          FLastPing:=0;
          //dolog(lldebug, 'got pong, lag '+IntToStr(FLag)+'ms');
        except
          on e: Exception do
          begin
            dolog(llError, GetPeerName+': send invalid pong reply ' + s + ' '+e.Message);
            Close;
          end;
        end;
      end;
    end;
  end;
end;

procedure THTTPConnection.WebscriptPostHandler(Sender: THTTPConnection;
  const Data: ansistring; finished: Boolean);
var
  s: ansistring;
begin
  FPostData:=FPostData + Data;
  if finished then
  begin
    s:=Data;
    if not FHeader.POSTData.readstr(s) then
      dolog(llError, 'Got invalid POST data');
    FPostData:='';
    Sender.OnPostData:=nil;
    if not ExecuteScript(Target) then
      SendStatusCode(500);
  end;
end;

procedure THTTPConnection.GetCGIEnvVars(Callback: TCGIEnvCallback);
var
  i: Integer;
  a, b: ansistring;
begin
  for i:=0 to FHeader.header.Count-1 do
  begin
    FHeader.header.Get(i, a, b);
    a:='HTTP_' + Uppercase(StringReplace(a, '-', '_', [rfReplaceAll]));
    Callback(a, b);
  end;

  Callback('CONTENT_LENGTH', FHeader.header['Content-Length']);
  Callback('CONTENT_TYPE', FHeader.header['Content-Type']);
  Callback('GATEWAY_INTERFACE', 'CGI/1.1');
  //'PATH_INFO'
  //'PATH_TRANSLATED'
  Callback('QUERY_STRING', FHeader.parameters);
  Callback('REMOTE_ADDR', GetRemoteIP);
  Callback('REMOTE_HOST', GetPeerName);
  // 'REMOTE_IDENT'
  Callback('REQUEST_METHOD', FHeader.action);
  Callback('SCRIPT_NAME', target);
  if FPathUrl <> '' then
    Callback('PATH_INFO', FPathUrl);
  a:=FHeader.header['Host'];
  if a<>'' then
  begin
    if Pos(':', a)>0 then
    begin
      b:=Copy(a, Pos(':', a)+1, Length(a));
      Delete(a, Pos(':', a), Length(b)+1);
    end else b:='80';
    Callback('SERVER_NAME', a);
    Callback('SERVER_PORT', b);
  end else
  begin
    Callback('SERVER_NAME', '127.0.0.1');
    Callback('SERVER_PORT', '80');
  end;
  Callback('SERVER_PROTOCOL', FHeader.version);
  Callback('SERVER_SOFTWARE', FullServerName);
  Callback('SERVER_SIGNATURE', FullServerName);
  Callback('DOCUMENT_ROOT', FHost.Files.BaseDir);
  Callback('REQUEST_SCHEME', 'http');
  Callback('SCRIPT_FILENAME', FHost.Files.BaseDir + target);
  Callback('REQUEST_URI', FHeader.url);
  Callback('REDIRECT_STATUS', FHeader.Url);
end;

procedure THTTPConnection.CheckMessageBody;
var
  finished: Boolean;
  s: ansistring;
begin
  if FContentLength = -1 then
    FContentLength:=StrToIntDef(FHeader.header['Content-Length'], 0);
  if FContentLength<=0 then
    Exit;

  if Assigned(FOnPostData) then
  begin
    finished:=Length(FInBuffer)>=FContentLength;
    if Length(FInBuffer)<=FContentLength then
    begin
      s:=FInBuffer;
      Dec(FContentLength, Length(FInBuffer));
      FInBuffer:='';
      FOnPostData(Self, s, finished);
    end else
    begin
      s:=Copy(FInBuffer, 1, FContentLength);
      Delete(FInBuffer, 1, FContentLength);
      FContentLength:=0;
      FOnPostData(Self, s, finished);
    end;
    if finished then
      FOnPostData:=nil;
  end else
  begin
    if Length(FInBuffer)<=FContentLength then
    begin
      Dec(FContentLength, Length(FInBuffer));
      FInBuffer:='';
    end else
    begin
      Delete(FInBuffer, 1, FContentLength);
      FContentLength:=0;
    end;
    if FContentLength = 0 then
      dolog(llWarning, GetPeerName+': Got unexpected message body for '+FHeader.action+' '+FHeader.url);
  end;
end;

procedure THTTPConnection.ProcessData(const Buffer: Pointer;
  BufferLength: Integer);
var
  i: Integer;
begin
  FIdletime:=0;
  i:=Length(FInBuffer);
  Setlength(FInBuffer, i + BufferLength);
  Move(Buffer^, FInBuffer[i+1], BufferLength);

  case FVersion of
    wvNone:
    begin
      if GotCompleteRequest then
      begin
        ProcessRequest;
      end else
      if (not FGotHeader) and (Length(FInBuffer)>128*1024) then
      begin
        // 128kb of data and still no complete request (not counting postdata)
        SendStatusCode(400);
        Close;
      end;
    end;
    wvHixie76: ProcessHixie76();
    wvRFC, wvHybi07, wvHybi10: ProcessRFC();
    else begin
      dolog(llError, 'Unknown state in THTTPConnection.ProcessData');
      Close;
    end;
  end;
end;

procedure THTTPConnection.SendWS(data: ansistring; Flush: Boolean);
begin
  case FVersion of
    wvNone,
    wvUnknown: Exit;
    wvHixie76: SendRaw(#0+data+#255, Flush);
    else
      SendRaw(CreateHeader(1, length(data))+data, Flush);
  end;
end;

procedure THTTPConnection.SendContent(mimetype, data: ansistring;result:ansistring = '200 OK');
begin
  if mimetype<>'' then
    freply.header.add('Content-Type', mimetype);
  if Length(data)>0 then
    freply.header.add('Content-Length', IntToStr(length(data)));

  if FHeader.action = 'HEAD' then
    SendRaw(freply.build(result))
  else
    SendRaw(freply.Build(result) + data);

  if Assigned(FOnPostData) then
  begin
    dolog(llError, GetPeerName+': Internal error - postdata callback still in place when it should not be');
    FOnPostData:=nil;
  end;

  CheckMessageBody; // this is just a courtesy call to remove bogus post-data from our inbuffer

  if not FKeepAlive then
    Close;
end;

{ TWebserver }

procedure TWebserver.AddWorkerThread(AThread: TWebserverWorkerThread);
var
  i: Integer;
begin
  i:=Length(FWorker);
  Setlength(FWorker, i+1);
  FWorker[i]:=AThread;
end;

constructor TWebserver.Create(const BasePath: ansistring; IsTestMode: Boolean);
var
  i: Integer;
begin
  FTestMode:=IsTestMode;
  FCS:=TCriticalSection.Create;

  FSiteManager:=TWebserverSiteManager.Create(BasePath);
  fcurrthread:=0;
  FWorkerCount:=1;

  for i:=0 to FWorkerCount-1 do
    AddWorkerThread(TWebserverWorkerThread.Create(Self));
end;

destructor TWebserver.Destroy;
var i: Integer;
begin
  for i:=0 to Length(FListener)-1 do
    FListener[i].Free;

  Setlength(FListener, 0);

  SetThreadCount(0);

  dolog(llNotice, 'Total requests served: '+IntToStr(FTotalRequests));
  FSiteManager.Destroy;

  for i:=0 to FCachedConnectionCount-1 do
    FCachedConnections[i].Free;

  FCS.Free;
  inherited Destroy;
end;

function TWebserver.SetThreadCount(Count: Integer): Boolean;
var
  i: Integer;
begin
  result:=False;

  if Count<0 then
    Exit;

  if FTestMode then
  begin
    result:=True;
    Exit;
  end;


  if Count < FWorkerCount then
  begin
    dolog(llDebug, 'Decimating threads from '+IntToStr(FWorkerCount)+' to '+IntToStr(Count));
    for i:=Count to FWorkerCount-1 do
      FWorker[i].Terminate;

    for i:=Count to FWorkerCount-1 do
    begin
      FWorker[i].WaitFor;
      Inc(FTotalRequests, FWorker[i].TotalCount);
      FWorker[i].Free;
    end;
    Setlength(FWorker, Count);
    FWorkerCount:=Count;
  end else
  if Count > FWorkerCount then
  begin
    dolog(llDebug, 'Increasing threads from '+IntToStr(FWorkerCount)+' to '+IntToStr(Count));
    Setlength(FWorker, Count);
    for i:=FWorkerCount to Count-1 do
      FWorker[i]:=TWebserverWorkerThread.Create(Self);
    FWorkerCount:=Count;
  end;
end;

function TWebserver.AddListener(IP, Port: ansistring): TWebserverListener;
var
  i: Integer;
begin
  if FTestMode then
  begin
    result:=nil;
    Exit;
  end;

  dolog(llNotice, 'Creating listener for '''+IP+':'+Port+'''');
  result:=TWebserverListener.Create(Self, IP, Port);
  FCS.Enter;
  try
    i:=Length(FListener);
    Setlength(FListener, i+1);
    FListener[i]:=result;
  finally
    FCS.Leave;
  end;
end;

function TWebserver.RemoveListener(Listener: TWebserverListener): Boolean;
var
  i: Integer;
begin
  result:=False;
  if not Assigned(FListener) then
    Exit;

  FCS.Enter;
  try
    for i:=0 to Length(FListener)-1 do
      if FListener[i] = Listener then
      begin
        FListener[i]:=FListener[Length(FListener)-1];
        Setlength(FListener, Length(FListener)-1);
        result:=True;
      end;
  finally
    FCS.Leave;
  end;
  if result then
  begin
    dolog(llNotice, 'Removing listener for '''+Listener.IP+':'+Listener.Port+'''');
    Listener.Free;
  end else
    dolog(llNotice, 'Could not remove listener for '''+Listener.IP+':'+Listener.Port+'''');
end;

const
  SendHelp: ansistring = 'internal server error';

procedure TWebserver.Accept(Sock: TSocket; IsSSL: Boolean; SSLContext: TAbstractSSLContext);
var c: THTTPConnection;
begin
  if FWorkerCount = 0 then
  begin
    Send(Sock, @SendHelp[1], Length(SendHelp), 0);
    CloseSocket(Sock);
    Exit;
  end;

  FCS.Enter;
  try
    fcurrthread:=(fcurrthread+1) mod FWorkerCount;
    if FCachedConnectionCount>0 then
    begin
      dec(FCachedConnectionCount);
      c:=FCachedConnections[FCachedConnectionCount];
      FCachedConnections[FCachedConnectionCount]:=nil;
      c.ReAssign(Sock);
    end else
      c:=nil;
  finally
    FCS.Leave;
  end;
  if not Assigned(c) then
    c:=THTTPConnection.Create(Self, Sock);

  c.WantSSL:=IsSSL;
  c.SSLContext:=SSLContext;

  //c.GetPeerName;
  c.Relocate(FWorker[fcurrthread]);
end;

procedure TWebserver.FreeConnection(Connection: THTTPConnection);
begin
  if FCachedConnectionCount>=ConnectionCacheSize-1 then
  begin
    Connection.Free;
    Exit;
  end;
  Connection.Cleanup;

  FCS.Enter;
  try
    if FCachedConnectionCount<ConnectionCacheSize then
    begin
      FCachedConnections[FCachedConnectionCount]:=Connection;
      Inc(FCachedConnectionCount);
    end else
      Connection.Free;
  finally
    FCS.Leave;
  end;
end;

end.

