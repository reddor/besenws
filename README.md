# besenws

besenws is a web(socket)server for linux based on [BESEN](https://github.com/BeRo1985/besen), a powerful ECMAScript engine. besenws allows you to write websocket services and dynamic webpages using ECMAScript.

There are three different types of scripts in besenws:

### Websocket Scripts
A websocket script runs in it's own context and thread. Whenever a clients connects, disconnects or sends data an event is fired. 

### Page Scripts
A page script is similar to PHP, but with ECMAScript. It allows you to create dynamic webpages by mixing HTML and server-side-ECMAScript. It also has the biggest impact on resources, as for each request, a new script context is created in which the script is then executed and followed by unloading of the contexts. Page scripts cannot receive events - once the execution of the script is over, the generated answer is sent to the client immediately. 

### Configuration Script
The configuration script (settings.js) is loaded on startup and sets up all aspects of the server. Since some type of configuration file is necessary, wrapping it in a script seemed like a good idea.

besenws supports multiple hosts and sites. It caches all static web-data, therefore it's not recommended to host big files, as they will reside in memory. besenws uses epoll for good performance. 

## Requirements

 - Linux or Windows-Subsystem for Linux
 - FPC (3.0+ recommended)

## F.A.Q.

### Can't I just use node.js?
Yes, yes you can. However, besenws follows a slightly different approach - all lowlevel socket-, thread- and protocol-handling is implemented natively with a neatly exposed ECMAScript API, specifically for websockets and -pages. You can't create arbritary servers in besenws, but you don't have to reimplement the http protocol or depend on 3rd party scripts to create a websocket service.

### Should I use it?
besenws is still in development - certain things are unfinished or untested, the API is undocumented and still subject to change. I strongly advise against using besenws in a production environment for now. Other than that you are more than welcome to try it out and leave feedback.


