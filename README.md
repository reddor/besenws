# besenws

besenws is a linux-only web(socket) server based on [BESEN](https://github.com/BeRo1985/besen). It allows you to write websocket services and dynamic webpages using ECMAScript without requiring any
further depencies. 

## Features

 - multithreaded
 - supports multiple hosts 
 - caches all static files
 - uses [epoll](https://en.wikipedia.org/wiki/Epoll)
 - all scripts runs in their own context
 - a php-like hypertext processor, but with ECMAScript
 - asynchronous scripts for websockets

besenws is still in development. To build it, FPC 3.0.0+ is recommended. Use at your own risk.
 
