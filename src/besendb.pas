unit besendb;

{$mode delphi}

interface

uses
  Classes,
  SysUtils,
  syncobjs,
  {$i besenunits.inc},
  beseninstance,
  epollsockets,
  db,
  sqldb,
  mysql57dyn,
  mysql57conn,
  BufDataset;

type
  TDatabaseType = (dtMySql, dtMSSql);
  TDatabaseConnectionState = (dcUninitialized, dcInitialized, dcConnected, dcQuery, dcPrepare, dcPrepareExecute);
  TDatabaseErrorEvent = procedure(ErrorMsg: ansistring) of object;
  TBESENDatabaseConnection = class;

  { TDatabaseConnection }

  TDatabaseConnection = class
  private
    FOnError: TDatabaseErrorEvent;
    FQuery: TSQLQuery;
    FConnection: TSQLConnection;
    FTransaction: TSQLTransaction;
    FState: TDatabaseConnectionState;
    FLastError: ansistring;

    function GetFieldCount: Integer;
    function GetFields: TFields;
    function GetRecordCount: Integer;
    function GetRowsAffected: Integer;
    procedure LogEvent(Sender : TSQLConnection; EventType : TDBEventType; Const Msg : String);
    procedure UpdateErrorEvent(Sender: TObject; DataSet: TCustomBufDataset; E: EUpdateError;
    UpdateKind: TUpdateKind; var Response: TResolverResponse);
    procedure CalcFieldsEvent(DataSet: TDataSet);
    procedure DeleteErrorEvent(DataSet: TDataSet; E: EDatabaseError;
    var DataAction: TDataAction);
    procedure EditErrorEvent(DataSet: TDataSet; E: EDatabaseError;
    var DataAction: TDataAction);
    procedure FilterRecordEvent(DataSet: TDataSet;
    var Accept: Boolean);
    procedure NewRecordEvent(DataSet: TDataSet);
    procedure PostErrorEvent(DataSet: TDataSet; E: EDatabaseError;
    var DataAction: TDataAction);

    procedure HandleException(e: Exception);
  public
    constructor Create;
    destructor Destroy; override;

    function Initialize(AKind: TDatabaseType): Boolean;
    function Connect(server, user, password, database: ansistring): Boolean;
    function Close: Boolean;
    function Query(QueryString: ansistring): Boolean;
    function Prepare(QueryString: ansistring): Boolean;
    function Execute: Boolean;
    procedure SetValue(ParamName: ansistring; Value: Variant);

    property Fields: TFields read GetFields;
    property FieldCount: Integer read GetFieldCount;
    property RecordCount: Integer read GetRecordCount;
    property RowsAffected: Integer read GetRowsAffected;
    property onError: TDatabaseErrorEvent read FOnError write FOnError;
  end;

  { TBESENDatabaseThread }

  TDatabaseThreadAction = (taNone, taConnect, taQuery, taPrepare, taExecute);

  TBESENDatabaseThread = class(TThread)
  private
    FEvent: PRTLEvent;
    FIsReady: Boolean;
    FWorkThread: TEpollWorkerThread;
    FParent: TBESENDatabaseConnection;
    FConnection: TDatabaseConnection;
    FAction: TDatabaseThreadAction;
    FServer, FUser, FPassword, FDatabase, FQuery: ansistring;
  protected
    procedure Execute; override;
  public
    constructor Create(Connection: TDatabaseConnection);
    destructor Destroy; override;
    function Connect(const AServer, AUser, APassword, ADatabase: ansistring): Boolean;
    function Query(const AQuery: ansistring): Boolean;
    function Prepare(const AQuery: ansistring): Boolean;
    function ExecuteQuery: Boolean;

    property IsReady: Boolean read FIsReady;
  end;

  { TBESENDatabaseRecord }

  TBESENDatabaseRecord = class(TBESENNativeObject)
  protected
    procedure InitializeObject; override;
  end;

  { TBESENDatabaseConnection }

  TBESENDatabaseConnection = class(TBESENNativeObject)
  private
    FWorkThread: TEpollWorkerThread;
    FThread: TBESENDatabaseThread;
    FConnection: TDatabaseConnection;
    FSuccessProc,
    FFailProc: TBESENObjectFunction;
    function GetErrorMessage: TBESENString;
    function GetFieldCount: Integer;
    function GetRecordCount: Integer;
    procedure Spinlock;
    procedure UnprotectCallbacks;
  protected
    procedure Success;
    procedure Fail;
    procedure ConstructObject(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer); override;
    procedure FinalizeObject; override;
  public
    destructor Destroy; override;
  published
    { connect(host, username, password, database, callbackSuccess, callbackFail) - connect to database }
    procedure connect(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { query(querystring, callbackSuccess, callbackFail) - raw query }
    procedure query(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { prepare(querystring, callbackSuccess, callbackFail) - raw query }
    procedure prepare(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    (* execute({json:values}, callbackSuccess, callbackFail) - execute prepared statement *)
    procedure execute(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { getRecord(callback) - get entry of record }
    procedure getNextRecord(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);
    { getFieldName(index) - get name of field }
    procedure getFieldName(const ThisArgument:TBESENValue;Arguments:PPBESENValues;CountArguments:integer;var ResultValue:TBESENValue);

    property recordCount: Integer read GetRecordCount;
    property fieldCount: Integer read GetFieldCount;
    property errorMessage: TBESENString read GetErrorMessage;
  end;

implementation

{ unloading & loading the mysql libs seems to cause a crash, this workaround
  prevents unloading the shared object. couldn't reproduce this in a standalone project :( }
{$define MySQLWorkAround}

uses
  logging;

{$ifdef MySQLWorkAround}
var
  MySQLWorkAround: Boolean;
{$endif}

{ TBESENDatabaseRecord }

procedure TBESENDatabaseRecord.InitializeObject;
begin
  inherited InitializeObject;
end;

{ TBESENDatabaseConnection }

function TBESENDatabaseConnection.GetRecordCount: Integer;
begin
  if Assigned(FThread) then
  begin
    if FThread.IsReady then
      result:=FConnection.RecordCount
    else
      result:=-1;
  end else
    result:=FConnection.RecordCount;
end;

function TBESENDatabaseConnection.GetErrorMessage: TBESENString;
begin
  result:=BESENUTF8ToUTF16(FConnection.FLastError);
end;

function TBESENDatabaseConnection.GetFieldCount: Integer;
begin
  if Assigned(FThread) then
  begin
    if FThread.IsReady then
      result:=FConnection.FieldCount
    else
      result:=-1;
  end else
    result:=FConnection.FieldCount;
end;

procedure TBESENDatabaseConnection.Spinlock;
begin
  if Assigned(FThread) then
  begin
    if not FThread.IsReady then
      Writeln('i am spinning...');
    while not FThread.IsReady do ;
  end;
end;

procedure TBESENDatabaseConnection.UnprotectCallbacks;
begin
  if Assigned(FSuccessProc) then
    TBESEN(Instance).GarbageCollector.Unprotect(FSuccessProc);
  if Assigned(FFailProc) then
    TBESEN(Instance).GarbageCollector.Unprotect(FFailProc);

  FSuccessProc:=nil;
  FFailProc:=nil;
end;

procedure TBESENDatabaseConnection.Success;
var
  AResult: TBESENValue;
  proc: TBESENObjectFunction;
begin
  Spinlock;
  proc:=FSuccessProc;
  UnprotectCallbacks;
  if Assigned(proc) then
  begin
    proc.Call(BESENObjectValue(Self), nil, 0, AResult);
  end;
end;

procedure TBESENDatabaseConnection.Fail;
var
  AResult: TBESENValue;
  proc: TBESENObjectFunction;
begin
  Spinlock;
  proc:=FFailProc;
  UnprotectCallbacks;
  if Assigned(proc) then
  begin
    proc.Call(BESENObjectValue(Self), nil, 0, AResult);
  end;
end;

procedure TBESENDatabaseConnection.ConstructObject(
  const ThisArgument: TBESENValue; Arguments: PPBESENValues;
  CountArguments: integer);
var
  AType: ansistring;
begin
  if CountArguments<1 then
    raise EBESENError.Create('Database type expected');

  if (Instance is TBESENInstance) and Assigned(TBESENInstance(Instance).Thread)
     and (TBESENInstance(Instance).Thread is TEpollWorkerThread) then
    FWorkThread:=TEpollWorkerThread(TBESENInstance(Instance).Thread);

  FConnection:=TDatabaseConnection.Create;

  AType:=BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[0]^));
  if AType = 'mysql' then
  begin
    FConnection.Initialize(dtMySql);
  end else
  raise EBESENError.Create('Unknown Database type');

  if Assigned(FWorkThread) then
  begin
    FThread:=TBESENDatabaseThread.Create(FConnection);
    FThread.FWorkThread:=FWorkThread;
    FThread.FParent:=Self;
  end;
  //inherited ConstructObject(ThisArgument, Arguments, CountArguments);
end;

procedure TBESENDatabaseConnection.FinalizeObject;
begin
  if Assigned(FThread) then
  begin
    FreeAndNil(FThread);
  end;
  if Assigned(FConnection) then
  begin
    FreeAndNil(FConnection);
  end;
  inherited FinalizeObject;
end;

destructor TBESENDatabaseConnection.Destroy;
begin
  inherited Destroy;
end;

procedure TBESENDatabaseConnection.connect(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  o: TBESENObject;
begin
  resultValue:=BESENUndefinedValue;

  if CountArguments<4 then
    Exit;

  if CountArguments>4 then
  begin
    o:=TBESEN(Instance).ToObj(Arguments^[4]^);
    if o is TBESENObjectFunction then
      FSuccessProc:=TBESENObjectFunction(o)
    else
      raise EBESENError.Create('function expected');
    TBESEN(Instance).GarbageCollector.Protect(FSuccessProc);
  end
  else
    FSuccessProc:=nil;

  if CountArguments>5 then
  begin
    o:=TBESEN(Instance).ToObj(Arguments^[5]^);
    if o is TBESENObjectFunction then
      FFailProc:=TBESENObjectFunction(o)
    else
      raise EBESENError.Create('function expected');

    TBESEN(Instance).GarbageCollector.Protect(FFailProc);
  end else
    FFailProc:=nil;

  if Assigned(FThread) then
  begin
    if not FThread.Connect(BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[0]^)),
                           BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[1]^)),
                           BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[2]^)),
                           BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[3]^))) then
     raise EBESENError.Create('Database operation still in progress');
  end else
  begin
    if FConnection.Connect(BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[0]^)),
                           BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[1]^)),
                           BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[2]^)),
                           BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[3]^))) then
    begin
      ResultValue:=BESENBooleanValue(True);
      Success
    end
    else
    begin
      ResultValue:=BESENBooleanValue(False);
      Fail;
    end;
  end;
