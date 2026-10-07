package app;

import haxe.Json;
import haxe.io.Bytes;
import haxeon.credentials.Credentials;
import haxeon.platform.NativeKitRuntime;
import haxeon.rpc.RpcClient;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcPeerOptions;
import nativekit.ffi.NativeKit;
import noisekit.NoiseSession;
import workspace.runtime.WorkspacePairingManager;
import workspace.runtime.WorkspaceRelayHost;
import workspace.runtime.WorkspaceRelaySettings;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspacePairingProtocol;
import workspace.service.WorkspacePairingProtocol.PendingPairing;
import workspace.service.WorkspacePairingProtocol.PairingDevice;
import workspace.service.WorkspaceService;
import workspace.storage.WorkspaceSqliteStore;
import workspace.runtime.WorkspaceDirectories;
import workspace.transport.NativeRpcHub;
import workspace.transport.NativeRpcConnector;
import workspace.transport.RelayMachineEndpoint;
import workspace.transport.WorkspaceRpcServer;

/** Runs the real machine-side first-pair path against a local Wrangler Worker. */
class BrowserPairingHostMain {
	static function require(value:Bool, message:String):Void {
		if (!value) throw message;
	}

	static function main():Void {
		var args = Sys.args();
		if (args.length == 2 && args[0] == "--agent-admin") {
			runAgentAdmin(args[1]);
			return;
		}
		if (args.length == 3 && args[0] == "--cleanup-credentials") {
			cleanupTestCredentials(args[1], args[2]);
			return;
		}
		if (args.length != 1)
			throw "Expected a private browser-pairing test config file";
		var configPath = args[0];
		if (!sys.FileSystem.exists(configPath))
			throw "Invalid browser-pairing test config file";
		var config:Dynamic = Json.parse(sys.io.File.getContent(configPath));
		var origin:String = config.origin, machineId:String = config.machineId, machineToken:String = config.machineToken,
			workspaceRoot:String = config.workspaceRoot, invitePath:String = config.invitePath,
			statusPath:String = config.statusPath, decisionPath:String = config.decisionPath,
			successPath:String = config.successPath, databasePath:String = config.databasePath,
			localSocket:String = config.localSocket;
		sys.FileSystem.createDirectory(workspaceRoot);
		var directories = new WorkspaceDirectories(workspaceRoot);
		var seed = new WorkspaceService("workspace", "browser-pairing-epoch", [
			{id: "work", name: "Browser pairing test", cwd: directories.root, revision: 1}
		]);
		var runtime = NativeKitRuntime.start(), hub = new NativeRpcHub(runtime.events),
			clock = function() return NativeKit.nk_time_seconds() * 1000,
			endpoint = new RelayMachineEndpoint(origin, machineId),
			relay = new WorkspaceRelayHost(runtime.events, hub, new WorkspaceRelaySettings(endpoint, machineToken), true),
		store = new WorkspaceSqliteStore(databasePath, "workspace", seed.snapshot(), 32, directories.root);
		var machineKeys = NoiseSession.generateKeypair();
		var server:Null<WorkspaceRpcServer> = null;
		var pairing = new WorkspacePairingManager(store, relay, machineKeys.privateKey,
			function() return server == null ? [WorkspaceProtocol.READ, WorkspaceProtocol.IDENTITY_CAPABILITY] : server.options.offered(),
			clock, function(secure, grants) {
				if (server == null) secure.close(); else server.acceptRemote(secure, grants);
			});
		server = new WorkspaceRpcServer(new WorkspaceService("workspace", "browser-pairing-epoch", seed.snapshot().groups,
			32, 256, 16, store, directories.resolve), clock, null,
			{workspace: "workspace", root: directories.root, instance: "browser-pairing-test"}, null, null, pairing);
		relay.onChannel = function(channel) pairing.acceptChannel(channel.channelId, channel);
		var localListener = hub.listen(NativeRpcHub.local(localSocket), server.acceptLocal);
		var failure:Null<String> = null, localConnection:Null<RpcConnection> = null;
		var localAdmin = new RpcClient(new NativeRpcConnector(hub, NativeRpcHub.local(localSocket)), clock,
			function() return 0.5,
			new RpcPeerOptions("exosuit-editor/1", [WorkspaceProtocol.READ, WorkspaceProtocol.EVENTS,
				WorkspaceProtocol.WRITE, WorkspaceProtocol.TREE, WorkspaceProtocol.IDENTITY_CAPABILITY,
				WorkspacePairingProtocol.ADMIN], [WorkspaceProtocol.READ, WorkspaceProtocol.EVENTS,
				WorkspaceProtocol.IDENTITY_CAPABILITY], 2000, 262144, 32, 1048576),
			function(connection, generation, _) {
				localConnection = connection;
			}, 10, 100, 2000);

		var invitationStarted = false, invitationReady = false, approved = false,
			approvalRequestPending = false, listRequestPending = false;
		var registeredDevice:String = "";
		var visiblePending:Array<PendingPairing> = [], deadline = clock() + 90000,
			nextStatusWrite = 0.0, nextListRequest = 0.0;
		while (clock() < deadline && failure == null) {
			runtime.events.wait(0.01);
			for (_ in 0...128) if (!runtime.events.poll()) break;
			relay.poll(clock());
			server.poll();
			pairing.poll();
			localAdmin.poll();

			var adminConnection = localConnection;
			if (relay.connected && adminConnection != null && !invitationStarted) {
				invitationStarted = true;
				adminConnection.call(WorkspacePairingProtocol.CREATE, {ttlSeconds: 60}, 10000, function(value) {
					registeredDevice = value.deviceId;
					writePrivate(invitePath, Json.stringify({pairingSocketUrl: value.pairingSocketUrl,
						machineId: value.machineId, deviceId: value.deviceId}));
					invitationReady = true;
				}, function(error) {
					failure = "local pairing invitation RPC failed: " + error.code;
				});
			}

			if (adminConnection != null && !listRequestPending && clock() >= nextListRequest) {
				listRequestPending = true;
				nextListRequest = clock() + 200;
				adminConnection.call(WorkspacePairingProtocol.LIST, {}, 2000, function(value) {
					listRequestPending = false;
					visiblePending = value.pending;
				}, function(error) {
					listRequestPending = false;
					failure = "local pairing list RPC failed: " + error.code;
				});
			}
			if (invitationReady && !approved && !approvalRequestPending && sys.FileSystem.exists(decisionPath)) {
				var decision:Dynamic = Json.parse(sys.io.File.getContent(decisionPath));
				var matched = false;
				for (candidate in visiblePending) {
					if (candidate.deviceId == decision.deviceId && candidate.authenticationCode == decision.authenticationCode) {
						matched = true;
						break;
					}
				}
				require(matched, "browser and desktop authentication codes did not match");
				approvalRequestPending = true;
				adminConnection.call(WorkspacePairingProtocol.APPROVE, {deviceId: registeredDevice,
					grants: [WorkspaceProtocol.READ, WorkspaceProtocol.IDENTITY_CAPABILITY]}, 10000, function(result) {
					if (!result.accepted) failure = "local pairing approval was refused: " + result.error;
					else approved = true;
				}, function(error) {
					failure = "local pairing approval RPC failed: " + error.code;
				});
			}

			if (clock() >= nextStatusWrite) {
				writePrivate(statusPath, Json.stringify({ready: relay.connected && invitationReady,
					pending: visiblePending, approved: approved, activeClients: server.clientCount() - (localAdmin.current() == null ? 0 : 1),
					failure: failure, workspaceRoot: workspaceRoot}));
				nextStatusWrite = clock() + 200;
			}
			if (server.clientCount() > 0 && approved && sys.FileSystem.exists(successPath)) {
				var result:Dynamic = Json.parse(sys.io.File.getContent(successPath));
				require(result.machineId == machineId && result.deviceId == registeredDevice
					&& result.workspaceRoot == workspaceRoot, "browser reported a different workspace identity");
				verifyPersistedDevice(store, registeredDevice);
				localAdmin.close();
				hub.forget(localListener);
				store.close();
				store = new WorkspaceSqliteStore(databasePath, "workspace", seed.snapshot(), 32, directories.root);
				verifyPersistedDevice(store, registeredDevice);
				pairing.dispose();
				relay.dispose();
				server.dispose();
				hub.dispose();
				store.close();
				runtime.dispose();
				Sys.println("PASS: browser completed Noise pairing, desktop approval, authenticated RPC and SQLite trust reload");
				return;
			}
		}
		pairing.dispose();
		relay.dispose();
		localAdmin.close();
		hub.forget(localListener);
		server.dispose();
		hub.dispose();
		store.close();
		throw failure == null ? "Browser pairing test timed out" : failure;
	}

