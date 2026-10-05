package app;

import NativeKitRuntime;
import nativekit.ffi.NativeKit;
import workspace.transport.NativeRpcHub;
import workspace.transport.WorkspaceRpcServer;
import workspace.transport.SessionPreflight;
import workspace.service.WorkspaceService;
import workspace.storage.WorkspaceSqliteStore;

/** Catalog daemon. The managed launcher owns exclusive startup and discovery. */
class AgentMain {
	static function main():Void {
		var args = Sys.args();
		if (args.length < 4 || args.length > 6)
			throw "Usage: exosuit-agent PRIVATE_SOCKET LOOPBACK_WS_PORT TOKEN_FILE SEED_EPOCH [DATABASE [WORKSPACE_ROOT]]";
		var port = Std.parseInt(args[1]);
		var metadata = sys.FileSystem.metadata(args[2]);
		if (metadata == null || metadata.size != 64)
			throw "Invalid session credential file size";
		var token = sys.io.File.getContent(args[2]);
		SessionPreflight.validateToken(token);
		var runtime = NativeKitRuntime.start(),
			hub = new NativeRpcHub(runtime.events);
		var clock = function() return NativeKit.nk_time_seconds() * 1000;
		// The seed epoch is used only when creating a new catalog. Reopening preserves it.
		var seed = new WorkspaceService("workspace", args[3], [
			{
				id: "work",
				name: "Work",
				cwd: args.length == 6 ? args[5] : Sys.getCwd(),
				revision: 1
			}
		]);
		var store = args.length >= 5 ? new WorkspaceSqliteStore(args[4], "workspace", seed.snapshot()) : null;
		var service = store == null ? seed : new WorkspaceService("workspace", args[3], seed.snapshot().groups, 32, 256, 16, store);
		if (args.length == 6 && (service.snapshot().groups.length != 1 || service.snapshot().groups[0].cwd != args[5]))
			throw "Workspace database root mismatch";
		var server = new WorkspaceRpcServer(service, clock);
		var local = hub.listen(NativeRpcHub.local(args[0]), server.acceptLocal);
		var websocket = hub.listen(NativeRpcHub.websocket(port, "/workspace", true), function(transport) {
			server.acceptWebSocket(transport, token);
		});
		Sys.println("READY: exosuit-agent local and loopback WebSocket");
		Sys.stdout().flush();
		while (true) {
			runtime.events.wait(0.01);
			for (_ in 0...128)
				if (!runtime.events.poll())
					break;
			server.poll();
		}
	}
}
