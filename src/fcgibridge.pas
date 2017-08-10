unit fcgibridge;

{$mode delphi}

interface

uses
  Classes,
  SysUtils,
  baseunix,
  unix,
  linux,
  sockets,
  epollsockets,
  process,
  fpfcgi,
  fastcgi;

type
  { TFastCGIBridge }

  TFastCGIEvent = procedure(Header: PFCGI_Header; Data: Pointer; Length: Integer) of object;

  { TAbstractFastCGIBridge }

  TAbstractFastCGIBridge = class(TCustomEpollHandler)
  private
    FCurrentID: Word;
    FData: ansistring;
    FOnEvent: TFastCGIEvent;
  protected
    FHandle: THandle;
    function DataReady(Event: epoll_event): Boolean; override;
    procedure Send(Data: Pointer; Length: Integer); virtual; abstract;
    function Receive(Data: Pointer; Length: Integer): Integer; virtual; abstract;
    procedure ConnectionClosed; virtual; abstract;
    function ProcessData(const Data: ansistring): Boolean;
  public
    constructor Create(AParent: TEpollWorkerThread; AHandle: THandle);
    function BeginRequest: Word;
    procedure SetParameters(ID: Word; Parameters: ansistring);
    procedure SendRequest(ReqType: Byte; Id: Word; Data: Pointer; Length: Word);
    property OnEvent: TFastCGIEvent read FOnEvent write FOnEvent;
  end;

  { TSocketFastCGIBridge }

  { TFastCGIBridgeSocket }

  TFastCGIBridgeSocket = class(TAbstractFastCGIBridge)
  private
    FIP, FPort: ansistring;
    function Connect: THandle;
  protected
    procedure Send(Data: Pointer; Length: Integer); override;
    function Receive(Data: Pointer; Length: Integer): Integer; override;
    procedure ConnectionClosed; override;
  public
    constructor Create(AParent: TEpollWorkerThread; IP, Port: ansistring);
    destructor Destroy; override;
  end;

  { TFastCGIBridgeProcess }

  TFastCGIBridgeProcess = class(TAbstractFastCGIBridge)
  private
    FProcess: TProcess;
  protected
    procedure Send(Data: Pointer; Length: Integer); override;
    function Receive(Data: Pointer; Length: Integer): Integer; override;
    procedure ConnectionClosed; override;
  public
    constructor Create(AParent: TEpollWorkerThread; Binary, Parameter: ansistring);
    destructor Destroy; override;
  end;

  { TFastCGIBridgeFile }

  TFastCGIBridgeFile = class(TAbstractFastCGIBridge)
  protected
    procedure Send(Data: Pointer; Length: Integer); override;
    function Receive(Data: Pointer; Length: Integer): Integer; override;
    procedure ConnectionClosed; override;
  public
    constructor Create(AParent: TEpollWorkerThread; AFilename: ansistring);
  end;

implementation

uses
  blcksock;

const
  MaxTempBufferSize = 65536;

function SwapWord(w: Word): Word; inline;
begin
  result:=Word((w shr 8) or (w shl 8));
end;

{ TFastCGIBridgeFile }

procedure TFastCGIBridgeFile.Send(Data: Pointer; Length: Integer);
begin
  FpWrite(FHandle, Data,Length);
end;

function TFastCGIBridgeFile.Receive(Data: Pointer; Length: Integer): Integer;
begin
  result:=fpRead(FHandle, Data, Length);
end;

procedure TFastCGIBridgeFile.ConnectionClosed;
begin
  // well sheeit
  Writeln('connection closed');
end;

constructor TFastCGIBridgeFile.Create(AParent: TEpollWorkerThread;
  AFilename: ansistring);
begin
  inherited Create(AParent, FpOpen(AFilename, O_RdWr));
end;

{ TFastCGIBridgeSocket }

function TFastCGIBridgeSocket.Connect: THandle;
var
  sock: TTCPBlockSocket;
begin
  result:=-1;
  sock:=TTCPBlockSocket.Create;
  try
    sock.Connect(FIP, FPort);
    result:=sock.Socket;
    sock.Socket:=-1;
  finally
    Sock.Free;
  end;
end;

procedure TFastCGIBridgeSocket.Send(Data: Pointer; Length: Integer);
begin
  fpsend(FHandle, Data, Length, MSG_NOSIGNAL);
end;

function TFastCGIBridgeSocket.Receive(Data: Pointer; Length: Integer): Integer;
begin
  result:=fprecv(FHandle, Data, Length, MSG_DONTWAIT or MSG_NOSIGNAL);
end;

procedure TFastCGIBridgeSocket.ConnectionClosed;
begin
  Writeln('connection closed');
  FHandle:=Connect;
  fpfcntl(FHandle, F_SetFl, fpfcntl(FHandle, F_GetFl, 0) or O_NONBLOCK);
  AddHandle(FHandle);

end;

constructor TFastCGIBridgeSocket.Create(AParent: TEpollWorkerThread; IP,
  Port: ansistring);
begin
  FIP:=IP;
  FPort:=Port;
  inherited Create(AParent, Connect());
end;

destructor TFastCGIBridgeSocket.Destroy;
begin
  inherited Destroy;
  FpClose(FHandle);
end;

{ TFastCGIBridgeProcess }

procedure TFastCGIBridgeProcess.Send(Data: Pointer; Length: Integer);
begin
  FProcess.Input.Write(Data^, Length);
