unit buildinfo;

{$mode delphi}

interface

uses
  Classes, SysUtils;

const
  ServerName = 'besenws';
  ServerVersion = '0.2';
  TargetCPU = {$I %FPCTARGETCPU%};
  BuildDate = {$I %DATE%};
  BuildString = BuildDate+'-'+TargetCPU;
  FullServerName = ServerName+'/'+ServerVersion+' '+BuildString;

implementation

end.

