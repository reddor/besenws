unit mimehelper;
{
 simple functions to determine a file's mime type.

 Todo:
   OverwriteMimeType should be threadsafe!

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

function GetFileMIMEType(const FileName: String): String;
procedure OverwriteMimeType(FileExt: string; const NewType: string);

implementation

uses
  SysUtils,
  contnrs;

var
  MimeTypes: TFPStringHashTable;

procedure OverwriteMimeType(FileExt: string; const NewType: string);
begin
  if Pos('.', FileExt)=1 then
    delete(FileExt, 1, 1);
  MimeTypes.Items[FileExt]:=NewType;
end;

function GetFileMIMEType(const FileName: String): String;
var
  ext: String;
begin
  ext:=ExtractFileExt(FileName);
  if Pos('.', ext)=1 then
    delete(ext, 1, 1);

  ext:=lowercase(ext);
  Result := MimeTypes.Items[ext];
end;

procedure ReadMimeTypes;
var
  t: Textfile;
  s, a, b: string;
  i: Integer;
begin
  Assignfile(t, '/etc/mime.types');
  {$I-}Reset(t);{$I+}
  if ioresult=0 then
  begin
    while not eof(t) do
    begin
      readln(t, s);
      if Length(s)>0 then
       if s[1]<>'#' then
       begin
         i:=1;
         while (i<=Length(s))and(s[i]<>#9)and(s[i]<>' ') do
           inc(i);
         a:=trim(Copy(s, 1, i));
         b:=trim(Copy(s, i+1, length(s)));
         if (a<>'')and(b<>'') then
         begin
           while pos(' ', b)>0 do
           begin
             s:=Trim(copy(b, 1, pos(' ', b)));
             Delete(b, 1, Length(s)+1);
             MimeTypes[s]:=a;
           end;
           MimeTypes[lowercase(b)]:=a;
         end;
       end;
    end;

    Closefile(t);
  end;
end;

initialization
  MimeTypes:=TFPStringHashTable.Create;
  try
    ReadMimeTypes;
  except

  end;
finalization
  MimeTypes.Free;
end.
 