end;

function TFastCGIBridgeProcess.Receive(Data: Pointer; Length: Integer): Integer;
begin
  result:=FpRead(FProcess.Output.Handle, Data, Length);
end;

procedure TFastCGIBridgeProcess.ConnectionClosed;
begin
  Writeln('connection closed');
  FProcess.Terminate(0);
  FProcess.Execute;
end;

constructor TFastCGIBridgeProcess.Create(AParent: TEpollWorkerThread; Binary,
  Parameter: ansistring);
begin
  FProcess:=TProcess.Create(nil);
  FProcess.Executable:=Binary;
  FProcess.Parameters.Text:=Parameter;
  FProcess.Options := [poUsePipes];

  FProcess.Execute;

  inherited Create(AParent, FProcess.Output.Handle);
end;

destructor TFastCGIBridgeProcess.Destroy;
begin
  inherited Destroy;
  FProcess.Terminate(1001);
  FProcess.Free;
end;

{ TFastCGIBridge }

function TAbstractFastCGIBridge.DataReady(Event: epoll_event): Boolean;
var
  temp: ansistring;
  bufRead: Integer;
begin
  result:=True;
  Writeln('got event ', Event.Events);
  if (Event.Events and EPOLLIN<>0) then
  begin
    // got data
    Writeln('got data');
    Setlength(temp, MaxTempBufferSize);
    repeat
      bufRead:=Receive(@temp[1], Length(Temp));
      //bufRead:=fprecv(FSocket, @temp[1], Length(temp), MSG_DONTWAIT or MSG_NOSIGNAL);
      if (bufRead > 0) then
      begin
        if bufRead <> MaxTempBufferSize then
          Setlength(temp, bufRead);
        ProcessData(temp);
      end else
      if bufRead<0 then
        Writeln('error ', GetLastOSError, ' ', bufRead, ' ', socketerror);
    until bufRead <> MaxTempBufferSize;
  end;
  if (Event.Events and EPOLLHUP<>0) or (Event.Events and EPOLLERR <> 0) then
  begin
    Writeln('Epoll hup! ', GetLastOSError);
    RemoveHandle(FHandle);
    ConnectionClosed;
  end;
end;

procedure TAbstractFastCGIBridge.SendRequest(ReqType: Byte; Id: Word; Data: Pointer;
  Length: Word);
var
  Rec: FCGI_Header;
  Foo: ansistring;
begin
  Rec.reqtype:=ReqType;
  Rec.version:=1;
  Rec.paddingLength:=0;
  Rec.requestID:=SwapWord(Id);
  Rec.contentLength:=SwapWord(Length);
  Setlength(Foo, SizeOf(Rec) + Length);
  Move(Rec, Foo[1], SizeOf(rec));
  if Length>0 then
    Move(Data^, foo[SizeOf(Rec)+1], Length);
  Send(@foo[1], system.Length(foo));
  //if Length>0 then
  // Send(Data, Length);
end;

constructor TAbstractFastCGIBridge.Create(AParent: TEpollWorkerThread; AHandle: THandle
  );
begin
  Writeln(GetLastOSError);
  inherited Create(AParent);
  FHandle:=AHandle;
  FCurrentID:=1;
  fpfcntl(FHandle, F_SetFl, fpfcntl(FHandle, F_GetFl, 0) or O_NONBLOCK);
  AddHandle(FHandle);
end;

function TAbstractFastCGIBridge.BeginRequest: Word;
var
  Packet: FCGI_BeginRequestRecord;
begin
  result:=FCurrentID;
  Inc(FCurrentId);
  Packet.header.version:=1;
  Packet.header.reqtype:=FCGI_BEGIN_REQUEST;
  Packet.header.paddingLength:=0;
  Packet.header.contentLength:=SwapWord(Word(SizeOf(Packet.body)));
  Packet.header.requestID:=SwapWord(result);
  Packet.header.reserved:=0;
  Packet.body.role:=SwapWord(FCGI_RESPONDER);
  Packet.body.flags:=FCGI_KEEP_CONN;
  Send(@Packet, SizeOf(Packet));
end;

procedure TAbstractFastCGIBridge.SetParameters(ID: Word; Parameters: ansistring);
begin
  if Parameters<>'' then
    SendRequest(FCGI_PARAMS, id, @Parameters[1], Length(Parameters))
  else
    SendRequest(FCGI_PARAMS, id, nil, 0);
end;

function TAbstractFastCGIBridge.ProcessData(const Data: ansistring): Boolean;
var
  FHeader: PFCGI_Header;
begin
  result:=True;
  FData:=FData + Data;
  while Length(FData)>0 do
  begin
    if Length(FData)<SizeOf(FCGI_Header) then
      Exit;
    FHeader:=@FData[1];

    if Length(FData)<SizeOf(FCGI_Header) + SwapWord(FHeader^.contentLength) then
      Exit;

    if FHeader^.reqtype < FCGI_MAXTYPE then
    begin
      if Assigned(FOnEvent) then
        FOnEvent(FHeader, @FData[SizeOf(FCGI_Header)], SwapWord(FHeader^.contentLength));
    end;
    Delete(FData, 1, SizeOf(FCGI_Header) + SwapWord(FHeader^.contentLength) + FHeader^.paddingLength);
  end;
end;


end.