end;

procedure TBESENDatabaseConnection.query(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  o: TBESENObject;
begin
  if CountArguments=0 then
    raise EBESENError.Create('Query expected');

  if CountArguments>1 then
  begin
    o:=TBESEN(Instance).ToObj(Arguments^[1]^);
    if o is TBESENObjectFunction then
      FSuccessProc:=TBESENObjectFunction(o)
    else
      raise EBESENError.Create('function expected');
    TBESEN(Instance).GarbageCollector.Protect(FSuccessProc);
  end
  else
    FSuccessProc:=nil;

  if CountArguments>2 then
  begin
    o:=TBESEN(Instance).ToObj(Arguments^[2]^);
    if o is TBESENObjectFunction then
      FFailProc:=TBESENObjectFunction(o)
    else
      raise EBESENError.Create('function expected');

    TBESEN(Instance).GarbageCollector.Protect(FFailProc);
  end else
    FFailProc:=nil;
  if Assigned(FThread) then
  begin
    if not FThread.Query(BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[0]^))) then
      raise EBESENError.Create('Database operation still in progress');
  end else
  begin
    if FConnection.Query(BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[0]^))) then
    begin
      ResultValue:=BESENBooleanValue(True);
      Success;
    end
    else
    begin
      ResultValue:=BESENBooleanValue(False);
      Fail;
    end;
  end;
