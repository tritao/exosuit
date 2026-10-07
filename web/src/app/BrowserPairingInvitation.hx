package app;

/** Validates one-time relay invitations before opening a browser connection. */
class BrowserPairingInvitation {
	public static function parse(url:String):Null<{url:String, origin:String, machineId:String, deviceId:String}> {
		var pattern = new EReg("^(wss?)://([A-Za-z0-9.-]+)(?::([0-9]{1,5}))?/v1/machines/([0-9a-f]{32})/pair/([0-9a-f]{32})[?]secret=([0-9a-f]{64})$", "");
		if (url == null || !pattern.match(url)) return null;
		var scheme = pattern.matched(1).toLowerCase();
		var host = pattern.matched(2).toLowerCase();
		// Haxeon returns an empty string for an unmatched optional group.
		var port = pattern.matched(3);
		if (port == "") port = null;
		if (port != null && (Std.parseInt(port) == null || Std.parseInt(port) > 65535 || Std.parseInt(port) < 1)) return null;
		if (scheme != "wss" && host != "localhost" && host != "127.0.0.1") return null;
		var origin = (scheme == "wss" ? "https" : "http") + "://" + host + (port == null ? "" : ":" + port);
		return {url: url, origin: origin, machineId: pattern.matched(4), deviceId: pattern.matched(5)};
	}
}
