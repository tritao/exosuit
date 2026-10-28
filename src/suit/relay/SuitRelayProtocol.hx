package suit.relay;

import haxe.Json;
import haxe.io.Bytes;
import suit.SuitClient;
import suit.SuitClient.SuitMode;

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

/** What the workspace has open, for suit's tray. */
typedef SuitRelayOpen = {
	var terminals:Int;
	var agents:Int;
}

/** A paired device as the daemon reports it to suit: no keys or tokens. */
typedef SuitRelayReportedDevice = {
	var deviceId:String;
	var grants:Array<String>;
	var connected:Bool;
}

/** The daemon's client report (kind 0x11). */
typedef SuitRelayClientReport = {
	var devices:Array<SuitRelayReportedDevice>;
	/** Device ids of pairing requests waiting for approval. */
	var pending:Array<String>;
	var open:SuitRelayOpen;
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
	byte for byte what the Worker sends and receives (first byte 1 for data, 2 for a channel reset;
	suit itself sends 3 to the Worker to close a client), or a
	suit status message: the byte 0x10 followed by JSON `{connected, error}`. suit reads only the envelope's
	channel id; the payload is a Noise handshake message or Noise ciphertext.

	The daemon also sends a client report when it changes: the byte 0x11 followed by JSON
	`{devices: [{deviceId, grants, connected}], pending: [deviceId], open: {terminals, agents}}`, so suit
	can show who is connected and what the workspace has open. It holds no keys or tokens.
**/
class SuitRelayProtocol {
	public static inline var VERSION:Int = 1;
	public static inline var ATTACH_OP:String = "relay-attach";
	public static inline var STATUS_KIND:Int = 0x10;
	public static inline var CLIENTS_KIND:Int = 0x11;

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

	public static function statusMessage(status:SuitRelayLinkStatus):Bytes
		return tagged(STATUS_KIND, Json.stringify({connected: status.connected, error: status.error}));

	public static function clientsMessage(report:SuitRelayClientReport):Bytes
		return tagged(CLIENTS_KIND, Json.stringify(report));

	/** Parses and checks a client report; null when it is not one or is malformed. */
	public static function parseClients(message:Bytes):Null<SuitRelayClientReport> {
		if (message == null || message.length < 2 || message.get(0) != CLIENTS_KIND)
			return null;
		var value:Dynamic = Json.parse(Bytes.view(message, 1, message.length - 1).toString());
		if (value == null || !Reflect.isObject(value))
			return null;
		var devices:Array<SuitRelayReportedDevice> = [];
		var listed:Dynamic = Reflect.field(value, "devices");
		if (Std.isOfType(listed, Array))
			for (item in (listed : Array<Dynamic>)) {
				var id:Dynamic = Reflect.field(item, "deviceId");
				if (!Std.isOfType(id, String))
					continue;
				var grants:Array<String> = [];
				var rawGrants:Dynamic = Reflect.field(item, "grants");
				if (Std.isOfType(rawGrants, Array))
					for (grant in (rawGrants : Array<Dynamic>))
						if (Std.isOfType(grant, String))
							grants.push(grant);
				devices.push({deviceId: id, grants: grants, connected: Reflect.field(item, "connected") == true});
			}
		var pending:Array<String> = [];
		var waiting:Dynamic = Reflect.field(value, "pending");
		if (Std.isOfType(waiting, Array))
			for (id in (waiting : Array<Dynamic>))
				if (Std.isOfType(id, String))
					pending.push(id);
		var open:Dynamic = Reflect.field(value, "open");
		return {devices: devices, pending: pending, open: {terminals: count(open, "terminals"), agents: count(open, "agents")}};
	}

	static function count(value:Dynamic, field:String):Int {
		var raw:Dynamic = value == null ? null : Reflect.field(value, field);
		return Std.isOfType(raw, Int) ? raw : Std.isOfType(raw, Float) ? Std.int(raw) : 0;
	}

	static function tagged(kind:Int, json:String):Bytes {
		var text = Bytes.ofString(json);
		var message = Bytes.alloc(text.length + 1);
		message.set(0, kind);
		message.blit(1, text, 0, text.length);
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

	/**
		A daemon uses suit unless `EXOSUIT_RELAY_VIA_SUIT=0` or `EXOSUIT_SUIT` is off (tests and the
		run guard), so a test reaches at most its own isolated suit, never the user's.
	**/
	public static function viaSuitEnabled():Bool {
		if (Sys.getEnv("EXOSUIT_RELAY_VIA_SUIT") == "0")
			return false;
		return SuitClient.mode() != SuitMode.Off;
	}
}
