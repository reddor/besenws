unit webserverhosts;
{
 managment classes for sites

 a "site" in besenws terminology describes a single website with all data and scripts.

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
  syncobjs,
  filecache,
  contnrs,
  httphelper,
  jsonstore,
  epollsockets,
  logging;

const
  CustomStatusPageMin = 400;
  CustomStatusPageMax = 511;

type
  TWebserverSiteManager = class;
  TWebserverSite = class;

  { TFileCachingThread }

  TFileCachingThread = class(TThread)
  private
    FCS: TCriticalSection;
    FItems: array of TWebserverSite;
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure QueueScan(Site: TWebserverSite);
  end;

  TExternalScriptType = (esCGI, esFastCGI);

  { TWebserverSite }

  TWebserverSite = class
  private
    FCS: TCriticalSection;
    FScriptFileCache: TFileCache;
    FStorage: TJSONStore;
    FName, FPath: string;
    FParent: TWebserverSiteManager;
    FFileCache: TFileCache;
    FCustomHandlers: TFPObjectHashTable;
    FExternalScriptTypes: array of record
      ScriptType: TExternalScriptType;
      UrlPrefix: ansistring;
      Extension: ansistring;
      ParamA, ParamB: ansistring;
    end;
    FScriptDirs: array of record
      Dir: ansistring;
      Script: ansistring;
    end;
    FResponseHeaders: array of record
      Name: ansistring;
      Value: ansistring;
    end;
    FIndexNames: array of string;
    FWhitelistedProcesses: array of ansistring;
    FForwards: TFPStringHashTable;
    FCustomStatusPages: array[CustomStatusPageMin..CustomStatusPageMax] of ansistring;
    procedure ClearItem(Item: TObject; const Key: string; var Continue: Boolean);
  public
    constructor Create(Parent: TWebserverSiteManager; Path: ansistring);
    destructor Destroy; override;
    procedure log(Level: TLoglevel; Msg: string);
    procedure Rescan;
    procedure AddScriptDirectory(directory, filename: string);
    procedure AddForward(target, NewTarget: string);
    procedure AddIndexPage(name: string);
    function IsScriptDir(target: string; out Script, Params: string): Boolean;
    function IsForward(target: string; out NewTarget: string): Boolean;
    procedure AddResponseHeader(const name, value: ansistring);
    procedure AddFile(filename, content, fullpath: string);
    procedure AddHostAlias(HostName: string);
    procedure AddCustomHandler(url: string; Handler: TEpollWorkerThread);
    procedure AddCustomStatusPage(StatusCode: Word; URI: string);
    procedure AddCGI(urlPrefix, extension, binary, parameters: ansistring);
    procedure AddFastCGISocket(urlPrefix, extension, host, port: ansistring);
    procedure ApplyResponseHeader(const Response: THTTPReply);
    procedure AddWhiteListProcess(const Executable: ansistring);
    function IsProcessWhitelisted(const Executable: ansistring): Boolean;
    function GetCustomStatusPage(StatusCode: Word): ansistring;
    function GetStore(const Location: string): string;
    function PutStore(const Location, Data: string): Boolean;
    function DelStore(const Location: string): Boolean;
    function GetCustomHandler(url: string): TEpollWorkerThread;
    function GetIndexPage(var target: string): PFileCacheItem;
    function IsExternalScript(url: string; Client: TEPollSocket): Boolean;
    property Files: TFileCache read FFileCache;
    property Scripts: TFileCache read FScriptFileCache;
    property Path: string read FPath;
    property Name: string read FName;
    property Parent: TWebserverSiteManager read FParent;
  end;

  { TWebserverSiteManager }

  TWebserverSiteManager = class
  private
    FDefaultHost: TWebserverSite;
    FHosts: array of TWebserverSite;
    FHostsByName: TFPObjectHashTable;
    FPath: ansistring;
    FSharedScripts: TFileCache;
    FSharedScriptsDir: ansiString;
    FCacheThread: TFileCachingThread;
    FHostToDelete: TWebserverSite;
    function GetTotalFileCount: longword;
    function GetTotalFileSize: longword;
    function GetTotalGZipFileSize: longword;
    Procedure HostNameDeleteIterator(Item: TObject; const Key: string; var Continue: Boolean);
  public
    constructor Create(const BasePath: ansistring);
    destructor Destroy; override;
    procedure RescanAll;
    procedure ProcessTick;
    function UnloadSite(Path: string): Boolean;
    function AddSite(Path: string): TWebserverSite;
    function GetSite(Hostname: string): TWebserverSite;
    property Path: ansistring read FPath;
    property TotalFileCount: longword read GetTotalFileCount;
    property TotalFileSize: longword read GetTotalFileSize;
    property TotalGZipFileSize: longword read GetTotalGZipFileSize;
    property SharedScripts: TFileCache read FSharedScripts;
    property DefaultHost: TWebserverSite read FDefaultHost write FDefaultHost;
  end;


function IntToFilesize(Size: longword): string;

implementation

uses
  webserver,
  webservercgi,
  besenserverconfig;

function FileToStr(const aFilename: string): string;
var
  f: File;
begin
  Assignfile(f, aFilename);
  {$I-}Reset(f,1); {$I+}
  if ioresult=0 then
  begin
    Setlength(result, FileSize(f));
    Blockread(f, result[1], Filesize(f));
    CloseFile(f);
  end else
    result:='{}';
end;

procedure WriteFile(const aFilename, aContent: string);
var
  f: file;
begin
  Assignfile(f, aFilename);
  {$I-}Rewrite(f, 1);{$I+}
  if ioresult = 0 then
  begin
    {$I-}BlockWrite(f, aContent[1], Length(aContent));{$I+}
    if ioresult<>0 then
      dolog(llError, aFilename+': Could not write to disk!');
    Closefile(f);
  end;
end;

{ TFileCachingThread }

procedure TFileCachingThread.Execute;
var
  s: TWebserverSite;
  Done: Boolean;
begin
  Done:=True;

  while not Terminated do
  begin
    FCS.Enter;
    if Length(FItems)>0 then
    begin
      s:=FItems[Length(FItems)-1];
      Setlength(Fitems, Length(FItems)-1);
      Done:=False;
    end else
      s:=nil;
    FCS.Leave;
    if Assigned(s) then
    begin
      s.Files.DoScan(s.Path+'web','/');
      s.Scripts.DoScan(s.Path+'scripts', '/');
    end
    else begin
      if not Done then
      begin
        dolog(llNotice, IntToStr(ServerManager.Server.Sitemanager.TotalFileCount)+' files cached with '+
                        IntToFilesize(ServerManager.Server.Sitemanager.TotalFileSize)+'(+ '+
                        IntToFilesize(ServerManager.Server.Sitemanager.TotalGZipFileSize)+' compressed)');
        Done:=True;
      end;
      Sleep(50);
    end;
  end;
end;

constructor TFileCachingThread.Create;
begin
  FCS:=TCriticalSection.Create;
  inherited Create(False);
end;

destructor TFileCachingThread.Destroy;
begin
  Terminate;
  WaitFor;
  inherited Destroy;
  FCS.Free;
end;

procedure TFileCachingThread.QueueScan(Site: TWebserverSite);
var
  i: Integer;
begin
  FCS.Enter;
  i:=Length(FItems);
  Setlength(FItems, i+1);
  FItems[i]:=Site;
  FCS.Leave;
end;

{ TWebserverSite }

procedure TWebserverSite.ClearItem(Item: TObject; const Key: string;
  var Continue: Boolean);
begin
  Item.free;
end;

constructor TWebserverSite.Create(Parent: TWebserverSiteManager;
  Path: ansistring);
begin
  FCS:=TCriticalSection.Create;
  FStorage:=TJSONStore.Create;
  FForwards:=TFPStringHashTable.Create;
  FFileCache:=TFileCache.Create;
  FScriptFileCache:=TFileCache.Create;
  FCustomHandlers:=TFPObjectHashTable.Create(False);

  FParent:=Parent;
  FName:=Path;
  FPath:=FParent.Path+Path+'/';

  FStorage.Put(FName, FileToStr(FPath+'storage.json'));

  AddResponseHeader('X-Frame-Options', 'SAMEORIGIN');
  AddResponseHeader('X-XSS-Protection', '1');
  AddResponseHeader('X-Content-Type-Options', 'nosniff');

  AddIndexPage('index.htm');
  AddIndexPage('index.html');

  Scripts.DoScan(FPath+'scripts', '/');

  Rescan;
end;

destructor TWebserverSite.Destroy;
var
  p: TJSONElement;
begin
  p:=FStorage.GetObj(FName);
  if Assigned(p) then
  begin
    WriteFile(FPath+'storage.json', p.toJSON2());
  end;
  FFileCache.Free;
  FScriptFileCache.Free;
  FForwards.Free;
  FStorage.Free;
  FCustomHandlers.Iterate(ClearItem);
  FCustomHandlers.Free;
  FCS.Free;
  Setlength(FScriptDirs, 0);
  log(llNotice, 'Site unloaded');
  inherited Destroy;
end;

procedure TWebserverSite.log(Level: TLoglevel; Msg: string);
begin
  dolog(Level, '['+FName+'] '+Msg);
end;

function IntToFilesize(Size: longword): string;

function Foo(A: longword): string;
var
  b: longword;
begin
  result:=IntToStr(Size div A);

  if a=1 then
    Exit;

  b:=(Size mod a)div (a div 1024);
  b:=(b*100) div 1024;

  if b<10 then
    result:=result+'.0'+IntToStr(b)
  else
    result:=result+'.'+IntTOStr(b);
end;

begin
  if Size<1024 then
    result:=Foo(1)+' B'
  else if Size < 1024*1024 then
    result:=Foo(1024) + ' kB'
  else if Size < 1024*1024*1024 then
    result:=Foo(1024*1024) + ' mB'
  else
    result:=Foo(102*1024*1024) + ' gB';
end;

procedure TWebserverSite.Rescan;
begin
  FParent.FCacheThread.QueueScan(Self);
  // dolog(llDebug, '['+FName+'] Got '+IntTostr(FFileCache.TotalFileCount)+' files with '+IntToFilesize(FFileCache.TotalFileSize)+' total, (compressed: '+IntToFileSize(FFileCache.TotalGZipFileSize)+')');
end;

procedure TWebserverSite.AddScriptDirectory(directory, filename: string);
var
  i: Integer;
begin
  i:=Length(FScriptDirs);
  Setlength(FScriptDirs, i+1);
  FScriptDirs[i].script:=filename;
  FScriptDirs[i].dir:=directory;
end;

procedure TWebserverSite.AddForward(target, NewTarget: string);
begin
  FForwards[target]:=NewTarget;
end;

procedure TWebserverSite.AddIndexPage(name: string);
var
  i: Integer;
begin
  i:=Length(FIndexNames);
  Setlength(FIndexNames, i+1);
  FIndexNames[i]:=name;
end;

function TWebserverSite.IsScriptDir(target: string; out Script, Params: string
  ): Boolean;
var
  i: Integer;
begin
  result:=False;
  for i:=0 to Length(FScriptDirs)-1 do
  if Pos(FScriptDirs[i].dir, target)>0 then
  begin
    result:=True;
    Script:=FScriptDirs[i].script;
    Params:=Copy(target, Length(FScriptDirs[i].dir), Length(Target));
    Exit;
  end;
end;

function TWebserverSite.IsForward(target: string; out NewTarget: string
  ): Boolean;
begin
  NewTarget:=FForwards[target];
  result:=NewTarget<>'';
end;

procedure TWebserverSite.AddResponseHeader(const name, value: ansistring);
var
  i: Integer;
  add:Boolean;
begin
  FCS.Enter;
  try
    add:=True;
    for i:=0 to Length(FResponseHeaders)-1 do
    if FResponseHeaders[i].name = name then
    begin
      if value='' then
      begin
        FResponseHeaders[i]:=FResponseHeaders[Length(FResponseHeaders)-1];
        Setlength(FResponseHeaders, Length(FResponseHeaders)-1);
      end else
        FResponseHeaders[i].value:=value;
      add:=False;
      Break;
    end;
    if add then
    begin
      i:=Length(FResponseHeaders);
      Setlength(FResponseHeaders, i+1);
      FResponseHeaders[i].name:=name;
      FResponseHeaders[i].value:=value;
    end;
  finally
    FCS.Leave;
  end;
end;

procedure TWebserverSite.AddFile(filename, content, fullpath: string);
begin
  FFileCache.AddFile(filename, content, fullpath);
end;

procedure TWebserverSite.AddHostAlias(HostName: string);
begin
  FParent.FHostsByName.Add(HostName, Self);
end;


procedure TWebserverSite.AddCustomHandler(url: string;
  Handler: TEpollWorkerThread);
begin
  FCustomHandlers.Add(url, Handler);
end;

procedure TWebserverSite.AddCustomStatusPage(StatusCode: Word; URI: string);
begin
  if (StatusCode>=CustomStatusPageMin)and
     (StatusCode<=CustomStatusPageMax) then
  FCustomStatusPages[StatusCode]:=URI;
end;

procedure TWebserverSite.AddCGI(urlPrefix, extension, binary,
  parameters: ansistring);
var
  i: Integer;
begin
  i:=Length(FExternalScriptTypes);
  Setlength(FExternalScriptTypes, i+1);
  FExternalScriptTypes[i].UrlPrefix:=urlPrefix;
  FExternalScriptTypes[i].Extension:=extension;
  FExternalScriptTypes[i].ParamA:=binary;
  FExternalScriptTypes[i].ParamB:=parameters;
  FExternalScriptTypes[i].ScriptType:=esCGI;
end;

procedure TWebserverSite.AddFastCGISocket(urlPrefix, extension, host,
  port: ansistring);
var
  i: Integer;
begin
  i:=Length(FExternalScriptTypes);
  Setlength(FExternalScriptTypes, i+1);
  FExternalScriptTypes[i].UrlPrefix:=urlPrefix;
  FExternalScriptTypes[i].Extension:=extension;
  FExternalScriptTypes[i].ParamA:=host;
  FExternalScriptTypes[i].ParamB:=port;
  FExternalScriptTypes[i].ScriptType:=esFastCGI;
end;

procedure TWebserverSite.ApplyResponseHeader(const Response: THTTPReply);
var
  i: Integer;
begin
  FCS.Enter;
  try
    for i:=0 to Length(FResponseHeaders)-1 do
      Response.header.Add(FResponseHeaders[i].name, FResponseHeaders[i].Value);
  finally
    FCS.Leave;
  end;
end;

procedure TWebserverSite.AddWhiteListProcess(const Executable: ansistring);
var
  i: Integer;
begin
  i:=Length(FWhitelistedProcesses);
  SetLength(FWhitelistedProcesses, i+1);
  FWhitelistedProcesses[i]:=Executable;
end;

function TWebserverSite.IsProcessWhitelisted(const Executable: ansistring
  ): Boolean;
var
  i: Integer;
begin
  result:=False;
  for i:=0 to Length(FWhitelistedProcesses)-1 do
  if FWhitelistedProcesses[i] = Executable then
  begin
    result:=True;
    Exit;
  end;
end;

function TWebserverSite.GetCustomStatusPage(StatusCode: Word): ansistring;
begin
  if (StatusCode>=CustomStatusPageMin)and
     (StatusCode<=CustomStatusPageMax) then
    result:=FCustomStatusPages[StatusCode]
  else
    result:='';
end;

function TWebserverSite.GetStore(const Location: string): string;
begin
  result:='';
  FCS.Enter;
  try
    result:=FStorage.Get(FName+'.'+Location);
  finally
    FCS.Leave;
  end;
end;

function TWebserverSite.PutStore(const Location, Data: string): Boolean;
begin
  result:=False;
  FCS.Enter;
  try
    FStorage.Put(FName+'.'+Location, Data);
    result:=True;
  finally
    FCS.Leave;
  end;
end;

function TWebserverSite.DelStore(const Location: string): Boolean;
begin
  result:=False;
  FCS.Enter;
  try
    FStorage.DeleteEntry(Location);
    result:=True;
  finally
    FCS.Leave;
  end;
end;

function TWebserverSite.GetCustomHandler(url: string): TEpollWorkerThread;
begin
  result:=TEpollWorkerThread(FCustomHandlers[url]);
end;

function TWebserverSite.GetIndexPage(var target: string): PFileCacheItem;
var
  i: Integer;
begin
  result:=nil;
  for i:=Length(FIndexNames)-1 downto 0 do
  begin
    result:=FFileCache.Find(target + FIndexNames[i]);
    if Assigned(result) then
    begin
      target:=target + FIndexNames[i];
      Exit;
    end;
  end;
end;

function TWebserverSite.IsExternalScript(url: string; Client: TEPollSocket
  ): Boolean;
var
  i, j: Integer;
begin
  result:=False;
  {$IFDEF CGISUPPORT}
  for i:=0 to Length(FExternalScriptTypes)-1 do
  begin
    if Length(FExternalScriptTypes[i].UrlPrefix)>Length(url) then
      Continue;
    for j:=1 to Length(FExternalScriptTypes[i].UrlPrefix) do
      if url[j] <> FExternalScriptTypes[i].UrlPrefix[j] then
        Continue;
    if Lowercase(ExtractFileExt(url)) = FExternalScriptTypes[i].Extension then
    begin
      case FExternalScriptTypes[i].ScriptType of
        esCGI: TWebserverCGIInstance.Create(Client.Parent, THTTPConnection(Client),
          FExternalScriptTypes[i].ParamA, FExternalScriptTypes[i].ParamB);
        esFastCGI: with TWebserverFastCGIInstance.Create(Client.Parent, THTTPConnection(Client),
          FExternalScriptTypes[i].ParamA, FExternalScriptTypes[i].ParamB) do
          if Broken then Free;
      end;
      result:=True;
      Exit;
    end;
  end;
  {$ENDIF}
end;

{ TWebserverSiteManager }

function TWebserverSiteManager.GetTotalFileCount: longword;
var
  i: Integer;
begin
  result:=0;
  for i:=0 to Length(FHosts)-1 do
    result:=result + FHosts[i].Files.TotalFileCount;
end;

function TWebserverSiteManager.GetTotalFileSize: longword;
var
  i: Integer;
begin
  result:=0;
  for i:=0 to Length(FHosts)-1 do
    result:=result + FHosts[i].Files.TotalFileSize;
end;

function TWebserverSiteManager.GetTotalGZipFileSize: longword;
var
  i: Integer;
begin
  result:=0;
  for i:=0 to Length(FHosts)-1 do
    result:=result + FHosts[i].Files.TotalGZipFileSize;
end;

procedure TWebserverSiteManager.HostNameDeleteIterator(Item: TObject;
  const Key: string; var Continue: Boolean);
begin
  if Item = FHostToDelete then
  begin
    Continue:=False;
    FHostToDelete:=nil;
    FHostsByName.Delete(key);
  end else
    Continue:=True;
end;

constructor TWebserverSiteManager.Create(const BasePath: ansistring);
begin
  FPath:=BasePath+'sites/';
  FSharedScriptsDir:=BasePath+'shared/scripts/';
  FSharedScripts:=TFileCache.Create;
  FSharedScripts.DoScan(FSharedScriptsDir, '/');
  FDefaultHost:=nil; //TWebserverSite.Create(Self, 'default');
  FCacheThread:=TFileCachingThread.Create;
  //Setlength(FHosts, 1);
  //FHosts[0]:=FDefaultHost;

  //if not FDefaultHost.Files.Exists('/index.html') then
  //  FDefaultHost.AddFile('/index.html', '<html><head><title>Nothing to see here</title></head><body>Default webserver string</body></html>');

  FHostsByName:=TFPObjectHashTable.Create(false);
end;

destructor TWebserverSiteManager.Destroy;
var
  i: Integer;
begin
  FCacheThread.Free;
  for i:=0 to Length(FHosts)-1 do
  begin
    FHosts[i].Free;
  end;
  Setlength(FHosts, 0);
  FHostsByName.Free;
  FSharedScripts.Free;
  inherited Destroy;
end;

procedure TWebserverSiteManager.RescanAll;
var
  i: Integer;
begin
  for i:=0 to Length(FHosts)-1 do
    FHosts[i].Rescan;
end;

procedure TWebserverSiteManager.ProcessTick;
var
  i: Integer;
begin
  for i:=0 to Length(FHosts)-1 do
    FHosts[i].Files.ProcessTick;
end;

function TWebserverSiteManager.UnloadSite(Path: string): Boolean;
var
  i: Integer;
begin
  result:=False;
  for i:=0 to Length(FHosts)-1 do
  if FHosts[i].FName = Path then
  begin
    if FDefaultHost = FHosts[i] then
      FDefaultHost:=nil;

    repeat
      FHostToDelete:=FHosts[i];
      FHostsByName.Iterate(HostNameDeleteIterator);
    until Assigned(FHostToDelete);
    FHostToDelete:=nil;

    FHosts[i].Free;
    FHosts[i]:=FHosts[Length(FHosts)-1];
    Setlength(FHosts, Length(FHosts)-1);
    Exit;
  end;
end;

function TWebserverSiteManager.AddSite(Path: string): TWebserverSite;
var
  i: Integer;
begin
  for i:=0 to Length(FHosts)-1 do
  if FHosts[i].FPath = Path then
  begin
    result:=FHosts[i];
    Exit;
  end;
  result:=TWebserverSite.Create(Self, Path);
  i:=Length(FHosts);
  Setlength(FHosts, i+1);
  FHosts[i]:=result;
  dolog(llNotice, 'Loaded site "'+Path+'"');
  // result.AddHostAlias(Hostname);
end;

function TWebserverSiteManager.GetSite(Hostname: string): TWebserverSite;
begin
  result:=TWebserverSite(FHostsByName[Hostname]);
  if not Assigned(result) then
    result:=FDefaultHost;
end;

end.

