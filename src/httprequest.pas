unit httprequest;

{$mode delphi}
{$define gzipsupport}

interface

uses
  Classes,
  SysUtils,
  blcksock,
  httphelper;

type
  THTTPRequestError = (heConnectionFailed, heProtocolError, heSSLError, heForwardLoop, heInternalError);
  THTTPRequestErrorCallback = procedure(ErrorType: THTTPRequestError; const Message: ansistring) of object;
  THTTPRequestResponse = procedure(const ResponseCode, data: ansistring) of object;
  THTTPRequestForward = function(var newUrl: ansistring): Boolean of object;

  { THTTPClient }

  THTTPClient = class
  private
    FOnError: THTTPRequestErrorCallback;
    FOnForward: THTTPRequestForward;
    FOnResponse: THTTPRequestResponse;
    FTimeOut: longword;
    FUserAgent: ansistring;
    FRequest: THTTPRequest;
    FResponse: THTTPReply;
    FSocket: TTCPBlockSocket;
  protected
    function DoHandshake(const Host, Port: ansistring; https: Boolean): Boolean;
    function ReadResponseBody: ansistring;
  public
    constructor Create;
    destructor Destroy; override;
    function Get(Url: ansistring): ansistring;
    property TimeOut: longword read FTimeOut write FTimeOut;
    property UserAgent: ansistring read FUserAgent write FUserAgent;
    property OnError: THTTPRequestErrorCallback read FOnError write FOnError;
    property OnResponse: THTTPRequestResponse read FOnResponse write FOnResponse;
    property OnForward: THTTPRequestForward read FOnForward write FOnForward;
  end;

  { THTTPRequestThread }

  THTTPRequestThread = class(TThread)
  private
    FURL: ansistring;
    FClient: THTTPClient;
    function GetOnError: THTTPRequestErrorCallback;
    function GetOnForward: THTTPRequestForward;
    function GetOnResponse: THTTPRequestResponse;
    function GetTimeout: longword;
    function GetUserAgent: ansistring;
    procedure SetOnError(AValue: THTTPRequestErrorCallback);
    procedure SetOnForward(AValue: THTTPRequestForward);
    procedure SetOnResponse(AValue: THTTPRequestResponse);
    procedure SetTimeout(AValue: longword);
    procedure SetUserAgent(AValue: ansistring);
  protected
    procedure Execute; override;
  public
    constructor Create(Url: ansistring);
    destructor Destroy; override;
    property Timeout: longword read GetTimeout write SetTimeout;
    property UserAgent: ansistring read GetUserAgent write SetUserAgent;
    property OnError: THTTPRequestErrorCallback read GetOnError write SetOnError;
    property OnResponse: THTTPRequestResponse read GetOnResponse write SetOnResponse;
    property OnForward: THTTPRequestForward read GetOnForward write SetOnForward;
  end;

function SimpleHTTPGet(URL: ansistring): ansistring;

implementation

uses
{$ifdef gzipsupport}
  zbase,
  zinflate,
{$endif}
  synsock;


{$ifdef gzipsupport}
// TODO: do CRC checks
function InflateString(const Input: ansistring; var Output: ansistring): Boolean;
var
  I: Integer;
  ReadPos: Integer;
  Flags: Byte;
  //CrcHeader: Word;
  BufferStart,
  BufferEnd: LongWord;
  InflateStream: z_stream;
  Temp: ansistring;