end;

procedure TBESENDatabaseConnection.prepare(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  o: TBESENObject;
begin
  if CountArguments=0 then
    raise EBESENError.Create('Query expected');

  if CountArguments>1 then
  begin
    o:=TBESEN(Instance).ToObj(Arguments^[1]^);
    if o is TBESENObjectFunction then
      FSuccessProc:=TBESENObjectFunction(o)
    else
      raise EBESENError.Create('function expected');
    TBESEN(Instance).GarbageCollector.Protect(FSuccessProc);
  end
  else
    FSuccessProc:=nil;

  if CountArguments>2 then
  begin
    o:=TBESEN(Instance).ToObj(Arguments^[2]^);
    if o is TBESENObjectFunction then
      FFailProc:=TBESENObjectFunction(o)
    else
      raise EBESENError.Create('function expected');

    TBESEN(Instance).GarbageCollector.Protect(FFailProc);
  end else
    FFailProc:=nil;

  if Assigned(FThread) then
  begin
    if not FThread.Prepare(BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[0]^))) then
      raise EBESENError.Create('Database operation still in progress');
  end else
  begin
    if FConnection.Prepare(BESENUTF16ToUTF8(TBESEN(Instance).ToStr(Arguments^[0]^))) then
    begin
      ResultValue:=BESENBooleanValue(True);
      Success;
    end
    else
    begin
      ResultValue:=BESENBooleanValue(False);
      Fail;
    end;
  end;
