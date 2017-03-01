unit filecache;
{
 a simple file cache

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
  DateUtils,
  datautils,
  logging;

type
  PFileCacheItem = ^TFileCacheItem;
  TFileCacheItem = record
    Filename: shortstring;
    mimetype: string[64];
    Locked: Boolean;
    Filelength: Integer;
    Filedata: Pointer;
    GZiplength: Integer;
    Gzipdata: Pointer;
    LastModifiedTick: Integer;
    LastModified: TDateTime;
    CacheLength: Integer;
    RefCount: Integer;
  end;

  { TFileCache }

  TFileCache = class
  private
    FAutoUpdate: Boolean;
    FCS: TCriticalSection;
    FFileCount: longword;
    FGZipFileSize: longword;
    FFileSize: longword;
    FFiles: THashtable;
    FTicks: Integer;
    FBaseDir: ansistring;
    function AddItem(Name: ansistring): PFileCacheItem;
    procedure ClearItem(Item: Pointer);
    procedure ReadFile(p: PFileCacheItem; Filename: string); overload;
    function ReadFile(URL, Filename: string): PFileCacheItem; overload;
    procedure CompressItem(p: PFileCacheItem);
    procedure Scan(const Dir, BaseDir: ansistring);

    procedure ReloadFileIfChanged(var p: PFileCacheItem; target: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure ProcessTick;
    procedure DoScan(const Dir, BaseDir: ansistring);
    procedure AddSymlink(source, dest: ansistring);
    function Exists(target: ansistring): Boolean;
    function Find(target: ansistring): PFileCacheItem;
    function Release(Item: PFileCacheItem): Boolean;
    procedure AddFile(target: ansistring; const data, filename: ansistring);
    function GetFile(target: ansistring; var data: ansistring; var GZip: Boolean; RangeStart: Integer = 0; RangeEnd: Integer = -1): Integer;
    procedure WriteFile(target: ansistring);

    property AutoUpdate: Boolean read FAutoUpdate write FAutoUpdate;
    property TotalFileSize: Longword read FFileSize;
    property TotalGZipFileSize: Longword read FGZipFileSize;
    property TotalFileCount: Longword read FFileCount;
  end;

implementation

uses
  zlib,
  mimehelper,
  httphelper;
{ TFileCache }

function TFileCache.AddItem(Name: ansistring): PFileCacheItem;
var
  p: PFileCacheItem;
  i: Integer;
begin
  FCS.Enter;
  try
    p:=PFileCacheItem(FFiles[Name]);
    if Assigned(p) then
    begin
      i:=0;
      p^.Locked:=True;
      // FCS.Leave;
      try
        while p^.RefCount>0 do
        begin
          if i=0 then
            dolog(llDebug, 'Waiting for '+IntToStr(p^.RefCount)+' file references...');
          Sleep(5);
          inc(i);
          if i>200 then
          begin
            dolog(llError, 'File reference wait timeout in '+p^.Filename);
            result:=nil;
            Exit;
          end;
        end;
      finally
        // FCS.Enter;
      end;
      if Assigned(p^.Filedata) then
        Freemem(p^.Filedata);
      if Assigned(p^.Gzipdata) then
        Freemem(p^.Gzipdata);

      FFileSize:=FFileSize - p^.Filelength;
      FGZipFileSize:=FGZipFileSize - p^.GZiplength;

      p^.Gzipdata:=nil;
      p^.Filedata:=nil;
      p^.GZiplength:=0;
      p^.Filelength:=0;
      p^.RefCount:=0;
      p^.LastModifiedTick:=FTicks;
    end else
    begin
      inc(FFileCount);
      GetMem(p, SizeOf(TFileCacheItem));
      FillChar(p^, sizeof(TFileCacheItem), #0);
      p^.Locked:=True;
      FFiles[Name]:=p;
    end;
  finally
    FCS.Leave;
  end;
  result:=p;
end;

procedure TFileCache.ClearItem(Item: Pointer);
var
  p: PFileCacheItem;
begin
  p:=PFileCacheItem(Item);
  if Assigned(p) then
  begin
    begin
      p.Filename:='';
      p.Filelength:=0;
      p.GZiplength:=0;
      if Assigned(p.Filedata) then
        FreeMem(p.Filedata);
      if Assigned(p.Gzipdata) then
        FreeMem(p^.GZipdata);
      FreeMem(p);
    end;
  end;
end;

procedure TFileCache.ReadFile(p: PFileCacheItem; Filename: string);
var
  f: File;
begin
  if Assigned(p^.Filedata) then
    dolog(llDebug, 'Memory leak in TFileCache.ReadFile!');
  Assignfile(f, Filename);
  {$i-}Reset(f, 1);{$i+}
  if ioresult = 0 then
  begin
    p^.mimetype:=GetFileMIMEType(Filename);
    p^.Filelength:=Filesize(f);
    p^.LastModified:=RecodeMilliSecond(FileLastModified(Filename), 0);
    p^.CacheLength:=60*60*24*30;

    try
      GetMem(p^.Filedata, p^.Filelength);
      BlockRead(f, p^.Filedata^, p^.Filelength);
    finally
      Closefile(f);
    end;

    FFileSize:=FFileSize + p^.Filelength;
  end;
end;

function TFileCache.ReadFile(URL, Filename: string): PFileCacheItem;
var
  f: File;
begin
  result:=nil;
  Assignfile(f, Filename);
  {$i-}Reset(f, 1);{$i+}
  if ioresult = 0 then
  begin
    result:=AddItem(URL);
    if not Assigned(result) then
    begin
      Closefile(f);
      Exit;
    end;
    if Assigned(result^.Filedata) then
      dolog(llDebug, 'Memory leak in TFileCache.ReadFile!');

    result^.mimetype:=GetFileMIMEType(Filename);
    result^.Filelength:=Filesize(f);
    result^.LastModified:=RecodeMilliSecond(FileLastModified(Filename), 0);
    result^.CacheLength:=60*60*24*30;
    result^.Filename:=Filename;

    try
      GetMem(result^.Filedata, result^.Filelength);
      BlockRead(f, result^.Filedata^, result^.Filelength);
    finally
      Closefile(f);
    end;
    CompressItem(result);
    FFileSize:=FFileSize + result^.Filelength;
  end;
end;

procedure TFileCache.CompressItem(p: PFileCacheItem);
var
  c: cardinal;
  foo: z_stream;
  i: Integer;
begin
  if Assigned(p^.Gzipdata) then
    dolog(llDebug, 'Memory leak in TFileCache.CompressItem!');

  c := p^.Filelength + p^.Filelength div 100 + 64;
  GetMem(P.Gzipdata, c);

  Fillchar(foo, Sizeof(foo), #0);

  foo.next_out:=P^.Gzipdata;
  foo.avail_out:=c;

  deflateInit2(foo, 9, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY);
  foo.next_in:=p^.Filedata;
  foo.avail_in:=p^.Filelength;
  repeat
    i := deflate(foo, Z_FINISH);
  until (i=Z_STREAM_END);
  deflateEnd(foo);
  ReallocMem(P.GZipdata, foo.total_out);
  c:=foo.total_out;
  P.GZiplength:=foo.total_out;

  FGZipFileSize:=FGZipFileSize + p^.GZiplength;
end;

constructor TFileCache.Create;
begin
  FCS:=TCriticalSection.Create;
  FFiles:=THashtable.Create;
  FFileCount:=0;
  FFileSize:=0;
  FAutoUpdate:=True;
end;

destructor TFileCache.Destroy;
var
  Hash: kstring;
  p: Pointer;
begin
  FFiles.First;
  while FFiles.GetNext(Hash, p) do
  begin
    ClearItem(p);
  end;
  FCS.Free;
  FFiles.Free;
  inherited Destroy;
end;

procedure TFileCache.ProcessTick;
begin
  inc(FTicks);
end;

procedure TFileCache.DoScan(const Dir, BaseDir: ansistring);
begin
  //FCS.Enter;
  try
    FBaseDir:=Dir;
    Scan(Dir, BaseDir);
  finally
    //FCS.Leave;
  end;
end;

procedure TFileCache.Scan(const Dir, BaseDir: ansistring);
var
  i: Integer;
  sr: TSearchRec;
  p: PFileCacheItem;
  fullpath, fakepath, basePath: ansistring;
begin
  i:=FindFirst(dir+'/*', faAnyFile, sr);
  while i=0 do
  begin
    fullpath:=dir+'/'+sr.name;
    fakepath:=basedir+sr.Name;
    basepath:=fakepath+'/';
    if sr.Attr and faDirectory<>0 then
    begin
      if (sr.Name<>'.')and(sr.Name<>'..') then
      begin
        p:=AddItem(fakepath);
        p.Filelength:=-1;
        p^.Locked:=False;
        Scan(fullpath, basepath);
      end;
    end else
    begin
      p:=FFiles[fakepath];

      if (not Assigned(p)) or (p.LastModified <> RecodeMilliSecond(FileLastModified(fullpath), 0)) then
      begin
        p:=ReadFile(fakepath, fullpath);
        if Assigned(p) then
          p^.Locked:=False;
      end;
    end;
    i:=FindNext(sr);
  end;
  FindClose(sr);
  fullpath:='';
  fakepath:='';
  basepath:='';
end;

procedure TFileCache.ReloadFileIfChanged(var p: PFileCacheItem; target: string);
var
  p2: PFileCacheItem;
  t: TDateTime;
begin
  if not FAutoUpdate then
    Exit;

  if Not Assigned(p) then
  begin
    //if FileExists(FileName) then
    //  ; //ReadFile(URL, Filename) // url to filename D:
    //else
    //dolog(llDebug, 'File does not exist: '+target);
  end else
  begin
    if p^.LastModified <> 0 then
    if p^.LastModifiedTick<>FTicks then
    begin
      if not FileExistsAndAge(p^.Filename, t) then
      begin
        // file was removed
        FFiles.DeleteKey(p^.Filename);
        ClearItem(p);
        p:=nil;
      end else
      if p^.LastModified <> RecodeMilliSecond(t, 0) then
      begin
        //dolog(llDebug, target+' is modified');
        FCS.Leave;
        p2:=p;
        try
          p:=ReadFile(target, p^.Filename);
        finally
          FCS.Enter;
        end;
        if Assigned(p) then
          p^.Locked:=False
        else
          p:=p2;
      end;
      if Assigned(p) then
        P^.LastModifiedTick:=FTicks;
    end;
  end;
end;

procedure TFileCache.AddSymlink(source, dest: ansistring);
begin
  FCS.Enter;
  try
    if Assigned(FFiles[dest]) then
      Exit;
    FFiles[dest]:=FFiles[source];
  finally
    FCS.Leave;
  end;
end;

function TFileCache.Exists(target: ansistring): Boolean;
begin
  result:=Assigned(FFiles[target]);
end;

function TFileCache.Find(target: ansistring): PFileCacheItem;
var
  s: ansistring;
begin
  FCS.Enter;
  try
    result:=FFiles[target];
    if Assigned(result) then
    begin
      if result.Locked then
        result:=nil
      else
      begin
        ReloadFileIfChanged(result, target);
        if Assigned(result) then
          InterlockedIncrement(result.RefCount);
      end;
    end else
    begin
      if AutoUpdate then
      begin
        if URLPathToAbsolutePath(target, FBaseDir, s) then
        begin
          result:=ReadFile(target, s);
          if Assigned(result) then
            result.Locked:=False;
        end;
      end;
    end;
  finally
    FCS.Leave;
  end;
end;

function TFileCache.Release(Item: PFileCacheItem): Boolean;
begin
  result:=InterLockedDecrement(Item^.RefCount)>=0;
end;

procedure TFileCache.AddFile(target: ansistring; const data,
  filename: ansistring);
var
  p: PFileCacheItem;
begin
  FCS.Enter;
  try
    p:=AddItem(target);
    if not Assigned(p) then
      Exit;

    p^.Filename:=filename;
    p^.Filelength:=Length(Data);
    Getmem(p^.Filedata, p^.Filelength);
    Move(data[1], p^.Filedata^, Length(data));
    CompressItem(p);
    p^.Locked:=False;
  finally
    FCS.Leave;
  end;
end;

function TFileCache.GetFile(target: ansistring; var data: ansistring;
  var GZip: Boolean; RangeStart: Integer; RangeEnd: Integer): Integer;
var
  p: PFileCacheItem;
  l: Integer;
  d: Pointer;
begin
  FCS.Enter;
  try
    p:=FFiles[target];
    ReloadFileIfChanged(p, target);

    if not Assigned(p) then
    begin
      result:=-1;
    end else
    begin
      if GZip then
       if not Assigned(p.Gzipdata) then
        GZip:=False;

      if GZip then
      begin
        d:=p.Gzipdata;
        l:=p.GZiplength;
      end else
      begin
        d:=p.Filedata;
        l:=p.Filelength;
      end;
      if l = 0 then
      begin
        result:=-1;
        data:='';
      end else
      begin
        if RangeEnd=-1 then
          RangeEnd:=l;
        if RangeStart>=l then
          RangeStart:=l-1;
        if RangeStart+RangeEnd>l then
          RangeEnd:=l - RangeStart;
        result:=RangeEnd - RangeStart;
        Setlength(data, result);
        Move(PByteArray(d)[RangeStart], data[1], result);
      end;
    end;
  finally
    FCS.Leave;
  end;
end;

procedure TFileCache.WriteFile(target: ansistring);
var
  p: PFileCacheItem;
  f: File;
begin
  FCS.Enter;
  try
    p:=FFiles[target];
    if (not Assigned(p)) then
    begin
      // dolog(llDebug, 'file '+target+' does not exist');
    end else
    // if (p^.LastModified = 0) then
    if p^.Filename<>'' then
    begin
      Assignfile(f, p^.Filename);
      Rewrite(f, 1);
      try
        Blockwrite(f, p^.Filedata^, p^.Filelength);
      finally
        Closefile(f);
      end;
      p^.LastModified:=RecodeMilliSecond(FileLastModified(p^.Filename), 0)
    end;
  finally
    FCS.Leave;
  end;
end;

end.

