unit besenwebscript;
{
 synchronous besen classes for page generation

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
  SysUtils,
  Classes,
  SyncObjs,
  {$i besenunits.inc},
  beseninstance,
  besenevents,
  webserverhosts,
  webserver;

type
  TBESENWebscript = class;

  { TBESENWebscriptHandler }

  TBESENWebscriptHandler = class(TBESENNativeObject)
  private
    FConnection: THTTPConnection;
    FParent: TBESENwebscript;
    FPageTexts: array of string;
    function GetHostname: string;
    function GetMimeType: TBESENString;
    function GetParameter: TBESENString;
    function GetReturnType: TBESENString;
    procedure SetMimeType(AValue: TBESENString);
    procedure SetReturnType(AValue: TBESENString);
  protected
    procedure InitializeObject; override;
  public
    function AddPageText(const PageText: ansistring): ansistring;
  published
    { used internally. text portions from the html/server-side-ecmascript file is replaced with this function }
    procedure _internalTextOut(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { print(...) - prints out arguments, without newline }
    procedure print(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { println(...) - prints out arguments, with newline }
    procedure println(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { getHeader(item) - returns item from the http request header (e.g. cookies) }
    procedure getHeader(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { setReplyHeader(item, value) - adds/updates a field in the http response header (e.g. cookies) }
    procedure setReplyHeader(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { readFile(filename) - returns contents for filename }
    procedure readFile(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { writeFile(filename, content) - overwrites filename IN CACHE. Modifications will NOT be saved on disk unless it is flushed }
    procedure writeFile(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { getPostData(field) - returns the postdata for the specified field }
    procedure getPostData(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { import(file) - same as <?import file ?> }
    procedure import(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { remote client ip }
    property host: string read GetHostname;
    { the mime type for the response. usually "text/html" }
    property mimeType: TBESENString read GetMimeType write SetMimeType;
    { the http response message. usually "200 OK" }
    property returnType: TBESENString read GetReturnType write SetReturnType;
    { the http request uri parameter }
    property parameter: TBESENString read GetParameter;
  end;

  { TBESENWebscript }

  TBESENWebscript = class
  private
    FInstance: TBESENInstance;
    FHandler: TBESENWebscriptHandler;
    FMimeType: TBESENString;
    FResult: TBESENString;
    FResultCode: TBESENString;
    FSite: TWebserverSite;
    FPath: ansistring;
    FClient: THTTPConnection;

  public
    constructor Create(Manager: TWebserverSiteManager; Site: TWebserverSite);
    destructor Destroy; override;
    function Execute(Path, Filename: ansistring; Client: THTTPConnection): Boolean;
    property Result: TBESENString read FResult write FResult;
    property MimeType: TBESENString read FMimeType write FMimeType;
    property ResultCode: TBESENString read FResultCode write FResultCode;
  end;


implementation

{ TBESENWebscriptHandler }

function TBESENWebscriptHandler.GetHostname: string;
begin
  result:=FConnection.GetRemoteIP;
end;

function TBESENWebscriptHandler.GetMimeType: TBESENString;
begin
  result:=FParent.MimeType;
end;

function TBESENWebscriptHandler.GetParameter: TBESENString;
begin
  result:=widestring(FConnection.Header.parameters);
end;

function TBESENWebscriptHandler.GetReturnType: TBESENString;
begin
  result:=FParent.ResultCode;
end;

procedure TBESENWebscriptHandler.SetMimeType(AValue: TBESENString);
begin
  FParent.MimeType:=AValue;
end;

procedure TBESENWebscriptHandler.SetReturnType(AValue: TBESENString);
begin
  FParent.ResultCode:=AValue;
end;

procedure TBESENWebscriptHandler.InitializeObject;
begin
  inherited InitializeObject;
end;

function TBESENWebscriptHandler.AddPageText(const PageText: ansistring): ansistring;
var
  i, j: Integer;
begin
  i:=Length(FPageTexts);
  Setlength(FPageTexts, i+1);
  FPageTexts[i]:=PageText;

  j:=0;
  result:='handler["_internalTextOut"]('+IntToStr(i)+');';

  // count number of lines and add them so in case of an error we get consistens line numbers
  for i:=1 to Length(PageText) do
   if PageText[i] = #10 then
     Inc(j);

  for i:=0 to j-1 do
    result:=result+#13#10;

end;

procedure TBESENWebscriptHandler._internalTextOut(
  const ThisArgument: TBESENValue; Arguments: PPBESENValues;
  CountArguments: integer; var ResultValue: TBESENValue);
var
  i: Integer;
begin
  ResultValue:=BESENUndefinedValue;
  if CountArguments<1 then
    exit;

  i:=TBESEN(Instance).ToInt(Arguments^[0]^);
  if(i>=0)and(i<Length(FPageTexts)) then
    FParent.Result:=FParent.Result + widestring(FPageTexts[i]);
end;

procedure TBESENWebscriptHandler.print(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  i: Integer;
begin
  for i:=0 to CountArguments-1 do
    FParent.FResult:=FParent.FResult + TBESEN(Instance).ToStr(Arguments^[i]^);
end;

procedure TBESENWebscriptHandler.println(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  i: Integer;
begin
  for i:=0 to CountArguments-1 do
    FParent.FResult:=FParent.FResult + TBESEN(Instance).ToStr(Arguments^[i]^);

  FParent.FResult:=FParent.FResult + #13#10;
end;

procedure TBESENWebscriptHandler.getHeader(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
begin
  ResultValue:=BESENUndefinedValue;
  if CountArguments>0 then
    if(Assigned(FConnection)) then
      ResultValue:=BESENStringValue(widestring(FConnection.Header.header[ansistring(TBESEN(Instance).ToStr(Arguments^[0]^))]));
end;

procedure TBESENWebscriptHandler.setReplyHeader(
  const ThisArgument: TBESENValue; Arguments: PPBESENValues;
  CountArguments: integer; var ResultValue: TBESENValue);
begin
  if CountArguments>1 then
    if(Assigned(FConnection)) then
      FConnection.Reply.header.Add(ansistring(TBESEN(Instance).ToStr(Arguments^[0]^)), ansistring(TBESEN(Instance).ToStr(Arguments^[1]^)));
end;

procedure TBESENWebscriptHandler.readFile(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  s: string;
  gzip: Boolean;
begin
  if CountArguments<1 then
    Exit;

  s:='';
  gzip:=False;
  FParent.FSite.Files.GetFile(FParent.FPath + ansistring(TBESEN(Instance).ToStr(Arguments^[0]^)), s, gzip);
  ResultValue:=BESENStringValue(BESENUTF8ToUTF16(s));
end;

procedure TBESENWebscriptHandler.writeFile(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  s: string;
begin
  if CountArguments<2 then
    Exit;

  s:=FParent.FPath + ansistring(TBESEN(Instance).ToStr(Arguments^[0]^));

  FParent.FSite.Files.AddFile(s, BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[1]^)), FParent.FSite.Path+'web'+s);

end;

procedure TBESENWebscriptHandler.getPostData(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
begin
  ResultValue:=BESENUndefinedValue;

  if CountArguments<1 then
    Exit;

  if Assigned(FConnection) then
  begin
    ResultValue:=BESENStringValue(BESENUTF8ToUTF16(FConnection.Header.POSTData.Entities[BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments[0]^))]));
  end;
end;

procedure TBESENWebscriptHandler.import(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
begin
  if CountArguments>0 then
    FParent.Execute(FParent.FPath, BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[0]^)), FParent.FClient);
end;

{ TBESENWebscript }

constructor TBESENWebscript.Create(Manager: TWebserverSiteManager;
  Site: TWebserverSite);
begin
  FSite:=Site;
  if Assigned(FSite) then
    FInstance:=TBESENInstance.Create(Manager, FSite)
  else
    FInstance:=TBESENInstance.Create(Manager, nil);
  FResult:='';
  FResultCode:='200 OK';
  FMimeType:='text/html';

end;

destructor TBESENWebscript.Destroy;
begin
  if Assigned(FHandler) then
    FInstance.GarbageCollector.UnProtect(TBESENObject(FHandler));
  FInstance.Free;
  inherited Destroy;
end;


const startTag = '<?besen';
const importTag = '<?import';
const stopTag = '?>';

function TBESENWebscript.Execute(Path, Filename: ansistring;
  Client: THTTPConnection): Boolean;
var
  i, j, k, lastfile: Integer;
  content, script, temp: string;
  gzip: Boolean;
begin
  result:=False;

  FClient:=Client;
  FPath:=Path;

  gzip:=False;
  content:='';

  if (Length(Path)>0)and(Path[Length(Path)]='/') then
    temp:=Path + filename
  else
    temp:=Path + '/' + filename;

  if FSite.Files.GetFile(temp, content, gzip)<=0 then
    Exit;

  result:=True;

  if not Assigned(FHandler) then
  begin
    FHandler:=TBESENWebscriptHandler.Create(FInstance);
    FHandler.FConnection:=Client;
    FHandler.FParent:=Self;
    FHandler.InitializeObject;
    FInstance.GarbageCollector.Protect(TBESENObject(FHandler));
  end;

  FHandler.FConnection:=Client;
  FHandler.FParent:=Self;

  FInstance.ObjectGlobal.put('handler', BESENObjectValue(FHandler), false);
  FInstance.ObjectGlobal.put('page', BESENObjectValue(FHandler), false);

  script:='';
  i := pos(StartTag, content)-1;
  j := pos(ImportTag, content)-1;
  FInstance.SetFilename(Filename);
  while (i>=0)or(j>=0) do
  begin
    if(j>=0)and((j<i)or(i<0)) then
    begin
      script:=script + FHandler.AddPageText(Copy(content, 1, j));
      Delete(content, 1, j + Length(ImportTag))
    end else
    begin
      script:=script + FHandler.AddPageText(Copy(content, 1, i));
      Delete(content, 1, i + Length(StartTag));
    end;

    k := pos(StopTag, content)-1;
    if k>=0 then
    begin
      temp := Copy(content, 1, k);
      Delete(content, 1, k + Length(StopTag));
    end else
    begin
      temp := content;
      content := '';
    end;

    if(j>=0)and((j<i)or(i<0)) then
      try
        if script<>'' then
        begin
          FInstance.Execute(script);
          script:='';
        end;
        lastfile:=FInstance.CurrentFile;
        Execute(Path, trim(temp), Client);
        FInstance.CurrentFile:=lastfile;
      except
        on e: Exception do
        begin
          FResult:=FResult + ' error';
          FInstance.OutputException(e, 'webscript');
        end;
      end
    else
      script:=script + temp;

    i := pos(StartTag, content) - 1;
    j := pos(ImportTag, content) - 1;
  end;
  if Length(content)>0 then
  begin
    script:=script + FHandler.AddPageText(content);
  end;
  if script<>'' then
  try
    FInstance.Execute(Script);
  except
    on e: Exception do
    begin
      FInstance.OutputException(e, 'webscript');
    end;
  end;
end;


end.