end;

procedure TBESENDatabaseConnection.execute(const ThisArgument: TBESENValue;
  Arguments: PPBESENValues; CountArguments: integer;
  var ResultValue: TBESENValue);
var
  o: TBESENObject;
  prop: TBESENObjectProperty;
  key: TBESENString;
  Value: TBESENValue;
begin
  if CountArguments=0 then
    raise EBESENError.Create('Query expected');

  if CountArguments>1 then
  begin
    o:=TBESEN(Instance).ToObj(Arguments^[1]^);
    if o is TBESENObjectFunction then
      FSuccessProc:=TBESENObjectFunction(o)
    else
      raise EBESENError.Create('function expected');
    TBESEN(Instance).GarbageCollector.Protect(FSuccessProc);
  end
  else
    FSuccessProc:=nil;

  if CountArguments>2 then
  begin
    o:=TBESEN(Instance).ToObj(Arguments^[2]^);
    if o is TBESENObjectFunction then
      FFailProc:=TBESENObjectFunction(o)
    else
      raise EBESENError.Create('function expected');

    TBESEN(Instance).GarbageCollector.Protect(FFailProc);
  end else
    FFailProc:=nil;

  if Assigned(FThread) then
  begin
    if not FThread.IsReady then
      raise EBESENError.Create('Database operation still in progress');
  end;

  o:=TBESEN(Instance).ToObj(Arguments^[0]^);
  prop:=o.Properties.First;

  while Assigned(prop) do
  begin
    key:=prop.Key;
    o.Get(Key, Value);
    FConnection.SetValue(BESENUTF16ToUTF8(Key), BESENValueToVariant(Value));
    prop:=Prop.Next;
  end;

  if Assigned(FThread) then
  begin
    if not FThread.ExecuteQuery then
      raise EBESENError.Create('Internal error');
  end else
  begin
    if FConnection.Execute then
    begin
      ResultValue:=BESENBooleanValue(True);
      Success;
    end
    else
    begin
      ResultValue:=BESENBooleanValue(False);
      Fail;
    end;
  end;
end;

procedure TBESENDatabaseConnection.getNextRecord(
  const ThisArgument: TBESENValue; Arguments: PPBESENValues;
  CountArguments: integer; var ResultValue: TBESENValue);
var
  i: Integer;
  fields: TFields;
  o: TBESENDatabaseRecord;
  v: TBESENValue;
