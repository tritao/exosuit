/** A one-time pairing link from the desktop's Remote Access panel, checked before the phone opens a connection. */
class PhoneInvitation {
	public final url:String;
	public final origin:String;
	public final machineId:String;
	public final deviceId:String;

	function new(url:String, origin:String, machineId:String, deviceId:String) {
		this.url = url;
		this.origin = origin;
		this.machineId = machineId;
		this.deviceId = deviceId;
	}

	/** `wss://host[:port]/v1/machines/<machine>/pair/<device>?secret=<secret>`; plain `ws` only to a loopback development relay. */
	public static function parse(text:Null<String>):Null<PhoneInvitation> {
		var pattern = new EReg("^(wss?)://([A-Za-z0-9.-]+)(?::([0-9]{1,5}))?/v1/machines/([0-9a-f]{32})/pair/([0-9a-f]{32})[?]secret=([0-9a-f]{64})$", "");
		if (text == null || !pattern.match(text)) return null;
		var scheme = pattern.matched(1).toLowerCase();
		var host = pattern.matched(2).toLowerCase();
		var port = pattern.matched(3);
		if (port == "") port = null;
		if (port != null && (Std.parseInt(port) == null || Std.parseInt(port) > 65535 || Std.parseInt(port) < 1)) return null;
		if (scheme != "wss" && host != "localhost" && host != "127.0.0.1") return null;
		var origin = (scheme == "wss" ? "https" : "http") + "://" + host + (port == null ? "" : ":" + port);
		return new PhoneInvitation(text, origin, pattern.matched(4), pattern.matched(5));
	}
}
