{$mode delphi}

{ Basic support for OpenSSL - sadly there is still a mysterious bug within
  openssl when certain openssl-functions are called from within a native
  BESEN callback function, which usually happens when websocket-scripts
  are involved. This happens only when BESEN is compiled with JIT.
  As a workaround you can use the DISABLEJIT define for BESEN. }
{$DEFINE OPENSSL_SUPPORT}

{.$DEFINE HIXIE76_PING}
{ send and receive ping requests via userdata-layer, since this draft
  has no support for pings inside the protocol. }

