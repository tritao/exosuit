package app;

import NativeKitRuntime;
import nativekit.ffi.NativeKit;
import workspace.transport.NativeRpcHub;
import workspace.transport.WorkspaceRpcServer;
import workspace.transport.SessionPreflight;
import workspace.service.WorkspaceService;

/** Bootstrap catalog daemon. Durable storage/runtime supervision follow separately. */
class AgentMain {
	static function main():Void {
		var args = Sys.args();
		if (args.length != 4)
			throw "Usage: exosuit-agent PRIVATE_SOCKET LOOPBACK_WS_PORT TOKEN_FILE FRESH_EPOCH";
		var port = Std.parseInt(args[1]);
		var metadata = sys.FileSystem.metadata(args[2]);
		if (metadata == null || metadata.size != 64)
			throw "Invalid session credential file size";
		var token = sys.io.File.getContent(args[2]);
		SessionPreflight.validateToken(token);
		var runtime = NativeKitRuntime.start(),
			hub = new NativeRpcHub(runtime.events);
		var clock = function() return NativeKit.nk_time_seconds() * 1000;
		// Each startup receives a fresh, cryptographically generated credential/epoch.
		var service = new WorkspaceService("workspace", args[3], [
			{
				id: "work",
				name: "Work",
				cwd: Sys.getCwd(),
				revision: 1
			}
		]);
		var server = new WorkspaceRpcServer(service, clock);
		var local = hub.listen(NativeRpcHub.local(args[0]), server.acceptLocal);
		var websocket = hub.listen(NativeRpcHub.websocket(port, "/workspace", true), function(transport) {
			server.acceptWebSocket(transport, token);
		});
		Sys.println("READY: exosuit-agent local and loopback WebSocket");
		while (true) {
			runtime.events.wait(0.01);
			for (_ in 0...128)
				if (!runtime.events.poll())
					break;
			server.poll();
		}
	}
}