begin
  result:=False;
  if Length(Input)<4 then
    Exit;

  if (ord(Input[1]) and $1f = $1f) and (ord(Input[2]) and $8b = $8B) and
     (ord(Input[3]) and $08 = $08) then
  begin
    // gzip header
    flags:=Ord(Input[4]);
    readPos:=10; // 4 bytes header, 4 bytes timestamp, 2 bytes extra flags
    if (flags and $04 <> 0) then // Extra data flag
      readPos:=ReadPos + Byte(Input[readPos+1]) + Byte(Input[readPos+2])*$100 +
               Byte(Input[readPos+3])*$10000 + Byte(Input[readPos+4])*$1000000;

    if (flags and $08 <> 0) then // name flag
      while (readpos < length(Input)) and (Input[Readpos+1] <> #0) do
        Inc(ReadPos);

    if (flags and $10 <> 0) then // name flag
      while (readpos < length(Input)) and (Input[Readpos+1] <> #0) do
        Inc(ReadPos);

    if (flags and $02 <> 0) then // CRC16 flag
    begin
      //CrcHeader:=ord(Input[readPos+1]) + ord(Input[readPos+2])*$100;
      Inc(readPos, 2);
    end;
    BufferStart:=readPos;
    BufferEnd:=Length(Input)-8;
  end else
  if (ord(Input[1]) and $78 = $78) and (ord(Input[2]) and $9C = $9C) then
  begin
    // zlib
    BufferStart:=2;
    BufferEnd:=Length(Input) - 6;
  end else
  begin
    // raw
    BufferStart:=0;
    BufferEnd:=Length(Input);
  end;

  if not inflateInit2(InflateStream, -MAX_WBITS) = Z_OK then
    Exit;

  InflateStream.next_in:=@Input[1+BufferStart];
  InflateStream.avail_in:=BufferEnd - BufferStart;

  Output:='';
  I:=Z_OK;
  while (I=Z_OK) and (InflateStream.avail_in>0) do
  begin
    Setlength(Temp, 65536);
    InflateStream.next_out:=@Temp[1];
    InflateStream.avail_out:=Length(temp);
    while (InflateStream.avail_out>0)and(InflateStream.avail_in>0) do
    begin
      I:=inflate(InflateStream, Z_NO_FLUSH);
      if I<>Z_OK then
        Break;
    end;
    Setlength(Temp, Length(Temp) - InflateStream.avail_out);
    Output:=Output + Temp;
  end;
  inflateEnd(InflateStream);
  result:=(I = Z_STREAM_END) or (I = Z_OK);
end;
{$endif}

procedure ParseUrl(url: ansistring; var proto, host, port, uri: ansistring);
var
  i: Integer;
begin
  if pos('://', url)>0 then
  begin
    proto:=lowercase(System.Copy(url, 1, pos('://', url)-1));
    delete(url, 1, pos('://', url)+2);
  end else
    proto:='';

  if (pos(':', url)>0) and (pos('/', url)>pos(':', url)) then
  begin
    host:=System.Copy(url, 1, pos(':', url)-1);
    Delete(url, 1, pos(':', url));
    port:=System.Copy(url, 1, pos('/', url)-1);
    delete(url, 1, pos('/', url)-1);
    uri:=url;
  end else
  begin
    i:=pos('/', url)-1;
    if i<=0 then i:=Length(url);
    host:=System.Copy(url, 1, i);
    if proto='https' then
      port:='443'
    else
      port:='80';
    delete(url, 1, i);
    uri:=url;
    if uri='' then
      uri:='/';
  end;
end;

function SimpleHTTPGet(URL: ansistring): ansistring;

begin
  result:='';
  with THTTPClient.Create do
  try
    result:=Get(URL);
  finally
    Free;
  end;
end;

{ THTTPRequestThread }

function THTTPRequestThread.GetOnError: THTTPRequestErrorCallback;
begin
  result:=FClient.OnError;
end;

function THTTPRequestThread.GetOnForward: THTTPRequestForward;
begin
  result:=FClient.OnForward;
end;

function THTTPRequestThread.GetOnResponse: THTTPRequestResponse;
begin
  result:=FClient.OnResponse;
end;

function THTTPRequestThread.GetTimeout: longword;
begin
  result:=FClient.TimeOut;
end;

function THTTPRequestThread.GetUserAgent: ansistring;
begin
  result:=FClient.UserAgent;
end;

procedure THTTPRequestThread.SetOnError(AValue: THTTPRequestErrorCallback);
begin
  FClient.OnError:=AValue;
end;

procedure THTTPRequestThread.SetOnForward(AValue: THTTPRequestForward);
begin
  FClient.OnForward:=AValue;
end;

procedure THTTPRequestThread.SetOnResponse(AValue: THTTPRequestResponse);
begin
  FClient.OnResponse:=AValue;
end;

procedure THTTPRequestThread.SetTimeout(AValue: longword);
begin
  FClient.TimeOut:=AValue;
end;

procedure THTTPRequestThread.SetUserAgent(AValue: ansistring);
begin
  FClient.UserAgent:=AValue;
end;

procedure THTTPRequestThread.Execute;
begin
  FClient.Get(FURL);
end;

constructor THTTPRequestThread.Create(Url: ansistring);
begin
  FClient:=THTTPClient.Create;
  FURL:=Url;
  inherited Create(True);
end;

destructor THTTPRequestThread.Destroy;
begin
  WaitFor;
  FClient.Free;
  inherited Destroy;
end;


{ THTTPClient }

function THTTPClient.DoHandshake(const Host, Port: ansistring;
  https: Boolean): Boolean;
var
  s: ansistring;
begin
  result:=False;
  FSocket.Connect(Host, Port);

  if FSocket.LastError<>0 then
  begin
    if Assigned(FOnError) then
      FOnError(heConnectionFailed, FSocket.LastErrorDesc);
    Exit;
  end;

  if https then
  begin
    FSocket.SSL.SSLType:=LT_TLSv1_2;
    FSocket.SSLDoConnect;
    if FSocket.LastError<>0 then
    begin
      if Assigned(FOnError) then
        FOnError(heSSLError, FSocket.LastErrorDesc);
      Exit;
    end;
  end;
  // send request header and read reply
  FSocket.SendString(FRequest.Generate());
  s:=FSocket.RecvTerminated(FTimeOut, #13#10#13#10);

  if s='' then
  begin
    if Assigned(FOnError) then
      FOnError(heProtocolError, 'No data received');
    Exit;
  end;

  if not FResponse.Read(s) then
  begin
    if Assigned(FOnError) then
      FOnError(heProtocolError, 'Invalid HTTP response');
    Exit;
  end;

  if (FResponse.version <> 'HTTP/1.1') and (FResponse.Version <> 'HTTP/1.0') then
  begin
    if Assigned(FOnError) then
      FOnError(heProtocolError, 'Invalid Protocol Version');
    Exit;
  end;

  result:=True;
end;

function THTTPClient.ReadResponseBody: ansistring;
var
  i: Integer;
  {$ifdef gzipsupport}
  s: ansistring;
  {$endif}
begin
  i:=StrToIntDef(FResponse.header['Content-Length'], 0);
  result:='';
  if i<>0 then
  begin
    // this is potentially bad if we encounter big files.. we could add a
    // size limit check to avoid hogging memory because we accidently download
    // a very big file
    repeat
      result:=result+FSocket.RecvBufferStr(i, FTimeOut);
    until (Length(result)>=i) or ( (FSocket.LastError<>0) and (FSocket.LastError <> WSAETIMEDOUT));
  end else
  if FResponse.header['Transfer-Encoding'] = 'chunked' then
  begin
    // chunked reply => chunked reading!
    repeat
      // lazy approach to make StrToInt parse hex
      s:=FSocket.RecvTerminated(FTimeOut, #13#10);
      if s='' then
        Break
      else
        i:=StrToIntDef('0x'+s, 0);
      if i>0 then
      begin
        result:=result + FSocket.RecvBufferStr(i, FTimeOut);
        if FSocket.RecvTerminated(FTimeOut, #13#10) <> '' then
        begin
          if Assigned(FOnError) then
            FOnError(heProtocolError, 'Unexpected data between chunks');
          result:='';
        end;
      end;
    until s='';
  end else
  begin
    // no content length info, not chunked.. we just read data until it stops
    while (FSocket.LastError = 0) or (FSocket.LastError = WSAETIMEDOUT) do
    begin
      result:=result+FSocket.RecvPacket(FTimeOut);
    end;
  end;
  {$ifdef gzipsupport}
  if FResponse.header['Content-Encoding'] = 'gzip' then
  begin
    if InflateString(result, s) then
      result:=s
    else begin
      if Assigned(FOnError) then
        FOnError(heProtocolError, 'gzip inflate error');
      Exit;
    end;
  end;
  {$endif}
end;


function THTTPClient.Get(Url: ansistring): ansistring;
var
  Proto, Host, Port, uri, s: ansistring;
  Forwards: Integer;
begin
  result:='';
  FSocket.ConnectionTimeout:=TimeOut;
  Forwards:=0;
  try
    ParseUrl(Url, Proto, Host, port, uri);

    FRequest.action:='GET';
    FRequest.header.Add('Host', Host);
    FRequest.header.Add('Connection', 'close');
    FRequest.header.Add('User-Agent', FUserAgent);
    {$ifdef gzipsupport}
    FRequest.header.Add('Accept-Encoding', 'gzip');
    {$endif}

    // loop is used in case we encounter 301/302 forwards
    repeat
      // count loops just in case we run into an endless loop..
      Inc(Forwards);
      if Forwards>10 then
      begin
        if Assigned(FOnError) then
          FOnError(heForwardLoop, '');
        Exit;
      end;

      if (Proto <> '') and (Proto <> 'http') and (Proto <> 'https') then
      begin
        if Assigned(FOnError) then
          FOnError(heProtocolError, 'Invalid protocol');
        Exit;
      end;

      // setup request header
      FRequest.header.Add('Host', Host);
      if Pos('?', uri)>0 then
      begin
        FRequest.url:=System.Copy(uri, 1, Pos('?', uri)-1);
        FRequest.parameters:=System.Copy(uri, Pos('?', uri)+1, Length(uri));
      end else
      begin
        FRequest.url:=uri;
        FRequest.parameters:='';
      end;

      if not DoHandshake(Host, Port, Proto='https') then
        Exit;

      // check if we are being forwarded
      if (Pos('302', FResponse.response)=1)or(Pos('301', FResponse.response)=1) then
      begin
        FSocket.CloseSocket;
        s:=FResponse.header['Location'];
        if s = '' then
        begin
          if Assigned(FOnError) then
            FOnError(heProtocolError, 'No forward location specified');
          Exit;
        end;
        if Assigned(FOnForward) then
        begin
          if not FOnForward(s) then
            Exit;
        end;
        ParseUrl(s, Proto, Host, port, url);
        Continue;
      end;
      result:=ReadResponseBody();
      if Assigned(FOnResponse) then
        FOnResponse(FResponse.response, result);
      Break;
    until false;
  except
    on e: Exception do
      if Assigned(FOnError) then
        FOnError(heInternalError, e.Message);
  end;
end;

constructor THTTPClient.Create;
begin
  FSocket:=TTCPBlockSocket.Create;
  FRequest:=THTTPRequest.Create;
  FResponse:=THTTPReply.Create;
  FTimeOut:=10000;
  FUserAgent:='Mozilla/4.0 (MSIE 6.0; Windows NT 5.0)'; // ie6 on win2000.. that oughta be good
end;

destructor THTTPClient.Destroy;
begin
  FRequest.Free;
  FResponse.Free;
  FSocket.Free;
  inherited Destroy;
end;

end.

