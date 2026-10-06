package workspace.transport;

/** Canonical relay origin and opaque registered machine identity. */
class RelayMachineEndpoint {
	public final origin:String;
	public final machineId:String;
	public final isLoopbackHttp:Bool;

	public function new(origin:String, machineId:String) {
		var value = origin != null && StringTools.endsWith(origin, "/") ? origin.substr(0, origin.length - 1) : origin;
		var pattern = ~/^(https?):\/\/([A-Za-z0-9.-]+)(?::([0-9]{1,5}))?$/i;
		if (value == null || !pattern.match(value))
			throw "Relay origin must be an HTTPS origin";
		var scheme = pattern.matched(1).toLowerCase();
		var host = pattern.matched(2).toLowerCase();
		var portText = pattern.matched(3);
		var port = portText == null || portText == "" ? 0 : Std.parseInt(portText);
		if (port == null || port > 65535 || port < 0 || portText != null && portText != "" && port == 0)
			throw "Invalid relay port";
		isLoopbackHttp = scheme == "http" && (host == "127.0.0.1" || host == "localhost");
		if (scheme != "https" && !isLoopbackHttp)
			throw "Relay access requires HTTPS except for a loopback development Worker";
		RelayFrameCodec.decodeChannelId(machineId);
		this.origin = value;
		this.machineId = machineId;
	}

	public function ticketUrl():String
		return origin + "/v1/machines/" + machineId + "/tickets";

	public function registrationUrl():String
		return origin + "/v1/machines/" + machineId + "/register";

	public function pairingsUrl():String
		return origin + "/v1/machines/" + machineId + "/pairings";

	public function deviceUrl(deviceId:String):String {
		RelayFrameCodec.decodeChannelId(deviceId);
		return origin + "/v1/machines/" + machineId + "/devices/" + deviceId;
	}

	public function websocketUrl(ticket:RelaySocketTicket):String {
		if (ticket == null)
			throw "Relay socket ticket is required";
		var scheme = isLoopbackHttp ? "ws" : "wss";
		var authority = origin.substr(origin.indexOf("://") + 3);
		return scheme + "://" + authority + "/v1/machines/" + machineId + "/connect?ticket=" + ticket.value;
	}

	public function pairingSocketUrl(channelId:String, secret:String):String {
		RelayFrameCodec.decodeChannelId(channelId);
		if (!RelaySocketTicket.isToken(secret))
			throw "Invalid relay pairing secret";
		var scheme = isLoopbackHttp ? "ws" : "wss";
		var authority = origin.substr(origin.indexOf("://") + 3);
		return scheme + "://" + authority + "/v1/machines/" + machineId + "/pair/" + channelId + "?secret=" + secret;
	}
}
