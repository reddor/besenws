function setMessage(msg, isLogin) {
  document.getElementById("message").innerHTML = msg;
  document.getElementById("overlay").style.visibility = "visible";
  document.getElementById("loginbox").style.visibility = (isLogin ? "visible" : "hidden");
  if(isLogin == true) 
    document.getElementById("username").focus();
}
 
function escapeHtml(str) {
    var div = document.createElement('div');
    div.appendChild(document.createTextNode(str));
    return div.innerHTML;
}
      
function timestamp() {
  var d = new Date();
  var fix = function(i) {
    if (i<10)
      return "0" + i;
    return i;
  };
  return "[" + fix(d.getHours()) +":" + fix(d.getMinutes()) + "] ";
}
      
function addRaw(message) {
  
  var chatbox = document.getElementById("chatbox");
  
  var doScroll = chatbox.scrollTop >= chatbox.scrollHeight - chatbox.clientHeight;
  
  chatbox.innerHTML += timestamp() + message;
  if(doScroll)
    chatbox.scrollTop = chatbox.scrollHeight;
}
      
function addChatter(user, text) {
  addRaw("<b>" + user + "</b>: "+escapeHtml(text) + "<br>\n");
}
      
function addSysMessage(message) {
  addRaw("<i>"+escapeHtml(message)+"</i><br>\n");  
}
  
function startChatting() {
  document.getElementById("overlay").style.visibility = "hidden";
  document.getElementById("textinput").focus();
}
      
var socket;
var username = "test";
var auth = false;
      
function doConnect() {
  if(socket) {
    try {
      socket.onerror = socket.onmessage = socket.onopen = socket.onclose = function() {};     
      socket.close();
    } catch(e) { }
  }
  
  auth = false;
  var url = ((location.protocol == "https") ? "wss" : "ws") + '//'+location.hostname+(location.port ? ':'+location.port: '') + "/chat";
  url = "ws://127.0.0.1:18080/chat";
  try {
    socket = new WebSocket(url);
    socket.onopen = function() {
      socket.send("HELLO "+username);
    };
    socket.onerror = function(e) {
      setMessage("Could not connect to service");
    };
    socket.onopen = function(e) {
      setMessage("Connected!");
      auth = false;
      socket.send("USER "+username);
      //alert("open");
    };
    socket.onmessage = function(e) {
      if(auth) {
        try {
          var foo = JSON.parse(e.data);
          if(foo.type == "user") {
            addSysMessage(foo.name + " has " + ((foo.reason == "join") ? "joined" : "left")); 
          } else if (foo.type == "message") {
           addChatter(foo.name, foo.message); 
          } else if (foo.type == "userlist") {
            if(foo.users.length == 1) {
              addSysMessage("There's no one here but you!");
            } else {
              addSysMessage("These people are here: "+JSON.stringify(foo.users)); 
            }
          }
        } catch(f) {
          setMessage("Invalid message received: "+e.data + " " + e + " "+f.message);
          socket.close();
        }
      } else {
        if (e.data == "WELCOME") {
          auth = true;
          startChatting();
        } else {
          setMessage(e.data, true);
          socket.close();
        }
      }
    };
    
    setMessage("Connecting...");
    
  } catch(e) {
    setMessage("Websockets not supported "+e.message);  
  }
}

window.onload = function(e) {

document.getElementById("textinput").addEventListener("keypress", function(e) {
  try {
    if(e.keyCode == 13) {
      socket.send(document.getElementById("textinput").value);
      document.getElementById("textinput").value = "";
      e.preventDefault();
    }
  } catch(e) {
      document.getElementById("textinput").value = "";
      e.preventDefault();
  }
  return false;
});
      
document.getElementById("username").addEventListener("keypress", function(e) {
  try {
    if(e.keyCode == 13) {
      username = (document.getElementById("username").value);
      doConnect();
      e.preventDefault();
    }
  } catch(e) {
    
  }
  return false;
});
      
  document.getElementById("chatbox").style.bottom = document.getElementById("textbox").style.height = document.getElementById("textinput").offsetHeight + "px";
  setMessage("Enter Name", true);
};
