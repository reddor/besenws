unit epollsockets;
{
 an abstraction layer for handling sockets with epoll

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
  baseunix,
  unix,
  linux,
  sockets,
  synsock,
{$IFDEF OPENSSL_SUPPORT}
  ssl_openssl_lib,
{$ENDIF}
  logging;

const
  { maximum concurrent connections per thread }
  MaxConnectionsPerThread = 40000;
  { maximum number of sockets a thread can accept in a single turn, inbetween
    epoll events }
  NewSocketBufferSize = 1024;

type
  TEPollSocket = class;
  TEpollWorkerThread = class;
  TEPollSocketEvent = procedure(Sender: TEPollSocket) of object;

  { TEPollSocket }

  TEPollSocket = class
  private
    FOutbuffer: ansistring;
    FOutbuffer2: ansistring;
    FonDisconnect: TEPollSocketEvent;
    FParent: TEpollWorkerThread;
    FSocket: TSocket;
    FRemoteIP, FRemoteIPPort: ansistring;
    FWantClose: Boolean;
{$IFDEF OPENSSL_SUPPORT}
    FWantSSL: Boolean;
    FIsSSL: Boolean;
    FSSLContext: PSSL_CTX;
    FSSL: PSSL;
    FSSLWantWrite: Boolean;
    procedure CheckSSLError(ErrNo: Longword);
{$ENDIF}
  protected
    { process incoming data - called by worker thread, has to be overridden }
    procedure ProcessData(const Data: ansistring); virtual; abstract;
    { send data - if flush is true, data will be immediately written to the
      socket, or stored until FlushSendbuffer is called }
    procedure SendRaw(const Data: ansistring; Flush: Boolean = True);
    { reads up to Length(Data) bytes from socket - called by worker thread.
      'Data' acts as a temporary buffer }
    function ReadData(var Data: ansistring): Boolean;
    { flush data that needs to be written to the socket - can be called manually,
      but is also called from worker thread (e.g. when not all data can be sent
      in one pass) }
    function FlushSendbuffer: Boolean;
    { returns true when the socket can be closed, and all outgoing data has
      been sent }
    function WantClose: Boolean;
    { returns true if socket can be closed. override this to add custom checks,
      is called by thread worker to determine if class can be removed from queue }
    function CheckTimeout: Boolean; virtual;
  public
    constructor Create(Socket: TSocket);
    destructor Destroy; override;
    { performs cleanup - closes socket, disposes any data that is held in class
      members. After cleanup, the class can be reused using .Reassign() }
    procedure Cleanup; virtual;
    { this frees the class. in derived classes this can be overridden to
      e.g. put this class instance back into a pool, instead of freeing }
    procedure Dispose; virtual;
    { assigns a new socket to to reuse the class. Cleanup must have been called
      before }
    procedure Reassign(Socket: TSocket);
    { move socket to another worker thread }
    function Relocate(NewParent: TEpollWorkerThread): Boolean;
    { marks the connection as "WantClosed". Remaining asynchronous send operations
      will be finished first before the socket is actually closed. this is done
      in the worker thread }
    procedure Close;
    { returns ip and port }
    function GetPeerName: string;
    { returns ip }
    function GetRemoteIP: string;
{$IFDEF OPENSSL_SUPPORT}
    { performs ssl handshake }
    procedure StartSSL;
    { cleans up ssl - you probably don't want to call this manually }
    procedure StopSSL;
{$ENDIF}
    { actual socket handle }
    property Socket: TSocket read FSocket;
    { Parent Thread }
    property Parent: TEpollWorkerThread read FParent;
    { callback function when socket is closed }
    property OnDisconnect: TEPollSocketEvent read FonDisconnect write FOnDisconnect;
{$IFDEF OPENSSL_SUPPORT}
    { returns true if ssl has been loaded }
    property IsSSL: Boolean read FIsSSL;
    { if true, SSL handshake is performed }
    property WantSSL: Boolean read FWantSSL write FWantSSL;
    { the associated openssl context }
    property SSLContext: PSSL_CTX read FSSLContext write FSSLContext;
{$ENDIF}
  end;

  { TEpollWorkerThread }

  TEpollWorkerThread = class(TThread)
  private
    FCS: TCriticalSection;
    FEpollFD: integer;
    FOnConnection: TEPollSocketEvent;
    FUpdated: Boolean;
    FNewSocketCount: Integer;
    FNewSockets: array[0..NewSocketBufferSize-1] of TEPollSocket;
    FEpollEvents: array[0..MaxConnectionsPerThread-1] of epoll_event;
    FSockets: array of TEPollSocket;
    FParent: TObject;
    FTicks: Integer;
    FTotalCount: Integer;
    procedure RemoveSocket(Sock: TEPollSocket; doClose: Boolean = True; doFree: Boolean = true);
  protected
    { puts newly added sockets in epoll-queue }
    procedure GetNewSockets;
    { called inbetween epoll, checks for client timeouts }
    procedure ThreadTick; virtual;
    { overriden thread function }
    procedure Execute; override;
  public
    constructor Create(aParent: TObject);
    destructor Destroy; override;
    { add socket - this is automatically called from TEPollSocket.Relocate }
    function AddSocket(Sock: TEPollSocket): Boolean;
    property EPollFD: integer read FEPollFD write FEpollFD;
    property OnConnection: TEPollSocketEvent read FOnConnection write FOnConnection;
    property Totalcount: Integer read FTotalCount;
    property Parent: TObject read FParent;
  end;

implementation

uses
  webserver;

{ TEPollSocket }

{$IFDEF OPENSSL_SUPPORT}
procedure TEPollSocket.CheckSSLError(ErrNo: Longword);
var
  i: Integer;
  s: string;
begin
  i:=SslGetError(fssl, ErrNo);
  case i of
    SSL_ERROR_NONE: dolog(llError, GetPeerName+': SSL Error - SSL_ERROR_NONE');
    SSL_ERROR_SSL: begin
      setlength(s, 256);
      ErrErrorString(ErrGetError, s, Length(s));
      dolog(llError, GetPeerName+': SSL Error - '+s);
      FWantclose:=True;
    end;
    SSL_ERROR_SYSCALL:
    begin
      if ErrNo<>0 then
      begin
        setlength(s, 256);
        ErrErrorString(ErrGetError, s, Length(s));
        dolog(llError, GetPeerName+': SSL Error - SSL_ERROR_SYSCALL -'+s);
      end;
      FWantclose:=True;
    end;
    SSL_ERROR_WANT_CONNECT: dolog(llError, GetPeerName+': SSL Error - SSL_ERROR_WANT_CONNECT');
    SSL_ERROR_WANT_READ:
    begin
      // this error can be savely ignored - data will be read automatically via epoll
    end;
    SSL_ERROR_WANT_WRITE:
    begin
      // openssl wants a
      FSSLWantWrite:=True;
      FlushSendbuffer;
    end;
    SSL_ERROR_WANT_X509_LOOKUP: dolog(llError, GetPeerName+': SSL Read Error - SSL_ERROR_WANT_X509_LOOKUP');
    SSL_ERROR_ZERO_RETURN:
    begin
      dolog(llError, GetPeerName+': SSL Error - SSL_ERROR_ZERO_RETURN');
      FWantclose:=True;
    end;

    SSL_ERROR_WANT_ACCEPT: dolog(llError, GetPeerName+': SSL Read Error - SSL_ERROR_WANT_ACCEPT');
    else
      dolog(llError, GetPeerName+': SSL Read Error - Other #'+IntToStr(i));
  end;
end;
{$ENDIF}

procedure TEPollSocket.SendRaw(const Data: ansistring; Flush: Boolean);
begin
{$IFDEF OPENSSL_SUPPORT}
  if FSSLWantWrite then
  begin
    FOutbuffer2:=FOutbuffer2 + data;
    Exit;
  end;
{$ENDIF}

  FOutbuffer:=FOutbuffer + data;
  if Flush then
    FlushSendbuffer;
end;

function TEPollSocket.ReadData(var Data: ansistring): Boolean;
var
  k, err: Integer;
  data2: ansistring;
begin
{$IFDEF OPENSSL_SUPPORT}
  if FIsSSL then
  begin
    k:=SslRead(FSSL, @Data[1], Length(Data));
    if k<=0 then
    begin
      result:=False;
      CheckSSLError(k);
    end else
    begin
      data2:=data;
      Setlength(data2, k);
      ProcessData(data2);
      data2:='';
      result:=True;
    end;
    Exit;
  end;
{$ENDIF}

  k := fprecv(FSocket, @data[1], Length(data), MSG_DONTWAIT or MSG_NOSIGNAL);
  if k<=0 then
  begin
    if k<0 then
    begin
      err:=fpgeterrno;
      if err=ESysECONNRESET then
      begin
        dolog(llDebug, GetPeerName+': Connection reset');
        result:=False;
        FWantClose:=True;
      end else
      if err<>ESysEWOULDBLOCK then
      begin
        dolog(llDebug, GetPeerName+': error in fprecv #'+IntTostr(err));
        result:=False;
        FWantClose:=True;
      end else
        result:=True; // would block
    end else
    begin
      result:=False; // connection closed
      FWantClose:=True;
    end;
  end else
  begin
    data2:=data;
    Setlength(data2, k);
    ProcessData(data2);
    data2:='';
    result:=True;
  end;
end;

function TEPollSocket.FlushSendbuffer: Boolean;
var
  i: Integer;
  event: epoll_event;
begin
  result:=False;

  if not Assigned(FParent) then
    Exit;

  if (Length(FOutbuffer)>0)
{$IFDEF OPENSSL_SUPPORT}
     or(FSSLWantWrite)
{$ENDIF}
  then begin

{$IFDEF OPENSSL_SUPPORT}
    if FIsSSL then
    begin
      // openssl might want to write something even when we have no data
      if Length(FOutBuffer)=0 then
        i:=SslWrite(FSSL, nil, 0)
      else
        i:=SslWrite(FSSL, @FOutBuffer[1], Length(FOutbuffer));

      FSSLWantWrite:=False;
      if i<=0 then
      begin
        CheckSSLError(i);
        i:=0;
      end else
        result:=True;
    end else
{$ENDIF}
    begin
      i:=fpsend(FSocket, @FOutbuffer[1], Length(FOutbuffer), MSG_DONTWAIT or MSG_NOSIGNAL);
      if i<0 then
      begin
        dolog(llError, GetPeerName+': Error in fpsend #'+IntTostr(fpgeterrno));
        FWantclose:=True;
      end
      else if i=0 then
        dolog(llDebug, GetPeerName+': fpsend Could not send anything, #'+IntTostr(fpgeterrno))
      else
        result := True;
    end;

    if result and (i>0) then
      delete(FOutbuffer, 1, i);

    if (Length(FOutBuffer)>0)
{$IFDEF OPENSSL_SUPPORT}
       or FSSLWantWrite
{$ENDIF}
    then begin
      event.Events:=EPOLLIN or EPOLLOUT;
      event.Data.ptr:=Self;
      if epoll_ctl(FParent.epollfd, EPOLL_CTL_MOD, FSocket, @event)<0 then
        dolog(llDebug, GetPeerName+': epoll_ctl_mod failed (epollin+epollout), error #'+IntTostr(fpgeterrno));
    end else
    if (Length(FOutbuffer)=0)and(Length(FOutbuffer2)>0) then
    begin
      FOutbuffer:=FOutbuffer2;
      FOutbuffer2:='';
      FlushSendbuffer();
    end;
  end else
  begin
   event.Events:=EPOLLIN;
   event.Data.ptr:=Self;
   if epoll_ctl(FParent.epollfd, EPOLL_CTL_MOD, FSocket, @event)<0 then
     dolog(llDebug, GetPeerName+': epoll_ctl_mod failed (epollin), error #'+IntTostr(fpgeterrno));
  end;
end;

constructor TEPollSocket.Create(Socket: TSocket);
begin
  FParent:=nil;
  FSocket:=Socket;
end;

function TEPollSocket.GetPeerName: string;
var
  len: integer;
  Name: TVarSin;
begin
  if FRemoteIPPort<>'' then
    result:=FRemoteIPPort
  else begin
    begin
      len := SizeOf(name);
      FillChar(name, len, 0);
      fpGetPeerName(FSocket, @name, @Len);
      FRemoteIP:=GetSinIP(Name);
      FRemoteIPPort:=FRemoteIP+'.'+IntToStr(GetSinPort(Name));
      result:=FRemoteIP;
    end;
  end;
end;

function TEPollSocket.GetRemoteIP: string;
begin
  if FRemoteIP='' then
    GetPeerName;
  result:=FRemoteIP;
end;

function TEPollSocket.Relocate(NewParent: TEpollWorkerThread): Boolean;
begin
  if Assigned(FParent) then
    FParent.RemoveSocket(Self, False, False);

  FParent:=NewParent;
  result:=NewParent.AddSocket(Self);

  if not result then
  begin
    FParent:=nil;
  end;
end;

destructor TEPollSocket.Destroy;
begin
  Cleanup;
  inherited Destroy;
end;

procedure TEPollSocket.Reassign(Socket: TSocket);
begin
  if FSocket<>0 then
    raise Exception.Create('TEpollSocket.Reassign was called while still holding socket');
  FParent:=nil;
  FSocket:=Socket;
end;

{$IFDEF OPENSSL_SUPPORT}
procedure TEPollSocket.StartSSL;
var
  i: Integer;
begin
  if FIsSSL then
    Exit;
  GetPeerName;
  fssl := SslNew(FSSLContext);
  if Assigned(fssl) then
  begin
    i:=SslSetFd(fssl, FSocket);
    if i<=0 then
      CheckSSLError(i);
    i:=SslAccept(fssl);
    if i<=0 then
      CheckSSLError(i);
    FIsSSL:=True;
  end else
    dolog(llError, 'SSL_new() failed!');
end;

procedure TEPollSocket.StopSSL;
begin
   if not FIsSSL then
     Exit;
  SslFree(fssl);
  FIsSSL:=False;
  Fssl:=nil;
end;

{$ENDIF}

procedure TEPollSocket.Cleanup;
begin
   if Assigned(FonDisconnect) then
     FonDisconnect(Self);

 {$IFDEF OPENSSL_SUPPORT}
   if FIsSSL then
     StopSSL;
 {$ENDIF}
   if FSocket<>0 then
     fpclose(FSocket);
   FSocket:=0;
   FWantclose:=False;
   FOutbuffer:='';
   FOutbuffer2:='';
   FRemoteIP:='';
   FRemoteIPPort:='';
   FOnDisconnect:=nil;
end;

procedure TEPollSocket.Dispose;
begin
  Free;
end;

procedure TEPollSocket.Close;
begin
  FWantClose:=True;
end;

function TEPollSocket.WantClose: Boolean;
begin
  result:=(FOutbuffer='')and FWantclose;
end;

function TEPollSocket.CheckTimeout: Boolean;
begin
  result:=FWantClose;
end;

{ TEpollWorkerThread }

procedure TEpollWorkerThread.Execute;
var
  i, j, k: Integer;
  data: ansistring;
  conn: TEPollSocket;
begin
  epollfd:=0;
  epollfd := epoll_create(MaxConnectionsPerThread);

  Setlength(data, 64*1024); // temporary buffer

  while (not Terminated) do
  begin
    GetNewSockets;
    k:=Length(FSockets);
    if k>MaxConnectionsPerThread then
      k:=MaxConnectionsPerThread;
    if k=0 then
    begin
      Sleep(10);
      ThreadTick;
      Continue;
    end else
    begin
      i := epoll_wait(epollfd, @FEpollEvents[0], k, 1000);
      for j:=0 to i-1 do
      if Assigned((FEpollEvents[j].data.ptr)) then
      begin
       conn:=TEPollSocket(FEpollEvents[j].data.ptr);

       if conn.FParent <> Self then
       begin
         dolog(llError, conn.GetPeerName+': got epoll message from connection located in different thread');
       end else
       if (FEpollEvents[j].Events and EPOLLIN<>0) then
       begin
         conn.ReadData(Data);
       end else if (FEpollEvents[j].Events and EPOLLOUT<>0) then
       begin
         conn.FlushSendbuffer;
       end else if (FEpollEvents[j].Events and EPOLLERR<>0) then
        begin
          dolog(llDebug, 'got epoll-error '+Inttostr(fpgeterrno));
          conn.FWantclose:=True;
        end else
        begin
          dolog(llDebug, 'unknown epoll-event '+IntToStr(FEpollEvents[j].Events));
          conn.FWantclose:=True;
        end;

        if not Assigned(conn.FParent) then
        begin
          // the connection tried to relocate itself to another thread, but if failed
          dolog(llError, conn.GetPeerName+': Could not relocate - dropping connection!');
          // we have to drop the disconnect-event, as we might fire it from the wrong thread
          conn.FonDisconnect:=nil;
          // at this point we have to close the socket and forget about the incident
          conn.Free;
        end else
        if (conn.FParent = Self) and (conn.WantClose) then
        begin
           RemoveSocket(conn);
        end;
      end;
    end;
    ThreadTick;
  end;
  j:=High(FSockets);
  while j>=0 do
  begin
    RemoveSocket(FSockets[j]);
    Dec(j);
  end;
end;

procedure TEpollWorkerThread.RemoveSocket(Sock: TEPollSocket;
  doClose: Boolean; doFree: Boolean);
var
  i: Integer;
begin
  for i:=0 to Length(FSockets)-1 do
  if FSockets[i] = Sock then
  begin
    if epoll_ctl(epollfd, EPOLL_CTL_DEL, FSockets[i].Socket, nil)<0 then
      dolog(llError, 'epoll_ctl_del failed #'+IntToStr(fpgeterrno));

    sock.FParent:=nil;

    FSockets[i]:=FSockets[Length(FSockets)-1];
    Setlength(FSockets, Length(FSockets)-1);

    if doFree then
    begin
      Sock.Dispose;
    end;
    Exit;
  end;
end;

procedure TEpollWorkerThread.GetNewSockets;
var
  i,j,k: Integer;
  event: epoll_event;
begin
  FCS.Enter;
  try
    if FUpdated then
    begin
      FUpdated:=False;

      i := Length(FSockets);
      Setlength(FSockets, i+FNewSocketCount);

      k:=0;

      for j:=0 to FNewSocketCount-1 do
      begin
        FSockets[i+k]:=FNewsockets[j];
{$IFDEF OPENSSL_SUPPORT}
        if FSockets[i+k].WantSSL then
        begin
          FSockets[i+k].StartSSL;
          FSockets[i+k].WantSSL:=False;
        end;
{$ENDIF}
        event.Events:=EPOLLIN;
        event.Data.ptr:=FSockets[i+k];

        if epoll_ctl(epollfd, EPOLL_CTL_ADD, FSockets[i+k].Socket, @event)<0 then
        begin
          dolog(llDebug, 'epoll_ctl_add failed, error #'+IntTostr(fpgeterrno)+' '+IntToStr(i)+' '+IntToStr(k)+' '+IntToStr(FSockets[i+k].SOcket));
          FSockets[i+k].FWantclose:=True;
          //FSockets[i+k].OnDisconnect:=nil;
          FSockets[i+k].Dispose;
        end else
        begin
          if Assigned(FOnConnection) then
            FOnConnection(FSockets[i+k]);
          inc(k);
        end;
      end;
      if k<>FNewSocketCount then
        Setlength(FSockets, i+k);
    end;
    FNewSocketCount:=0;
  finally
    FCS.Leave;
  end;
end;

procedure TEpollWorkerThread.ThreadTick;
var j: Integer;
begin
  inc(Fticks);
  if(FTicks mod 100=0) then
  begin
    j:=Length(FSockets)-1;
    while j>=0 do
    begin
      if (FSockets[j].CheckTimeout)or Terminated then
      begin
        RemoveSocket(FSockets[j]);
        Dec(j, 2);
      end else
        Dec(j);
    end;
  end;
end;

constructor TEpollWorkerThread.Create(aParent: TObject);
begin
  FParent:=aParent;
  FCS:=TCriticalSection.Create;
//  Priority:=tpHigher;
  inherited Create(False);
end;

destructor TEpollWorkerThread.Destroy;
var
  i: Integer;
begin
  for i:=0 to FNewSocketCount-1 do
    FSockets[i].Free;
  FNewSocketCount:=0;
  Setlength(FSockets, 0);
  FCS.Destroy;
  inherited Destroy;
end;

function TEpollWorkerThread.AddSocket(Sock: TEPollSocket): Boolean;
begin
  inc(FTotalCount);
  result:=True;
  FCS.Enter;
  try
    if FNewSocketCount>=NewSocketBufferSize then
    begin
      dolog(llError, sock.GetPeerName+': Could not add socket to thread!');
      result:=False;
    end else
    begin
      FNewSockets[FNewSocketCount]:=Sock;
      Inc(FNewSocketCount);
      FUpdated:=True;
    end;
  finally
    FCS.Leave;
  end;
end;

end.