begin
  ResultValue:=BESENUndefinedValue;

  if Assigned(FThread) and (not FThread.IsReady) then
    raise EBESENError.Create('Database connection is busy');

  fields:=FConnection.Fields;

  if not Assigned(Fields) then
    raise EBESENError.Create('No database query');

  if FConnection.FQuery.EOF then
  begin
    Exit;
  end;

  o:=TBESENDatabaseRecord.Create(Instance);
  o.InitializeObject;

  for i:=0 to FConnection.FieldCount-1 do
  begin
    BESENVariantToValue(Fields[i].Value, v);
    o.put(BESENUTF8ToUTF16(fields[i].FieldName), v, false);
  end;
  FConnection.FQuery.Next;

  ResultValue:=BESENObjectValue(o);
end;

procedure TBESENDatabaseConnection.getFieldName(
  const ThisArgument: TBESENValue; Arguments: PPBESENValues;
  CountArguments: integer; var ResultValue: TBESENValue);
var
  i: Integer;
  fields: TFields;
begin
  ResultValue:=BESENUndefinedValue;

  if CountArguments<1 then
    Exit;

  if Assigned(FThread) and (not FThread.IsReady) then
    raise EBESENError.Create('Database connection is busy');

  fields:=FConnection.Fields;

  if not Assigned(Fields) then
    raise EBESENError.Create('No database query');

  i:=TBESEN(Instance).ToInt(Arguments^[0]^);

  if (i>=0)and(i<fields.Count) then
    resultValue:=BESENStringValue(BESENUTF8ToUTF16(Fields[i].FieldName));
end;

{ TBESENDatabaseThread }

procedure TBESENDatabaseThread.Execute;
begin
  while not Terminated do
  begin
    FIsReady:=True;
    RTLeventWaitFor(FEvent);
    try
      case FAction of
        taNone: ;
        taConnect:
        begin
          if FConnection.Connect(FServer, FUser, FPassword, FDatabase) then
            FWorkThread.Callback(FParent.Success)
          else
            FWorkThread.Callback(FParent.Fail);
          FServer:='';
          FUser:='';
          FPassword:='';
          FDatabase:='';
        end;
        taQuery:
        begin
          if FConnection.Query(FQuery) then
            FWorkThread.Callback(FParent.Success)
          else
            FWorkThread.Callback(FParent.Fail);

          FQuery:='';
        end;
        taPrepare:
        begin
          if FConnection.Prepare(FQuery) then
            FWorkThread.Callback(FParent.Success)
          else
            FWorkThread.Callback(FParent.Fail);

          FQuery:='';
        end;
        taExecute:
        begin
          if FConnection.Execute then
            FWorkThread.Callback(FParent.Success)
          else
            FWorkThread.Callback(FParent.Fail);
        end;
      end;
    except
      on e: Exception do
        dolog(llError, 'Error in database thread: '+e.Message);
    end;
    FAction:=taNone;
  end;
end;

constructor TBESENDatabaseThread.Create(Connection: TDatabaseConnection);
begin
  FConnection:=Connection;
  FIsReady:=False;
  FEvent:=RTLEventCreate;
  FAction:=taNone;
  inherited Create(False);
end;

destructor TBESENDatabaseThread.Destroy;
begin
  Terminate;

  if FIsReady then
    RTLeventSetEvent(FEvent);

  WaitFor;
  RTLeventdestroy(FEvent);
  inherited Destroy;
end;

function TBESENDatabaseThread.Connect(const AServer, AUser, APassword,
  ADatabase: ansistring): Boolean;
begin
  result:=False;
  if not FIsReady then
    Exit;
  FServer:=AServer;
  FUser:=AUser;
  FPassword:=APassword;
  FDatabase:=ADatabase;
  FIsReady:=False;
  RTLeventSetEvent(FEvent);
  result:=True;
end;

function TBESENDatabaseThread.Query(const AQuery: ansistring): Boolean;
begin
  result:=False;
  if not Suspended then
    Exit;
  FQuery:=AQuery;
  FAction:=taQuery;
  FIsReady:=False;
  RTLeventSetEvent(FEvent);
  result:=True;