	/** Drives the real daemon's same-user pairing RPC from the browser E2E harness. */
	static function runAgentAdmin(configPath:String):Void {
		var config:Dynamic = Json.parse(sys.io.File.getContent(configPath));
		var machineId:String = config.machineId, origin:String = config.origin,
			workspaceRoot:String = config.workspaceRoot, invitePath:String = config.invitePath,
			statusPath:String = config.statusPath, decisionPath:String = config.decisionPath,
			successPath:String = config.successPath, localSocket:String = config.localSocket;
		var runtime = NativeKitRuntime.start(), hub = new NativeRpcHub(runtime.events),
			clock = function() return NativeKit.nk_time_seconds() * 1000;
		var localConnection:Null<RpcConnection> = null;
		var client = new RpcClient(new NativeRpcConnector(hub, NativeRpcHub.local(localSocket)), clock,
			function() return 0.5,
			new RpcPeerOptions("exosuit-editor/1", [WorkspaceProtocol.READ, WorkspaceProtocol.EVENTS,
				WorkspaceProtocol.WRITE, WorkspaceProtocol.TREE, WorkspaceProtocol.IDENTITY_CAPABILITY,
				WorkspacePairingProtocol.ADMIN], [WorkspaceProtocol.READ, WorkspaceProtocol.EVENTS,
				WorkspaceProtocol.IDENTITY_CAPABILITY], 2000, 262144, 32, 1048576),
			function(connection, generation, _) localConnection = connection, 10, 100, 2000);
		var invitationStarted = false, invitationReady = false, approved = false,
			approvalPending = false, listPending = false;
		var deviceId:String = "", visiblePending:Array<PendingPairing> = [],
			visibleDevices:Array<PairingDevice> = [];
		var deadline = clock() + 180000, nextStatusWrite = 0.0, nextListRequest = 0.0,
			failure:Null<String> = null;
		while (clock() < deadline && failure == null) {
			runtime.events.wait(0.01);
			for (_ in 0...128) if (!runtime.events.poll()) break;
			client.poll();
			var connection = localConnection;
			if (connection != null && !invitationStarted) {
				invitationStarted = true;
				connection.call(WorkspacePairingProtocol.CREATE, {ttlSeconds: 120}, 10000, function(value) {
					if (value.machineId != machineId || value.relayOrigin != origin) {
						failure = "AgentMain returned an invitation for a different relay identity";
						return;
					}
					deviceId = value.deviceId;
					writePrivate(invitePath, Json.stringify({pairingSocketUrl: value.pairingSocketUrl,
						machineId: value.machineId, deviceId: value.deviceId}));
					invitationReady = true;
				}, function(error) {
					failure = "AgentMain invitation RPC failed: " + error.code;
				});
			}
			if (connection != null && !listPending && clock() >= nextListRequest) {
				listPending = true;
				nextListRequest = clock() + 200;
				connection.call(WorkspacePairingProtocol.LIST, {}, 2000, function(value) {
					listPending = false;
					visiblePending = value.pending;
					visibleDevices = value.devices;
				}, function(error) {
					listPending = false;
					failure = "AgentMain pairing-list RPC failed: " + error.code;
				});
			}
			if (invitationReady && !approved && !approvalPending && sys.FileSystem.exists(decisionPath)) {
				var decision:Dynamic = Json.parse(sys.io.File.getContent(decisionPath));
				var matched = false;
				for (candidate in visiblePending)
					if (candidate.deviceId == decision.deviceId && candidate.authenticationCode == decision.authenticationCode)
						matched = true;
				if (!matched) {
					failure = "Browser and AgentMain authentication codes did not match";
				} else {
					approvalPending = true;
					connection.call(WorkspacePairingProtocol.APPROVE, {deviceId: deviceId,
						grants: [WorkspaceProtocol.READ, WorkspaceProtocol.IDENTITY_CAPABILITY]}, 10000, function(result) {
						if (!result.accepted) failure = "AgentMain refused pairing approval: " + result.error;
						else approved = true;
					}, function(error) {
						failure = "AgentMain pairing-approval RPC failed: " + error.code;
					});
				}
			}
			if (clock() >= nextStatusWrite) {
				var connected = false;
				for (device in visibleDevices)
					if (device.deviceId == deviceId && !device.revoked && device.connected) connected = true;
				writePrivate(statusPath, Json.stringify({ready: invitationReady, pending: visiblePending,
					approved: approved, activeClients: connected ? 1 : 0, failure: failure,
					workspaceRoot: workspaceRoot}));
				nextStatusWrite = clock() + 200;
			}
			if (approved && sys.FileSystem.exists(successPath)) {
				var result:Dynamic = Json.parse(sys.io.File.getContent(successPath));
				if (result.machineId != machineId || result.deviceId != deviceId || result.workspaceRoot != workspaceRoot)
					failure = "Browser reported a different AgentMain workspace identity";
				else {
					var connected = false;
					for (device in visibleDevices)
						if (device.deviceId == deviceId && !device.revoked && device.connected) connected = true;
					require(connected, "AgentMain did not retain the reconnected browser device");
					writePrivate(statusPath, Json.stringify({ready: true, pending: visiblePending,
						approved: true, activeClients: 1, failure: null, workspaceRoot: workspaceRoot}));
					client.close();
					hub.dispose();
					runtime.dispose();
					Sys.println("PASS: browser paired and reconnected through AgentMain's local admin RPC");
					return;
				}
			}
		}
		client.close();
		hub.dispose();
		runtime.dispose();
		throw failure == null ? "AgentMain browser pairing test timed out" : failure;
	}

