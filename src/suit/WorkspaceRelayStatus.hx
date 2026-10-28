package suit;

import haxe.Json;
import haxe.io.Path;

/** One paired device in a relay status: its id and state only, never keys or tokens. */
typedef WorkspaceRelayDevice = {
	var deviceId:String;
	var connected:Bool;
	var revoked:Bool;
}

/** What a hosting workspace daemon reports about its relay connection. */
typedef WorkspaceRelayState = {
	var configured:Bool;
	var connected:Bool;
	/** True while suit holds the machine socket for this daemon; false while the daemon holds it itself. */
	var viaSuit:Bool;
	var origin:Null<String>;
	var error:Null<String>;
	var devices:Array<WorkspaceRelayDevice>;
	var pending:Int;
}

/**
	`relay-status.json` in a workspace daemon's private state directory, which suit reads to show relay
	hosting without an RPC client (SuitInventory.readRelay). The document is the WorkspaceRelayState fields
	plus `version`, the writer's `pid`, and `updatedAt` (ms since the epoch), so a reader can tell a live
	file from a stale one. It never holds bearers, tokens, keys or pairing codes.
**/
class WorkspaceRelayStatus {
	public static inline var FILE_NAME:String = "relay-status.json";
	public static inline var VERSION:Int = 1;

	public static function path(stateDir:String):String
		return Path.join([stateDir, FILE_NAME]);

	/** The JSON document for `state`, written by `pid` at `updatedAt`. */
	public static function encode(state:WorkspaceRelayState, pid:Int, updatedAt:Float):String {
		return Json.stringify({
			version: VERSION,
			pid: pid,
			updatedAt: updatedAt,
			configured: state.configured,
			connected: state.connected,
			viaSuit: state.viaSuit,
			origin: state.origin,
			error: state.error,
			devices: [
				for (device in state.devices)
					{deviceId: device.deviceId, connected: device.connected, revoked: device.revoked}
			],
			pending: state.pending
		});
	}
}