end;

function TBESENDatabaseThread.Prepare(const AQuery: ansistring): Boolean;
begin
  result:=False;
  if not Suspended then
    Exit;
  FQuery:=AQuery;
  FAction:=taPrepare;
  FIsReady:=False;
  RTLeventSetEvent(FEvent);
  result:=True;
end;

function TBESENDatabaseThread.ExecuteQuery: Boolean;
begin
  result:=False;
  if not FIsReady then
    Exit;
  FAction:=taExecute;
  FIsReady:=False;
  RTLeventSetEvent(FEvent);
  result:=True;
end;

{ TDatabaseConnection }

procedure TDatabaseConnection.LogEvent(Sender: TSQLConnection;
  EventType: TDBEventType; const Msg: String);
begin
  // dolog(llDebug, 'db: '+ msg);
end;

function TDatabaseConnection.GetRowsAffected: Integer;
begin
  if FState = dcQuery then
    result:=FQuery.RowsAffected
  else
    result:=-1;
end;

function TDatabaseConnection.GetFieldCount: Integer;
begin
  FQuery.RecordCount;
  if FState = dcQuery then
    result:=FQuery.FieldCount
  else
    result:=-1;
end;

function TDatabaseConnection.GetFields: TFields;
begin
  FQuery.RecordCount;
  if FState = dcQuery then
    result:=FQuery.Fields
  else
    result:=nil;
end;

function TDatabaseConnection.GetRecordCount: Integer;
begin
  FQuery.RecordCount;
  if FState = dcQuery then
    result:=FQuery.RecordCount
  else
    result:=-1;
end;

procedure TDatabaseConnection.UpdateErrorEvent(Sender: TObject;
  DataSet: TCustomBufDataset; E: EUpdateError; UpdateKind: TUpdateKind;
  var Response: TResolverResponse);
begin
  FLastError:='Update Error '+e.Message;
  //Writeln('update error');
end;

procedure TDatabaseConnection.CalcFieldsEvent(DataSet: TDataSet);
begin
  //Writeln('calc fields');
end;

procedure TDatabaseConnection.DeleteErrorEvent(DataSet: TDataSet;
  E: EDatabaseError; var DataAction: TDataAction);
begin
  FLastError:='Delete Error '+e.Message;
  //Writeln('delete error');
end;

procedure TDatabaseConnection.EditErrorEvent(DataSet: TDataSet;
  E: EDatabaseError; var DataAction: TDataAction);
begin
  FLastError:='Edit Error '+e.Message;
  //Writeln('edit error');
end;

procedure TDatabaseConnection.FilterRecordEvent(DataSet: TDataSet;
  var Accept: Boolean);
begin
  //Writeln('filter record');
end;

procedure TDatabaseConnection.NewRecordEvent(DataSet: TDataSet);
begin
  //Writeln('new record');
end;

procedure TDatabaseConnection.PostErrorEvent(DataSet: TDataSet;
  E: EDatabaseError; var DataAction: TDataAction);
begin
  FLastError:='Post Error '+e.Message;
end;

procedure TDatabaseConnection.HandleException(e: Exception);
begin
  dolog(llError, 'database error: '+ e.Message);
  FLastError:=e.Message;
  if Assigned(FOnError) then
   FOnError(FLastError);
end;

constructor TDatabaseConnection.Create;
begin
  FConnection:=nil;
  Fquery:=nil;
  FTransaction:=nil;
  FState:=dcUninitialized;
  FLastError:='Not initialized';
end;

destructor TDatabaseConnection.Destroy;
begin
  if Assigned(FTransaction) then
  begin
    FTransaction.Commit;
    FTransaction.Active:=False;
  end;

  if Assigned(FQuery) then
    FQuery.Close;

  if Assigned(FConnection) then
    FConnection.Connected:=False;

  if Assigned(FQuery) then
    FreeAndNil(FQuery);

  if Assigned(FConnection) then
  begin
    FConnection.Transaction:=nil;
    FreeAndNil(FConnection);
  end;
  if Assigned(FTransaction) then
    FreeAndNil(FTransaction);

  inherited Destroy;
