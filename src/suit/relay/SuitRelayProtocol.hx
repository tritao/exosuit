package suit.relay;

import haxe.Json;
import haxe.io.Bytes;

/** What a hosting workspace daemon tells suit when it attaches to suit's machine socket. */
typedef SuitRelayAttachRequest = {
	var root:String;
	var stateDir:String;
	var machineId:String;
	var origin:String;
	/** The HashLink executable and agent bytecode suit runs to start this workspace's manager on demand. */
	var executable:String;
	var launcher:String;
}

/** suit's view of its machine socket, sent to the attached daemon whenever it changes. */
typedef SuitRelayLinkStatus = {
	var connected:Bool;
	var error:Null<String>;
}

/**
	The relay link between a workspace daemon and suit, over suit's control endpoint.

	The daemon sends `{"op":"relay-attach","version":1,...}` as JSON; suit answers `{"ok":true}` or
	`{"ok":false,"error":...}`. After an accepted attach every message is either a whole relay envelope,
	byte for byte what the Worker sends and receives (first byte 1 for data, 2 for a channel reset), or a
	suit status message: the byte 0x10 followed by JSON `{connected, error}`. suit reads only the envelope's
	channel id; the payload is a Noise handshake message or Noise ciphertext.
**/
class SuitRelayProtocol {
	public static inline var VERSION:Int = 1;
	public static inline var ATTACH_OP:String = "relay-attach";
	public static inline var STATUS_KIND:Int = 0x10;

	public static function attachMessage(request:SuitRelayAttachRequest):Bytes
		return Bytes.ofString(Json.stringify({
			op: ATTACH_OP,
			version: VERSION,
			pid: Sys.getPid(),
			root: request.root,
			stateDir: request.stateDir,
			machineId: request.machineId,
			origin: request.origin,
			executable: request.executable,
			launcher: request.launcher
		}));

	public static function statusMessage(status:SuitRelayLinkStatus):Bytes {
		var json = Bytes.ofString(Json.stringify({connected: status.connected, error: status.error}));
		var message = Bytes.alloc(json.length + 1);
		message.set(0, STATUS_KIND);
		message.blit(1, json, 0, json.length);
		return message;
	}

	/** Parses a status message; null when it is not one. */
	public static function parseStatus(message:Bytes):Null<SuitRelayLinkStatus> {
		if (message == null || message.length < 2 || message.get(0) != STATUS_KIND)
			return null;
		var text = Bytes.view(message, 1, message.length - 1).toString();
		var value:Dynamic = Json.parse(text);
		var connected:Dynamic = Reflect.field(value, "connected");
		var error:Dynamic = Reflect.field(value, "error");
		return {connected: connected == true, error: Std.isOfType(error, String) ? cast error : null};
	}

	/** EXOSUIT_RELAY_VIA_SUIT=1|0 decides; unset, a daemon uses suit unless suit autostart is off (tests, the run guard). */
	public static function viaSuitEnabled():Bool {
		var configured = Sys.getEnv("EXOSUIT_RELAY_VIA_SUIT");
		if (configured == "1")
			return true;
		if (configured == "0")
			return false;
		return Sys.getEnv("EXOSUIT_SUIT_AUTOSTART") != "0";
	}
}
