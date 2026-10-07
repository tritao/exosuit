package app;

class BrowserPairingUrlTestMain {
	static function require(value:Bool, message:String):Void {
		if (!value) throw message;
	}

	static function main():Void {
		var machine = "0123456789abcdef0123456789abcdef";
		var device = "abcdef0123456789abcdef0123456789";
		var secret = machine + device;
		var path = "/v1/machines/" + machine + "/pair/" + device + "?secret=" + secret;
		var url = "wss://exosuit-relay.example-9f7.workers.dev" + path;
		var parsed = BrowserPairingInvitation.parse(url);
		if (parsed == null) throw "Complete hosted WSS invitation rejected";
		require(parsed.url == url && parsed.origin == "https://exosuit-relay.example-9f7.workers.dev",
			"Invitation URL or relay origin changed");
		require(parsed.machineId == machine && parsed.deviceId == device, "Incorrect pairing identifiers");
		for (origin in ["ws://localhost:8787", "ws://127.0.0.1:8787", "wss://relay.example:443"])
			require(BrowserPairingInvitation.parse(origin + path) != null, "Valid origin rejected: " + origin);
		for (invalid in ["wss://relay.example", "https://relay.example" + path,
			"ws://relay.example" + path, "wss://relay.example:0" + path,
			"wss://relay.example:65536" + path, url.substr(0, url.length - 1),
			url + "0", url + "&extra=1", StringTools.replace(url, machine, "short"),
			StringTools.replace(url, "/pair/" + device, "/pair/short")])
			require(BrowserPairingInvitation.parse(invalid) == null, "Malformed invitation accepted");
		require(BrowserPairingInvitation.parse(null) == null, "Null invitation accepted");
		Sys.println("PASS: browser pairing URL validation");
	}
}