end;

function TDatabaseConnection.Initialize(AKind: TDatabaseType): Boolean;
begin
  result:=False;

  if FState <> dcUninitialized then
    Exit;

  case AKind of
    dtMySql:
    begin
      FConnection:=TMySQL57Connection.Create(nil);
      {$ifdef MySQLWorkAround}
      if not MySQLWorkAround then
      begin
        InitialiseMysql(mysqllib);
        MySQLWorkAround:=True;
      end;
      {$endif}
    end;
  end;
  FQuery:=TSQLQuery.Create(nil);
  FTransaction:=TSQLTransaction.Create(nil);
  FConnection.Transaction:=FTransaction;
  FQuery.Transaction:=FTransaction;

  FConnection.OnLog:=LogEvent;
  FQuery.OnUpdateError:=UpdateErrorEvent;
  FQuery.OnCalcFields:=CalcFieldsEvent;
  FQuery.OnDeleteError:=DeleteErrorEvent;
  FQuery.OnEditError:=EditErrorEvent;
  FQuery.OnFilterRecord:=FilterRecordEvent;
  FQuery.OnNewRecord:=NewRecordEvent;
  FQuery.OnPostError:=PostErrorEvent;

  FState:=dcInitialized;
  result:=True;
  FLastError:='';
end;

function TDatabaseConnection.Connect(server, user, password,
  database: ansistring): Boolean;
begin
  result:=false;
  if FState <> dcInitialized then
   Exit;

  FConnection.UserName:=user;
  FConnection.Password:=password;
  FConnection.HostName:=server;
  FConnection.DatabaseName:=database;

  try
    FConnection.Connected:=True;
    FTransaction.Active:=True;

    result:=True;
    FState:=dcConnected;
  except
    on e: Exception do
    begin
      result:=False;
      FState:=dcInitialized;
      HandleException(e);
    end;
  end;
end;

function TDatabaseConnection.Close: Boolean;
begin
  result:=False;
  if not (FState in [dcConnected, dcPrepare, dcPrepareExecute, dcQuery]) then
    Exit;

  FTransaction.Commit;
  FQuery.Close;
  FConnection.Close;
  result:=true;
end;

function TDatabaseConnection.Query(QueryString: ansistring): Boolean;
begin
  result:=False;
  if not (FState in [dcConnected, dcQuery, dcPrepare, dcPrepareExecute]) then
   Exit;

  FQuery.SQL.Text:=QueryString;

  try
    FQuery.Open;
    FState:=dcQuery;
    result:=True;
  except
    on e: Exception do
    begin
      result:=False;
      FState:=dcConnected;
      HandleException(e);
    end;
  end;
end;

function TDatabaseConnection.Prepare(QueryString: ansistring): Boolean;
begin
  result:=False;
  if not (FState in [dcConnected, dcQuery, dcPrepare, dcPrepareExecute]) then
   Exit;

  FQuery.SQL.Text:=QueryString;

  try
    FQuery.Prepare;
    FState:=dcPrepare;
    result:=True;
  except
    on e: Exception do
    begin
      result:=False;
      FState:=dcConnected;
      HandleException(e);
    end;
  end;
end;

function TDatabaseConnection.Execute: Boolean;
begin
  result:=False;
  if not (FState in [dcPrepare, dcPrepareExecute]) then
   Exit;

  //FQuery.SQL.Text:=QueryString;

  try
    FQuery.ExecSQL;
    FTransaction.CommitRetaining;
    FState:=dcPrepareExecute;
    result:=True;
  except
    on e: Exception do
    begin
      result:=False;
      FState:=dcConnected;
      HandleException(e);
    end;
  end;
end;

procedure TDatabaseConnection.SetValue(ParamName: ansistring; Value: Variant);
begin
  FQuery.Params.ParamByName(ParamName).Value:=Value;
end;

{$ifdef MySQLWorkAround}
initialization
  MySQLWorkAround:=False;
{$endif}
end.

