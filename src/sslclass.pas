unit sslclass;

{$mode delphi}

interface

uses
  Classes,
  SysUtils,
  Sockets;

type
  TAbstractSSLContext = class;

  { TAbstractSSLConnection }

  TAbstractSSLSession = class
  private
    FParent: TAbstractSSLContext;
  public
    constructor Create(AParent: TAbstractSSLContext);
    function Read(Buffer: Pointer; BufferSize: Integer): Integer; virtual; abstract;
    function Write(Buffer: Pointer; BufferSize: Integer): Integer; virtual; abstract;
    function WantWrite: Boolean; virtual; abstract;

    property Parent: TAbstractSSLContext read FParent;
  end;

  TAbstractSSLContext = class
  public
    function Enable(const PrivateKeyFile, CertificateFile, CertPassword: ansistring): Boolean; virtual; abstract;
    function StartSession(Socket: TSocket): TAbstractSSLSession; virtual; abstract;
  end;

implementation

{ TAbstractSSLConnection }

constructor TAbstractSSLSession.Create(AParent: TAbstractSSLContext);
begin
  FParent:=AParent;
end;

end.

