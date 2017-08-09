unit buildinfo;

{$mode delphi}

interface

uses
  Classes, SysUtils;

const
  TargetCPU = {$I %FPCTARGETCPU%};
  BuildDate = {$I %DATE%};
  BuildString = BuildDate+'-'+TargetCPU;

implementation

end.