	static function verifyPersistedDevice(store:WorkspaceSqliteStore, deviceId:String):Void {
		var records = store.loadDevices();
		require(records.length == 1, "SQLite did not retain exactly one approved device");
		var record = records[0];
		require(record.deviceId == deviceId && !record.revoked
			&& record.grants.length == 2
			&& record.grants.indexOf(WorkspaceProtocol.READ) >= 0
			&& record.grants.indexOf(WorkspaceProtocol.IDENTITY_CAPABILITY) >= 0,
			"SQLite device trust or explicit workspace grants did not survive reload");
	}

	static function cleanupTestCredentials(machineId:String, origin:String):Void {
		var runtime = NativeKitRuntime.start();
		for (account in ["noise-static:" + machineId, "relay:" + origin + "/machine/" + machineId]) {
			var secret = Credentials.get("com.exosuit.workspace-relay", account);
			if (secret != null) {
				for (index in 0...secret.length) secret.set(index, 0);
				Credentials.delete("com.exosuit.workspace-relay", account);
			}
		}
		runtime.dispose();
	}

	static function writePrivate(path:String, contents:String):Void {
		var newlyCreated = !sys.FileSystem.exists(path);
		var temporary = path + ".tmp";
		sys.io.File.saveContent(temporary, contents);
		if (newlyCreated) try Sys.command("chmod", ["600", temporary]) catch (_:Dynamic) {}
		sys.FileSystem.rename(temporary, path);
	}
}
