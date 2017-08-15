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
    constructor Create(AParent: TAbstractSSLContext; ASSL: PSSL);
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

function CheckOpenSSLError(fssl: PSSL; ErrNo: Longword): integer;
var
  s: string;
begin
  result:=SslGetError(fssl, ErrNo);
  case result of
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
      // FSSLWantWrite:=True;
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
      dolog(llError, ': SSL Read Error - Other #'+IntToStr(result));
  end;
end;


{ TOpenSSLSession }

procedure TOpenSSLSession.CheckSSLError(ErrNo: Longword);
begin
  if CheckOpenSSLError(FSSL, ErrNo) = SSL_ERROR_WANT_WRITE then
    FSSLWantWrite:=True;
end;

constructor TOpenSSLSession.Create(AParent: TAbstractSSLContext; ASSL: PSSL);
begin
  inherited Create(AParent);
  FSSL := ASSL;
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
var
  ssl: PSSL;
  i: INteger;
begin
  result:=nil;
  ssl := SslNew(FSSLContext);
  if Assigned(ssl) then
  begin
    i:=SslSetFd(ssl, Socket);
    if i>0 then
      i:=SslAccept(ssl);
    if i<=0 then
    begin
      case CheckOpenSSLError(ssl, i) of
        SSL_ERROR_WANT_WRITE: ;
        SSL_ERROR_WANT_READ: ;
        else begin
          SslFree(ssl);
          ssl:=nil;
        end;
      end;
    end;
    if Assigned(ssl) then
      result:=TOpenSSLSession.Create(Self, ssl);
  end else
    dolog(llError, 'SSL_new() failed!');
end;

initialization
  InitSSLInterface;
  OPENSSLaddallalgorithms;
end.

