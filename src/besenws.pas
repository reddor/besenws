program besenws;
{
 besenws - a web(socket)server powered by BESEN

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

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$IFDEF OPENSSL_SUPPORT}
  openssl in 'openssl.pas',
  {$ENDIF}
  Classes,
  SysUtils,
  webserver,
  filecache,
  unix,
  baseunix,
  linux,
  logging,
  webserverhosts,
  besenserverconfig,
  besenevents,
  besenwebscript,
  beseninstance,
  epollsockets;

{$R *.res}

var
  isdebug: Boolean;
  shutdown: Boolean;
  hasforked: Boolean;
  oa,na : PSigActionRec;

procedure ForkToBackground;
begin
  if hasforked then
    Exit;

  hasforked:=True;

  Writeln('Forking to background...');

  Close(input);
  Close(output);

  Assign(output,ChangeFileExt(ParamStr(0), '.std'));
  ReWrite(output);
  stdout:=output;
  Close(stderr);
  Assign(stderr,ChangeFileExt(ParamStr(0), '.err'));
  ReWrite(stderr);

  LogToFile(ChangeFileExt(ParamStr(0), '.log'));

  if FpFork()<>0 then
    Halt;

end;

procedure WritePid(p: TPid);
var t: Textfile;
begin
  Assignfile(t, ChangeFileExt(ParamStr(0), '.pid'));
  {$i-}rewrite(t);{$i+}
  if ioresult=0 then
  begin
    Writeln(t, p);
    Closefile(t);
  end;
end;

procedure DoSig(sig: longint); cdecl;
begin
  case sig of
    SIGHUP:
    begin
      dolog(llNotice, 'SIGHUP received');
      // Dispatch SIGHUP
    end;
    SIGINT:
    begin
     dolog(llNotice, 'SIGINT received');
     shutdown:=True;
    end;
    SIGTERM:
    begin
      dolog(llNotice, 'SIGTERM received');
      shutdown := True;
    end;
    SIGPIPE:
    begin
      dolog(llNotice, 'SIGPIPE received');
    end;
    SIGQUIT:
    begin
      dolog(llNotice, 'SIGQUIT received');
    end;
  end;
end;

begin
  Writeln('besen.ws server');

  try
    new(na);
    new(oa);
    na^.sa_Handler:=SigActionHandler(@DoSig);
    fillchar(na^.Sa_Mask,sizeof(na^.sa_mask),#0);
    na^.Sa_Flags:=0;
    {$ifdef Linux}
    na^.Sa_Restorer:=Nil;
    {$endif}

    if fpSigAction(SIGINT,na,oa)<>0 then
      dolog(llError, 'Could not set up signalhandler!');
    if fpSigAction(SIGTERM,na,oa)<>0 then
      dolog(llError, 'Could not set up signalhandler!');
    if fpSigAction(SIGQUIT,na,oa)<>0 then
      dolog(llError, 'Could not set up signalhandler!');
    if fpSigAction(SIGPIPE,na,oa)<>0 then
      dolog(llError, 'Could not set up signalhandler!');

    isdebug := Paramstr(1) = '-debug';

    if not isdebug then
    begin
      ForkToBackground;
    end else
      dolog(llNotice, 'Running in Debug Mode');

    WritePid(fpGetPid);

    shutdown:=False;

    ServerManager:=TWebserverManager.Create;
    ServerManager.Execute(ExtractFilePath(Paramstr(0))+'/settings.js', nil);
    dolog(llNotice, 'Loading complete');
    dolog(llNotice, IntToStr(ServerManager.Server.Sitemanager.TotalFileCount)+' files cached with '+
                    IntToFilesize(ServerManager.Server.Sitemanager.TotalFileSize)+'(+ '+
                    IntToFilesize(ServerManager.Server.Sitemanager.TotalGZipFileSize)+' compressed)');

    while not shutdown do
    begin
      Sleep(20);
      ServerManager.Process;
    end;

    dolog(llNotice, 'Shutting down');
    ServerManager.Destroy;

    FreeMem(na);
    Freemem(oa);
  except
    on e: Exception do
      dolog(llError, 'A serious program error has occured: '+ e.Message);
  end;
  dolog(llNotice, 'Good bye');
end.

