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
  datautils,
  jsonstore,
  logging;

const
  CustomStatusPageMin = 400;
  CustomStatusPageMax = 511;

type
  TWebserverSiteManager = class;

  //TObjectIteratorMethod
  { TWebserverSite }

  TWebserverSite = class
  private
    FCS: TCriticalSection;
    FStorage: TJSONStore;
    FName, FPath: string;
    FParent: TWebserverSiteManager;
    FFileCache: TFileCache;
    FCustomHandlers: THashtable;
    FScriptDirs: array of record
      dir: string;
      script: string;
    end;
    FForwards: TStringHashtable;
    FCustomStatusPages: array[CustomStatusPageMin..CustomStatusPageMax] of ansistring;
    procedure ClearItem(Key: KString; Data: Pointer; var Continue: Boolean);
  public
    constructor Create(Parent: TWebserverSiteManager; Path: ansistring);
    destructor Destroy; override;
    procedure log(Level: TLoglevel; Msg: string);
    procedure Rescan;
    procedure AddScriptDirectory(directory, filename: string);
    procedure AddForward(target, NewTarget: string);
    function IsScriptDir(target: string; out Script, Params: string): Boolean;
    function IsForward(target: string; out NewTarget: string): Boolean;
    procedure AddFile(filename, content, fullpath: string);
    procedure AddHostAlias(HostName: string);
    procedure AddCustomHandler(url: string; Handler: Pointer);
    procedure AddCustomStatusPage(StatusCode: Word; URI: string);
    function GetCustomStatusPage(StatusCode: Word): ansistring;
    function GetStore(const Location: string): string;
    function PutStore(const Location, Data: string): Boolean;
    function DelStore(const Location: string): Boolean;
    function GetCustomHandler(url: string): Pointer;
    property Files: TFileCache read FFileCache;
    property Path: string read FPath;
    property Name: string read FName;
    property Parent: TWebserverSiteManager read FParent;
  end;

  { TWebserverSiteManager }

  TWebserverSiteManager = class
  private
    FDefaultHost: TWebserverSite;
    FHosts: array of TWebserverSite;
    FHostsByName: THashTable;
    FPath: ansistring;
    FSharedScripts: TFileCache;
    FSharedScriptsDir: ansiString;
    function GetTotalFileCount: longword;
    function GetTotalFileSize: longword;
    function GetTotalGZipFileSize: longword;
  public
    constructor Create;
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

{ TWebserverSite }

procedure TWebserverSite.ClearItem(Key: KString; Data: Pointer;
  var Continue: Boolean);
begin
  TOBject(Data).free;
end;

constructor TWebserverSite.Create(Parent: TWebserverSiteManager;
  Path: ansistring);
begin
  FCS:=TCriticalSection.Create;
  FStorage:=TJSONStore.Create;
  FForwards:=TStringHashtable.Create;
  FFileCache:=TFileCache.Create;
  FCustomHandlers:=THashtable.Create;

  FParent:=Parent;
  FName:=Path;
  FPath:=FParent.Path+Path+'/';

  FStorage.Put(FName, FileToStr(FPath+'storage.json'));
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
  FFileCache.DoScan(FPath+'web','/');
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

procedure TWebserverSite.AddFile(filename, content, fullpath: string);
begin
  FFileCache.AddFile(filename, content, fullpath);
end;

procedure TWebserverSite.AddHostAlias(HostName: string);
begin
  FParent.FHostsByName.Add(HostName, Self);
end;


procedure TWebserverSite.AddCustomHandler(url: string; Handler: Pointer);
begin
  FCustomHandlers.Add(url, Handler);
end;

procedure TWebserverSite.AddCustomStatusPage(StatusCode: Word; URI: string);
begin
  if (StatusCode>=CustomStatusPageMin)and
     (StatusCode<=CustomStatusPageMax) then
  FCustomStatusPages[StatusCode]:=URI;
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

function TWebserverSite.GetCustomHandler(url: string): Pointer;
begin
  result:=FCustomHandlers[url];
end;

{ TWebserverSiteManager }

function TWebserverSiteManager.GetTotalFileCount: longword;
var
  i: longword;
begin
  result:=0;
  for i:=0 to Length(FHosts)-1 do
    result:=result + FHosts[i].Files.TotalFileCount;
end;

function TWebserverSiteManager.GetTotalFileSize: longword;
var
  i: longword;
begin
  result:=0;
  for i:=0 to Length(FHosts)-1 do
    result:=result + FHosts[i].Files.TotalFileSize;
end;

function TWebserverSiteManager.GetTotalGZipFileSize: longword;
var
  i: longword;
begin
  result:=0;
  for i:=0 to Length(FHosts)-1 do
    result:=result + FHosts[i].Files.TotalGZipFileSize;
end;

constructor TWebserverSiteManager.Create;
begin
  FPath:=ExtractFilePath(Paramstr(0))+'sites/';
  FSharedScriptsDir:=ExtractFilePath(Paramstr(0))+'shared/scripts/';
  FSharedScripts:=TFileCache.Create;
  FSharedScripts.DoScan(FSharedScriptsDir, '/');
  FDefaultHost:=nil; //TWebserverSite.Create(Self, 'default');
  //Setlength(FHosts, 1);
  //FHosts[0]:=FDefaultHost;

  //if not FDefaultHost.Files.Exists('/index.html') then
  //  FDefaultHost.AddFile('/index.html', '<html><head><title>Nothing to see here</title></head><body>Default webserver string</body></html>');

  FHostsByName:=THashtable.Create;
end;

destructor TWebserverSiteManager.Destroy;
var
  i: Integer;
begin
  for i:=0 to Length(FHosts)-1 do
    FHosts[i].Free;
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
  p: Pointer;
  s: string;
begin
  result:=False;
  for i:=0 to Length(FHosts)-1 do
  if FHosts[i].FName = Path then
  begin
    if FDefaultHost = FHosts[i] then
      FDefaultHost:=nil;

    FHostsByName.First;
    while FHostsByName.GetNext(s, p) do
      if p = FHosts[i] then
      begin
        FHostsByName.DeleteKey(s);
        FHostsByName.First;
      end;

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
  i:=Length(FHosts);
  Setlength(FHosts, i+1);
  result:=TWebserverSite.Create(Self, Path);
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

