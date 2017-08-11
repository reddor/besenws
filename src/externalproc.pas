unit externalproc;

{$mode delphi}

interface

uses
  Classes,
  SysUtils,
  baseunix,
  unix,
  linux,
  process,
  epollsockets;

type

  TExternalProcCallback= procedure(const Data: ansistring) of object;

  { TExternalProc }

  TExternalProc = class(TCustomEpollHandler)
  private
    FOnData: TExternalProcCallback;
    FProcess: TProcess;
    FData: ansistring;
    FBuffer: array[0..32767] of Char;
  protected
    procedure DataReady(Event: epoll_event); override;
    procedure SendData;
  public
    constructor Create(AParent: TEpollWorkerThread; AFilename, AParameters, AEnv: ansistring);
    destructor Destroy; override;
    procedure Write(Data: Pointer; Length: Integer);
    property OnData: TExternalProcCallback read FOnData write FOnData;
  end;

implementation

uses
  logging;

{ TExternalProc }

procedure TExternalProc.DataReady(Event: epoll_event);
var
  BufRead: Integer;
  i: Integer;
  s: ansistring;
begin
  if (Event.Events and EPOLLIN<>0) then
  begin
    // got data

    repeat
      bufRead:=FpRead(FProcess.Output.Handle, @FBuffer, SizeOf(FBuffer)); //fprecv(Event.Data.fd, @FBuffer, SizeOf(FBuffer), MSG_DONTWAIT or MSG_NOSIGNAL);

      if bufRead>0 then
      begin
        i:=Length(FData);
        Setlength(FData, i+bufRead);
        Move(FBuffer, FData[i+1], bufRead);
      end else
      if bufRead<=0 then
      begin
        bufRead:=FpRead(FProcess.Stderr.Handle, @FBuffer, SizeOf(FBuffer));
        if bufRead>0 then
        begin
          setlength(s, bufRead);
          Move(FBuffer, s[1], bufRead);
          dolog(llWarning, 'CGI: '+s);
        end;
      end;

    until bufRead<=0;
  end else
  if (Event.Events and EPOLLERR<>0) or (Event.Events and EPOLLHUP <>0) then
  begin
    RemoveHandle(FProcess.Output.Handle);
    RemoveHandle(FProcess.Stderr.Handle);
    SendData;
  end;
end;

procedure TExternalProc.SendData;
begin
  if Assigned(FOnData) then
    if FData = '' then
      FOnData('Content-type: text/html'#13#10#13#10+'CGI did not return any data')
    else
      FOnData(FData);
end;

constructor TExternalProc.Create(AParent: TEpollWorkerThread; AFilename, AParameters, AEnv: ansistring);
begin
  inherited Create(AParent);
  FProcess:=TProcess.Create(nil);
  FProcess.Executable:=AFilename;
  FProcess.Parameters.Text:=AParameters;
  FData:='';
  FProcess.Options := [poUsePipes];

  FProcess.Environment.Text:=AEnv;

  FProcess.Execute;

  fpfcntl(FProcess.Output.Handle, F_SetFl, fpfcntl(FProcess.Output.Handle, F_GetFl) or O_NONBLOCK);
  AddHandle(FProcess.Output.Handle);

  fpfcntl(FProcess.Stderr.Handle, F_SetFl, fpfcntl(FProcess.Stderr.Handle, F_GetFl) or O_NONBLOCK);
  AddHandle(FProcess.Stderr.Handle);
end;

procedure TExternalProc.Write(Data: Pointer; Length: Integer);
var
  s: ansistring;
begin
  setlength(s, Length);
  Move(Data^, s[1], Length);
  FProcess.Input.Write(Data^, Length);
end;

destructor TExternalProc.Destroy;
begin
  inherited Destroy;
  FProcess.Active:=False;
  FProcess.Terminate(0);
  FProcess.Free;
end;

end.

