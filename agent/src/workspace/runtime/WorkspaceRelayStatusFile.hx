package workspace.runtime;

import suit.WorkspaceRelayStatus;
import sys.FileSystem;

/**
	Publishes this daemon's relay hosting state as `relay-status.json` in its private state directory, so
	the suit tray daemon can show it without an RPC client. The format is WorkspaceRelayStatus's.

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
		path = WorkspaceRelayStatus.path(stateDirectory);
	}

	public function update(now:Float, relay:Null<WorkspaceRelayHost>, pairing:Null<WorkspacePairingManager>, setupError:Null<String>):Void {
		if (now - checkedAt < CHECK_MILLISECONDS)
			return;
		checkedAt = now;
		try {
			var devices:Array<WorkspaceRelayDevice> = [];
			var pending = 0;
			if (pairing != null) {
				for (device in pairing.listDevices())
					devices.push({deviceId: device.deviceId, connected: device.connected, revoked: device.revoked});
				pending = pairing.listPending().length;
			}
			var state:WorkspaceRelayState = {
				configured: true,
				connected: relay != null && relay.connected,
				viaSuit: relay != null && relay.viaSuit,
				origin: relay == null ? null : relay.pairingEndpoint().origin,
				error: setupError != null ? setupError : relay == null ? null : relay.lastError,
				devices: devices,
				pending: pending
			};
			// The state alone, without the volatile pid and time, decides whether the file is rewritten early.
			var key = WorkspaceRelayStatus.encode(state, 0, 0);
			if (key == written && now - writtenAt < REFRESH_MILLISECONDS)
				return;
			sys.io.AtomicFile.write(path, WorkspaceRelayStatus.encode(state, Sys.getPid(), Date.now().getTime()) + "\n");
			written = key;
			writtenAt = now;
		} catch (_:Dynamic) {}
	}

	public function remove():Void {
		try if (FileSystem.exists(path)) FileSystem.deleteFile(path) catch (_:Dynamic) {}
	}
}
