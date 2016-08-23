
function start() {
	// load default site
	server.setDefaultSite(loadSite('default', []));
	
	// to load another site:
	// loadSite('foobar', ['my-hostname1:18080', '127.0.0.1:18080']);
	
	// bind server to ip address:
	server.addListener('127.0.0.1', '18080');
	
	// set number of worker-threads
	server.setThreadCount(8);
}

var Sites = {};

function loadSite(site, hosts) {
	if(Sites[site]) {
		system.log("Site '"+site+"' already loaded");
		return Sites[site];
	}
	
	var result = server.addSite(site);
	
	if(!result) {
		system.log("Site '"+site+"' could not be loaded");
		return;
	}
	
	try {
		// if a startup script is inside the site folder we'll execute it
		if(result.fileExists('start.js')) {
			var x = system.eval(site+'/start.js', result.readFile('start.js'));
			x(result);
		}
	} catch(e) {
		system.log("Error running startup script for '"+site+"': "+e);
	}
	
	for(var h in hosts)
		result.addHostname(hosts[h]);
	
	Sites[site] = result;
	return result;
}

try {
	start();
} catch(e) {
	system.log("Error in configuration script: "+e);
}