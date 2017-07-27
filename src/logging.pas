unit logging;
{
 the most simplistic logging system

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
  Classes, SysUtils, SyncObjs, dateutils, Variants;

type
  TLoglevel = (llDebug=0, llNotice=1, llWarning=2, llError=3, llFatal=4);
  TLogItems = array of Variant;

var
  GlobalLogLevel: TLoglevel;

procedure dolog(LogLevel: TLogLevel; const Message: TLogItems); overload;
procedure dolog(Loglevel: TLoglevel; msg: ansistring); overload;
procedure LogToFile(filename: string);

implementation

var CS: TCriticalSection;

var
  FileHandle: Textfile;
  DoLogToFile: Boolean;

procedure LogToFile(filename: string);
begin
  Assignfile(Filehandle, filename);
  rewrite(Filehandle);
  DoLogToFile:=True;
end;

procedure dolog(LogLevel: TLogLevel; const Message: TLogItems);
var
  i: Integer;
begin
  if LogLevel<GlobalLogLevel then
    Exit;

  Write('[', TimeToStr(Time),'] ');
  case LogLevel of
    llDebug:   Write('  [Debug] ');
    llNotice:  Write(' [Notice] ');
    llWarning: Write('[Warning] ');
    llError:   Write('  [Error] ');
    llFatal:   Write('  [Fatal] ');
  end;
  for i:=Low(Message) to High(Message) do
    Write(Message[i]);
  Writeln;
end;

procedure dolog(Loglevel: TLoglevel; msg: ansistring);
var
  s:ansistring;
begin
  if LogLevel<GlobalLogLevel then
    Exit;
  case Loglevel of
    llDebug:   s:='['+TimeToStr(Time)+']   [Debug] '+msg;
    llNotice:  s:='['+TimeToStr(Time)+']  [Notice] '+msg;
    llWarning: s:='['+TimeToStr(Time)+'] [Warning] '+msg;
    llError:   s:='['+TimeToStr(Time)+']   [Error] '+msg;
    llFatal:   s:='['+TimeToStr(Time)+']   [Fatal] '+msg;
    else
               s:='['+TimeToStr(Time)+'] [???????] '+msg;
  end;
  CS.Enter;
  if DoLogToFile then
  begin
    Writeln(Filehandle, s);
    Flush(Filehandle);
  end else
    Writeln(StdOut, s);

  CS.Leave;
end;

initialization
  GlobalLogLevel:=llDebug;
  DoLogToFile:=False;
  CS:=TCriticalSection.Create;
finalization
  CS.Free;
end.
