package app;

import haxeon.platform.NativeKitRuntime;
import nativekit.ffi.NativeKit;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.AtomicFile;
import workspace.transport.NativeRpcHub;
import workspace.transport.WorkspaceRpcServer;
import workspace.transport.SessionPreflight;
import workspace.service.WorkspaceService;
import workspace.service.WorkspaceLifetime;
import workspace.storage.WorkspaceSqliteStore;
import workspace.runtime.WorkspaceTerminalManager;
import workspace.runtime.WorkspaceRelayHost;
import workspace.runtime.WorkspaceRelaySettings;
import workspace.runtime.WorkspaceCredentialStores;
import workspace.runtime.WorkspaceNoiseIdentity;
import workspace.transport.NoiseMessageTransport;
import workspace.runtime.WorkspacePairingManager;
import workspace.runtime.WorkspaceRelayStatusFile;
import suit.relay.SuitRelayProtocol;
import suit.relay.SuitRelayProtocol.SuitRelayAttachRequest;
import suit.relay.SuitRelayProtocol.SuitRelayReportedDevice;

/** Catalog daemon. The managed launcher owns exclusive startup and discovery. */
class AgentMain {
	static function main():Void {
		var args = Sys.args();
		AgentManagerNative.guardChildLock();
		if (args.length > 0 && args[0] == "--manager") {
			Sys.exit(AgentManager.run(args.slice(1)));
			return;
		}
		var stableLease:Null<String> = null;
		var stableBundle = Sys.getEnv("EXOSUIT_STABLE_BUNDLE");
		if (stableBundle != null && stableBundle.length > 0) {
			stableBundle = FileSystem.fullPath(stableBundle);
			if (!FileSystem.isDirectory(stableBundle)) throw "Stable workspace-agent snapshot is missing";
			stableLease = Path.join([stableBundle, ".running-daemon-" + Sys.getPid()]);
			AtomicFile.create(stableLease, Std.string(Sys.getPid()) + "\n");
		}
		if (args.length < 4 || args.length > 9)
			throw "Usage: exosuit-agent PRIVATE_SOCKET LOOPBACK_WS_PORT TOKEN_FILE SEED_EPOCH [DATABASE [WORKSPACE_ROOT [INSTANCE [IDLE_MILLISECONDS [RELAY_BOOTSTRAP]]]]]";
		// Settles EXOSUIT_SUIT once, before this daemon spawns terminals or compiler workers, so they inherit it.
		suit.SuitClient.resolve(haxe.io.Path.directory(args[2]));
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
		var relayRoot = FileSystem.fullPath(args.length >= 6 ? args[5] : Sys.getCwd());
		// suit holds the machine socket when it runs, so a device can reach this workspace with no editor open.
		function suitAttach(settings:WorkspaceRelaySettings):Null<SuitRelayAttachRequest> {
			if (!SuitRelayProtocol.viaSuitEnabled())
				return null;
			return {
				root: relayRoot,
				stateDir: haxe.io.Path.directory(args[2]),
				machineId: settings.endpoint.machineId,
				origin: settings.endpoint.origin,
				executable: Sys.executablePath(),
				launcher: FileSystem.fullPath(Sys.programPath())
			};
		}
		if (args.length == 9) {
			try {
				var settings = WorkspaceRelaySettings.loadBootstrap(args[8]);
				relayHost = new WorkspaceRelayHost(runtime.events, hub, settings, allowLoopbackHttp, suitAttach(settings));
			} catch (error:Dynamic) relaySetupError = Std.string(error);
		}
		var directories = new workspace.runtime.WorkspaceDirectories(args.length >= 6 ? args[5] : Sys.getCwd());
		var files = new workspace.runtime.WorkspaceFileService("workspace", [directories.root], clock, runtime.events);
		var scm = new workspace.runtime.WorkspaceScmService("workspace", [directories.root], processes, Sys.getEnv("EXOSUITE_GIT_BIN"));
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
		var claudeExecutable = Sys.getEnv("EXOSUIT_CLAUDE_BIN");
        var claude = new workspace.provider.ClaudeProvider(directories, function() return service.snapshot().groups, processes, clock, store,
            process.ExecutablePath.resolve(claudeExecutable == null ? "claude" : claudeExecutable), Sys.getEnv("EXOSUIT_CLAUDE_SCRIPT"));
        var piExecutable = Sys.getEnv("EXOSUIT_PI_BIN");
        var pi = new workspace.provider.PiProvider(directories, function() return service.snapshot().groups, processes, clock,
            haxe.io.Path.directory(args[2]), store, process.ExecutablePath.resolve(piExecutable == null ? "pi" : piExecutable), Sys.getEnv("EXOSUIT_PI_SCRIPT"));
        var agentKitSettings = workspace.provider.AgentKitSettings.fromEnvironment(haxe.io.Path.join([haxe.io.Path.directory(args[2]), "agentkit"]));
        var agentKit = new workspace.provider.AgentKitProvider(directories, function() return service.snapshot().groups, clock,
            new haxeon.agent.nativekit.NativeKitHttpTransport(runtime.events, agentKitSettings.allowsPlainHttp()), agentKitSettings, store);
        var codex = new workspace.provider.CodexProvider(args.length >= 7 ? args[6] : args[3], directories,
            function() return service.snapshot().groups, processes, clock, store,
            process.ExecutablePath.resolve(executable == null ? "codex" : executable), Sys.getEnv("EXOSUIT_CODEX_PROXY_LAUNCHER"), codexScript);
        var agents = new workspace.provider.WorkspaceAgentService("workspace", args.length >= 7 ? args[6] : args[3],
            directories.root, [codex, claude, pi, agentKit], store);
		service.canRemoveGroup = function(group) {
			for (terminal in terminals.snapshot().terminals) if (terminal.group == group) return false;
			return agents.groupIsEmpty(group);
		};
		var noiseIdentity:Null<WorkspaceNoiseIdentity> = null;
		if (relayHost != null && store == null)
			throw "Remote workspace access requires persistent device storage";
		var serverRef:Null<WorkspaceRpcServer> = null;
		var pairingManager:Null<WorkspacePairingManager> = null;
		function installPairing():Void {
			if (relayHost == null || store == null) throw "Remote access requires persistent workspace storage";
			noiseIdentity = new WorkspaceNoiseIdentity(relayHost.endpoint.machineId, WorkspaceCredentialStores.relay());
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
			terminals, agents, pairingManager, files, scm);
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
		var stateDirectory = haxe.io.Path.directory(args[2]);
		suit.SuitClient.registerWorkspaceService(suit.SuitKind.WorkspaceHost, {root: directories.root, stateDir: stateDirectory,
			generation: args.length >= 7 ? args[6] : null});
		var relayStatus = new WorkspaceRelayStatusFile(stateDirectory);
		var clientReportAt:Float = 0;
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
						relayHost = new WorkspaceRelayHost(runtime.events, hub, settings, allowLoopbackHttp, suitAttach(settings));
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
			if (relayHost != null || relaySetupError != null)
				relayStatus.update(clock(), relayHost, pairingManager, relaySetupError);
			if (relayHost != null && relayHost.viaSuit && clock() >= clientReportAt) {
				clientReportAt = clock() + 1000;
				var devices:Array<SuitRelayReportedDevice> = [], pendingDevices:Array<String> = [];
				if (pairingManager != null) {
					for (device in pairingManager.listDevices())
						if (!device.revoked)
							devices.push({deviceId: device.deviceId, grants: device.grants, connected: device.connected});
					for (request in pairingManager.listPending())
						pendingDevices.push(request.deviceId);
				}
				relayHost.reportClients({devices: devices, pending: pendingDevices,
					open: {terminals: terminals.activeCount(), agents: agents.activeCount()}});
			}
			server.poll();
			files.poll();
			scm.poll();
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
		relayStatus.remove();
		suit.SuitClient.unregister();
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
		if (stableLease != null && FileSystem.exists(stableLease))
			try FileSystem.deleteFile(stableLease) catch (_:Dynamic) {}
	}
}
