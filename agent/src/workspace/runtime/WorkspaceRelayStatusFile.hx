package workspace.runtime;

import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;

/**
	Publishes this daemon's relay hosting state as `relay-status.json` in its private state directory, so
	the suit tray daemon can show it without an RPC client. It holds the relay origin, the connection
	state, the last error and device ids with their connected and revoked flags. It never holds bearers,
	tokens, keys or pairing codes.

	Rewritten when the state changes, and every 30 s so readers can tell a live file from a stale one.
**/
class WorkspaceRelayStatusFile {
	static inline var CHECK_MILLISECONDS:Float = 2000;
	static inline var REFRESH_MILLISECONDS:Float = 30000;

	final path:String;
	var checkedAt:Float = -1e12;
	var writtenAt:Float = -1e12;
	var written:String = "";

	public function new(stateDirectory:String) {
		path = Path.join([stateDirectory, "relay-status.json"]);
	}

	public function update(now:Float, relay:Null<WorkspaceRelayHost>, pairing:Null<WorkspacePairingManager>, setupError:Null<String>):Void {
		if (now - checkedAt < CHECK_MILLISECONDS)
			return;
		checkedAt = now;
		try {
			var devices:Array<Dynamic> = [];
			var pending = 0;
			if (pairing != null) {
				for (device in pairing.listDevices())
					devices.push({deviceId: device.deviceId, connected: device.connected, revoked: device.revoked});
				pending = pairing.listPending().length;
			}
			var error = setupError != null ? setupError : relay == null ? null : relay.lastError;
			var state = Json.stringify({
				configured: true,
				connected: relay != null && relay.connected,
				origin: relay == null ? null : relay.pairingEndpoint().origin,
				error: error,
				devices: devices,
				pending: pending
			});
			if (state == written && now - writtenAt < REFRESH_MILLISECONDS)
				return;
			var document = state.substr(0, state.length - 1) + ',"version":1,"pid":' + Sys.getPid() + ',"updatedAt":' + Date.now().getTime() + "}";
			sys.io.AtomicFile.write(path, document + "\n");
			written = state;
			writtenAt = now;
		} catch (_:Dynamic) {}
	}

	public function remove():Void {
		try if (FileSystem.exists(path)) FileSystem.deleteFile(path) catch (_:Dynamic) {}
	}
}
