{$mode delphi}

{ Basic support for OpenSSL - use at your own risk. }
{$DEFINE OPENSSL_SUPPORT}

{.$DEFINE HIXIE76_PING}
{ send and receive ping requests via userdata-layer, since this draft
  has no support for pings inside the protocol. }

