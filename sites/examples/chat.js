/* 
besenws chat example (c) Simon Ley, 2017

a simple chat example, one big room, free for all. see chat.html for clientside implementation */

// all connected (and authenticated) clients are stored in this array
var clients = [];

// used to broadcast messages to all connected clients
function broadcast(data) {
  if(typeof data == "object")
    data = JSON.stringify(data);
  
  for(c in clients) {
    clients[c].send(data);
  }
}
  
// nickname validation - only letters and numbers allowed
function validNick(nick) {
  return (/^[a-zA-Z0-9]+$/.test(nick))&&(nick.length > 0);
}

// global connect handler - we wait for the client to say something, and flag it as "not authenticated"
handler.onConnect = function(client) {
  client.auth = false;
};

// global data receive handler - a client just sent us something
handler.onData = function(client, data) {
  
  if(client.auth == false) {
    // if the client is not authenticated, we check for valid commands
    var foo = data.split(" ");
    if(foo[0] == "USER") {
      // we got a username, lets check if it's valid
      if(validNick(foo[1]) == false) {
        client.send("Your username is bad and you should feel bad (only letters and numbers allowed)");
        client.disconnect();
        return ;
      }          

      var names = new Array(foo[1]);
      // check if the username is already taken
      for(c in clients) {
        if (clients[c].name == foo[1]) {
          client.send("Username is already taken");
          client.disconnect();
          return ;
        }
        names.push(clients[c].name);
      }
      
      // seems like everything is okay, user is authenticated now
      client.auth = true;
      client.name = foo[1];
      client.send("WELCOME");
      // add user to global client list and announce him to the others!
      clients.push(client);
      broadcast({type:"user", name:client.name, reason:"join"});
      
      client.send(JSON.stringify({type:"userlist", users:names}));
     
    } else {
      // whatever this is, the client is not using speaking the right protocol
      client.send("You are speaking funny");
      client.disconnect();
    }
  } else {
    // client is authenticated, we just pass the raw data forward to all other clients
    data = data.trim();
    if (data != "")
      broadcast({type:"message", name:client.name, message:data});
  }
};

// user got disconnected
handler.onDisconnect = function(client) {
  if(client.auth) {
    // if the user was authenticated, remove him from the client list and announce that it left
    client.auth = false;
    for(c in clients) {
      if (clients[c] == client) {
        clients[c] = clients[clients.length-1];
        clients.pop();
        break;
      }
    }
    broadcast({type:"user", name:client.name, reason:"left"});
  }
};

// a static http request has been made!
handler.onRequest = function(client) {
  client.redirect("/chat/");
};
