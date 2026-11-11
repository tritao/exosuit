package workspace.client;

import haxe.io.Bytes;
import workspace.transport.MachineKeys;

/**
	A one-time pairing link as the machine's Remote Access panel shows it:
	`wss://host[:port]/v1/machines/<relay id>/pair/<device id>?secret=<secret>[#mk=<machine key fingerprint>]`.
	Plain `ws` is accepted only for a loopback development relay. The fragment is the fingerprint of the machine's Noise
	key (`MachineKeys.fingerprint`); the device connects to `socketUrl`, without it, so the relay never sees it. A link
	from a machine before the fingerprint has none (`machineKey` null): then only the code comparison checks the machine.
**/
class PairingLink {
	public final socketUrl:String;
	public final origin:String;
	/** The relay id the machine registered (the id the device pairs under). */
	public final relayId:String;
	public final deviceId:String;
	public final machineKey:Null<String>;

	function new(socketUrl:String, origin:String, relayId:String, deviceId:String, machineKey:Null<String>) {
		this.socketUrl = socketUrl;
		this.origin = origin;
		this.relayId = relayId;
		this.deviceId = deviceId;
		this.machineKey = machineKey;
	}

	public static function parse(text:Null<String>):Null<PairingLink> {
		if (text == null)
			return null;
		var socketUrl = text, machineKey:Null<String> = null;
		var hash = text.indexOf("#");
		if (hash >= 0) {
			var fragment = text.substr(hash);
			if (!StringTools.startsWith(fragment, MachineKeys.URL_FRAGMENT))
				return null;
			machineKey = fragment.substr(MachineKeys.URL_FRAGMENT.length);
			if (!MachineKeys.isFingerprint(machineKey))
				return null;
			socketUrl = text.substr(0, hash);
		}
		var pattern = new EReg("^(wss?)://([A-Za-z0-9.-]+)(?::([0-9]{1,5}))?/v1/machines/([0-9a-f]{32})/pair/([0-9a-f]{32})[?]secret=([0-9a-f]{64})$", "");
		if (!pattern.match(socketUrl))
			return null;
		var scheme = pattern.matched(1).toLowerCase();
		var host = pattern.matched(2).toLowerCase();
		// Haxeon returns an empty string for an unmatched optional group.
		var port = pattern.matched(3);
		if (port == "")
			port = null;
		if (port != null && (Std.parseInt(port) == null || Std.parseInt(port) > 65535 || Std.parseInt(port) < 1))
			return null;
		if (scheme != "wss" && host != "localhost" && host != "127.0.0.1")
			return null;
		var origin = (scheme == "wss" ? "https" : "http") + "://" + host + (port == null ? "" : ":" + port);
		return new PairingLink(socketUrl, origin, pattern.matched(4), pattern.matched(5), machineKey);
	}

	/** Whether the machine key the handshake reached is the one the link names; true for a link without a fingerprint. */
	public function admits(remoteStaticKey:Bytes):Bool
		return machineKey == null || remoteStaticKey != null && remoteStaticKey.length == 32 && MachineKeys.fingerprint(remoteStaticKey) == machineKey;
}
