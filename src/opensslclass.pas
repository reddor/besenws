unit opensslclass;

{$mode delphi}

interface

uses
  Classes,
  SysUtils,
  sslclass,
  Sockets,
  ssl_openssl_lib;

type

  { TOpenSSLSession }

  TOpenSSLSession = class(TAbstractSSLSession)
  private
    FSSL: PSSL;
    FSSLWantWrite: Boolean;
    procedure CheckSSLError(ErrNo: Longword);
  public
    constructor Create(AParent: TAbstractSSLContext; AContext: PSSL_CTX; ASocket: TSocket);
    function Read(Buffer: Pointer; BufferSize: Integer): Integer; override;
    function Write(Buffer: Pointer; BufferSize: Integer): Integer; override;
    function WantWrite: Boolean; override;
  end;

  { TOpenSSLContext }
  TOpenSSLContext = class(TAbstractSSLContext)
  private
    FSSLCertPass: string;
    FSSLContext: PSSL_CTX;
    FSSLMethod: PSSL_METHOD;
  public
    function Enable(const PrivateKeyFile, CertificateFile, CertPassword: ansistring): Boolean; override;
    function StartSession(Socket: TSocket): TOpenSSLSession; override;
  end;

implementation

uses
  logging;

function passwordcallback(buf: Pointer; Size: longint; rwflag: longint; userdata: pointer): longint; cdecl;
var s: ansistring;
begin
  result:=-1;
  if Assigned(userdata) then
    s:=TOpenSSLContext(userdata).FSSLCertPass
  else
    Exit;
  Move(s[1], buf^, length(s));
  result:=Length(s);
end;

{ TOpenSSLSession }

procedure TOpenSSLSession.CheckSSLError(ErrNo: Longword);
var
  i: Integer;
  s: string;
begin
  i:=SslGetError(fssl, ErrNo);
  case i of
    SSL_ERROR_NONE: dolog(llError, ': SSL Error - SSL_ERROR_NONE');
    SSL_ERROR_SSL: begin
      setlength(s, 256);
      ErrErrorString(ErrGetError, s, Length(s));
      dolog(llError, ': SSL Error - '+s);
      //FWantclose:=True;
    end;
    SSL_ERROR_SYSCALL:
    begin
      if ErrNo<>0 then
      begin
        setlength(s, 256);
        ErrErrorString(ErrGetError, s, Length(s));
        dolog(llError, ': SSL Error - SSL_ERROR_SYSCALL -'+s);
      end;
      //FWantclose:=True;
    end;
    SSL_ERROR_WANT_CONNECT: dolog(llError, ': SSL Error - SSL_ERROR_WANT_CONNECT');
    SSL_ERROR_WANT_READ:
    begin
      // this error can be savely ignored - data will be read automatically via epoll
    end;
    SSL_ERROR_WANT_WRITE:
    begin
      // openssl wants a
      FSSLWantWrite:=True;
      //FlushSendbuffer;
    end;
    SSL_ERROR_WANT_X509_LOOKUP: dolog(llError, ': SSL Read Error - SSL_ERROR_WANT_X509_LOOKUP');
    SSL_ERROR_ZERO_RETURN:
    begin
      dolog(llError, ': SSL Error - SSL_ERROR_ZERO_RETURN');
      //FWantclose:=True;
    end;

    SSL_ERROR_WANT_ACCEPT: dolog(llError, ': SSL Read Error - SSL_ERROR_WANT_ACCEPT');
    else
      dolog(llError, ': SSL Read Error - Other #'+IntToStr(i));
  end;
end;

constructor TOpenSSLSession.Create(AParent: TAbstractSSLContext;
  AContext: PSSL_CTX; ASocket: TSocket);
var
  i: Integer;
begin
  inherited Create(AParent);

  FSSL := SslNew(AContext);
  if Assigned(FSSL) then
  begin
    i:=SslSetFd(FSSL, ASocket);
    if i<=0 then
      CheckSSLError(i);
    i:=SslAccept(fssl);
    if i<=0 then
      CheckSSLError(i);
  end else
    dolog(llError, 'SSL_new() failed!');
end;

function TOpenSSLSession.Read(Buffer: Pointer; BufferSize: Integer): Integer;
begin
  result:=SslRead(FSSL, Buffer, BufferSize);
  if result<=0 then
  begin
    CheckSSLError(result);
    result:=-1;
  end;
end;

function TOpenSSLSession.Write(Buffer: Pointer; BufferSize: Integer): Integer;
begin
  result:=SslWrite(FSSL, Buffer, BufferSize);
  FSSLWantWrite:=False;
  if result<0 then
  begin
    CheckSSLError(result);
    result:=-1;
  end;
end;

function TOpenSSLSession.WantWrite: Boolean;
begin
  result:=FSSLWantWrite;
end;

{ TOpenSSLContext }

function TOpenSSLContext.Enable(const PrivateKeyFile, CertificateFile,
  CertPassword: ansistring): Boolean;
var
  i: Integer;
begin
  result:=False;

  FSSLMethod:=SslMethodTLSV1;
  FSSLContext:=SslCtxNew(FSSLMethod);
  FSSLCertPass := CertPassword;

  SslCtxSetDefaultPasswdCbUserdata(FSSLContext, self);
  SslCtxSetDefaultPasswdCb(FSSLContext, @passwordcallback);

  i:=SslCtxUsePrivateKeyFile(FSSLContext, PrivateKeyFile, SSL_FILETYPE_PEM);
  if i<>1 then
    dolog(lLError,'SSL: Could not read server key!');

  i:=SslCtxUseCertificateFile(FSSLContext, CertificateFile, SSL_FILETYPE_PEM);
  if i<>1 then
    dolog(lLError,'SSL: Could not read certificate!');

  i:= SslCtxCheckPrivateKeyFile(FSSLContext);
  if i<>1 then
  begin
    dolog(llError, 'SSL: could not verify key file!');
    FSSLContext:=nil;
    result:=False;
  end else
    result:=True;
end;

function TOpenSSLContext.StartSession(Socket: TSocket): TOpenSSLSession;
begin
  result:=TOpenSSLSession.Create(Self, FSSLContext, Socket);
end;

initialization
  InitSSLInterface;
  OPENSSLaddallalgorithms;
end.

