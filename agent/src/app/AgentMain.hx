package app;

import haxeon.platform.NativeKitRuntime;
import nativekit.ffi.NativeKit;
import workspace.transport.NativeRpcHub;
import workspace.transport.WorkspaceRpcServer;
import workspace.transport.SessionPreflight;
import workspace.service.WorkspaceService;
import workspace.service.WorkspaceLifetime;
import workspace.storage.WorkspaceSqliteStore;
import workspace.runtime.WorkspaceTerminalManager;
import workspace.runtime.WorkspaceRelayHost;
import workspace.runtime.WorkspaceRelaySettings;
import workspace.runtime.NativeWorkspaceCredentialStore;
import workspace.runtime.WorkspaceNoiseIdentity;
import workspace.transport.NoiseMessageTransport;
import workspace.runtime.WorkspacePairingManager;

/** Catalog daemon. The managed launcher owns exclusive startup and discovery. */
class AgentMain {
	static function main():Void {
		var args = Sys.args();
		AgentManagerNative.guardChildLock();
		if (args.length > 0 && args[0] == "--manager") {
			Sys.exit(AgentManager.run(args.slice(1)));
			return;
		}
		if (args.length < 4 || args.length > 9)
			throw "Usage: exosuit-agent PRIVATE_SOCKET LOOPBACK_WS_PORT TOKEN_FILE SEED_EPOCH [DATABASE [WORKSPACE_ROOT [INSTANCE [IDLE_MILLISECONDS [RELAY_BOOTSTRAP]]]]]";
		var idleMilliseconds = args.length >= 8 ? Std.parseInt(args[7]) : 60000;
		if (idleMilliseconds == null || idleMilliseconds < 0)
			throw "Invalid workspace idle timeout";
		var lifetime = new WorkspaceLifetime(idleMilliseconds);
		var port = Std.parseInt(args[1]);
		var metadata = sys.FileSystem.metadata(args[2]);
		if (metadata == null || metadata.size != 64)
			throw "Invalid session credential file size";
		var token = sys.io.File.getContent(args[2]);
		SessionPreflight.validateToken(token);
		var processes = new process.ProcessManager();
		var runtime = NativeKitRuntime.start(),
			hub = new NativeRpcHub(runtime.events);
		var clock = function() return NativeKit.nk_time_seconds() * 1000;
		// HTTP remains rejected by RelayMachineEndpoint except for loopback. This
		// opt-in exists for local Worker development and test runs only.
		var allowLoopbackHttp = Sys.getEnv("EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP") == "1";
		var relayHost:Null<WorkspaceRelayHost> = null;
		var relaySetupError:Null<String> = null;
		if (args.length == 9) {
			try relayHost = new WorkspaceRelayHost(runtime.events, hub, WorkspaceRelaySettings.loadBootstrap(args[8]), allowLoopbackHttp)
			catch (error:Dynamic) relaySetupError = Std.string(error);
		}
		var directories = new workspace.runtime.WorkspaceDirectories(args.length >= 6 ? args[5] : Sys.getCwd());
		var files = new workspace.runtime.WorkspaceFileService("workspace", [directories.root], clock, runtime.events);
		// The seed epoch is used only when creating a new catalog. Reopening preserves it.
		var seed = new WorkspaceService("workspace", args[3], [
			{
				id: "work",
				name: "Work",
				cwd: directories.root,
				revision: 1
			}
		]);
		var store = args.length >= 5 ? new WorkspaceSqliteStore(args[4], "workspace", seed.snapshot(), 32, directories.root) : null;
		var service = new WorkspaceService("workspace", args[3], seed.snapshot().groups, 32, 256, 16, store, directories.resolve);
		var terminals = new WorkspaceTerminalManager("workspace", args.length >= 7 ? args[6] : args[3], directories.root,16777216,store,function() return service.snapshot().groups);
		var executable = Sys.getEnv("EXOSUIT_CODEX_BIN");
		var codexScript = Sys.getEnv("EXOSUIT_CODEX_SCRIPT");
		var agents = new workspace.provider.CodexProvider("workspace", args.length >= 7 ? args[6] : args[3], directories, function() return service.snapshot().groups, processes, clock, store, executable == null ? "codex" : executable, Sys.getEnv("EXOSUIT_CODEX_PROXY_LAUNCHER"), codexScript);
		var noiseIdentity:Null<WorkspaceNoiseIdentity> = null;
		if (relayHost != null && store == null)
			throw "Remote workspace access requires persistent device storage";
		var serverRef:Null<WorkspaceRpcServer> = null;
		var pairingManager:Null<WorkspacePairingManager> = null;
		function installPairing():Void {
			if (relayHost == null || store == null) throw "Remote access requires persistent workspace storage";
			noiseIdentity = new WorkspaceNoiseIdentity(relayHost.endpoint.machineId, new NativeWorkspaceCredentialStore());
			var activeStore = store, activeRelay = relayHost, activeIdentity = noiseIdentity;
			pairingManager = new WorkspacePairingManager(activeStore, activeRelay, activeIdentity.privateKeyForHandshake(),
				function() return serverRef == null ? [] : serverRef.options.offered(), clock,
				function(secure, grants) {
					var current = serverRef;
					if (current == null)
						secure.close();
					else
						current.acceptRemote(secure, grants);
				});
			relayHost.onChannel = function(channel) pairingManager.acceptChannel(channel.channelId, channel);
		}
		if (relayHost != null) {
			try installPairing() catch (error:Dynamic) {
				relayHost.dispose();
				relayHost = null;
				relaySetupError = Std.string(error);
			}
		}
		var server = new WorkspaceRpcServer(service, clock, null,
			args.length >= 7 ? {workspace: "workspace", root: directories.root, instance: args[6]} : null,
			terminals, agents, pairingManager, files);
		serverRef = server;
		var updates = new workspace.service.WorkspaceUpdatePolicy();
		var build = Sys.getEnv("EXOSUIT_AGENT_BUILD_ID");
		var updateRequestedAt:Float = 0;
		var restarting = false;
		if (Sys.getEnv("EXOSUIT_AGENT_MANAGED_UPDATES") == "1")
			server.enableLifecycle(function():workspace.service.WorkspaceLifecycleProtocol.WorkspaceServiceStatus return {
				protocol: workspace.service.WorkspaceLifecycleProtocol.VERSION,
				build: build == null ? "unknown" : build,
				terminals: terminals.activeCount(), agents: agents.updateActivityCount(), updatePending: updates.pending
			}, function(mode:String):Bool {
				if (!updates.request(mode)) return false;
				updateRequestedAt = clock();
				return true;
			});
		server.remoteAccessStatus = function() return {
			configured: relayHost != null,
			connected: relayHost != null && relayHost.connected,
			origin: relayHost == null ? null : relayHost.endpoint.origin,
			error: relaySetupError != null ? relaySetupError : relayHost == null ? null : relayHost.lastError
		};
		var setupPath = haxe.io.Path.directory(args[2]) + "/relay-bootstrap.json";
		var setupPollAt:Float = 0;
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
			if (relayHost == null && clock() >= setupPollAt) {
				setupPollAt = clock() + 500;
				if (sys.FileSystem.exists(setupPath)) {
					try {
						var settings = WorkspaceRelaySettings.loadBootstrap(setupPath);
						relayHost = new WorkspaceRelayHost(runtime.events, hub, settings, allowLoopbackHttp);
						installPairing();
						server.enablePairing(pairingManager);
						relaySetupError = null;
					} catch (error:Dynamic) {
						if (relayHost != null) relayHost.dispose();
						relayHost = null;
						relaySetupError = Std.string(error);
					}
				}
			}
			server.poll();
			files.poll();
			// Runtime ownership survives client disconnects.
			terminals.poll();
			agents.poll();
			if (relayHost != null) {
				relayHost.poll(clock());
				if (pairingManager != null)
					pairingManager.poll();
			}
			var remoteAccess = relayHost == null ? 0 : relayHost.activeCount();
			// Allow the update acknowledgement to flush before disconnecting clients.
			if (clock() - updateRequestedAt >= 250 && updates.shouldRestart(terminals.activeCount(), agents.updateActivityCount())) {
				restarting = true;
				break;
			}
			if (lifetime.shouldStop(clock(), server.clientCount(), terminals.activeCount() + agents.activeCount() + remoteAccess))
				break;
		}
		if (pairingManager != null)
			pairingManager.dispose();
		if (relayHost != null)
			relayHost.dispose();
		agents.dispose();
		processes.shutdown();
		terminals.dispose();
		server.dispose();
		files.dispose();
		hub.dispose();
		if (store != null)
			store.close();
		if (noiseIdentity != null)
			noiseIdentity.dispose();
		runtime.dispose();
		Sys.println(restarting ? "STOPPED: exosuit-agent update" : "STOPPED: exosuit-agent idle");
		Sys.stdout().flush();
	}
}
