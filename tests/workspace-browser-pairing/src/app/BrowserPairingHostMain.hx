package app;

import haxe.Json;
import haxe.io.Bytes;
import haxeon.platform.NativeKitRuntime;
import nativekit.ffi.NativeKit;
import noisekit.NoiseSession;
import workspace.runtime.WorkspacePairingManager;
import workspace.runtime.WorkspaceRelayHost;
import workspace.runtime.WorkspaceRelaySettings;
import workspace.service.WorkspaceDevicePersistence;
import workspace.service.WorkspaceDeviceRecord;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceService;
import workspace.transport.NativeRpcHub;
import workspace.transport.RelayMachineEndpoint;
import workspace.transport.WorkspaceRpcServer;

/** Runs the real machine-side first-pair path against a local Wrangler Worker. */
class BrowserPairingHostMain {
	static function require(value:Bool, message:String):Void {
		if (!value) throw message;
	}

	static function main():Void {
		var args = Sys.args();
		if (args.length != 1)
			throw "Expected a private browser-pairing test config file";
		var configPath = args[0];
		if (!sys.FileSystem.exists(configPath))
			throw "Invalid browser-pairing test config file";
		var config:Dynamic = Json.parse(sys.io.File.getContent(configPath));
		var origin:String = config.origin, machineId:String = config.machineId, machineToken:String = config.machineToken,
			workspaceRoot:String = config.workspaceRoot, invitePath:String = config.invitePath,
			statusPath:String = config.statusPath, decisionPath:String = config.decisionPath,
			successPath:String = config.successPath;
		sys.FileSystem.createDirectory(workspaceRoot);
		var runtime = NativeKitRuntime.start(), hub = new NativeRpcHub(runtime.events),
			clock = function() return NativeKit.nk_time_seconds() * 1000,
			endpoint = new RelayMachineEndpoint(origin, machineId),
			relay = new WorkspaceRelayHost(runtime.events, hub, new WorkspaceRelaySettings(endpoint, machineToken), true),
			store = new MemoryDeviceStore();
		var machineKeys = NoiseSession.generateKeypair();
		var server:Null<WorkspaceRpcServer> = null;
		var pairing = new WorkspacePairingManager(store, relay, machineKeys.privateKey,
			function() return server == null ? [WorkspaceProtocol.READ, WorkspaceProtocol.IDENTITY_CAPABILITY] : server.options.offered(),
			clock, function(secure, grants) {
				if (server == null) secure.close(); else server.acceptRemote(secure, grants);
			});
		server = new WorkspaceRpcServer(new WorkspaceService("workspace", "browser-pairing-epoch", [
			{id: "work", name: "Browser pairing test", cwd: workspaceRoot, revision: 1}
		]), clock, null, {workspace: "workspace", root: workspaceRoot, instance: "browser-pairing-test"}, null, null, pairing);
		relay.onChannel = function(channel) pairing.acceptChannel(channel.channelId, channel);

		var invitationStarted = false, invitationReady = false, approved = false,
			approvalRequestPending = false, failure:Null<String> = null;
		var registeredDevice:String = "";
		var deadline = clock() + 90000, nextStatusWrite = 0.0;
		while (clock() < deadline && failure == null) {
			runtime.events.wait(0.01);
			for (_ in 0...128) if (!runtime.events.poll()) break;
			relay.poll(clock());
			server.poll();
			pairing.poll();

			if (relay.connected && !invitationStarted) {
				invitationStarted = true;
				pairing.createInvitation(60, function(value, error) {
					if (error != null || value == null) failure = error == null ? "invitation_failed" : error;
					else {
						registeredDevice = value.deviceId;
						writePrivate(invitePath, Json.stringify({pairingSocketUrl: value.pairingSocketUrl,
							machineId: value.machineId, deviceId: value.deviceId}));
						invitationReady = true;
					}
				});
			}

			var candidates = pairing.listPending();
			if (invitationReady && !approved && !approvalRequestPending && sys.FileSystem.exists(decisionPath)) {
				var decision:Dynamic = Json.parse(sys.io.File.getContent(decisionPath));
				var matched = false;
				for (candidate in candidates) {
					if (candidate.deviceId == decision.deviceId && candidate.authenticationCode == decision.authenticationCode) {
						matched = true;
						break;
					}
				}
				require(matched, "browser and desktop authentication codes did not match");
				approvalRequestPending = true;
				pairing.approve(registeredDevice, [WorkspaceProtocol.READ, WorkspaceProtocol.IDENTITY_CAPABILITY], function(error) {
					if (error != null) failure = error; else approved = true;
				});
			}

			if (clock() >= nextStatusWrite) {
				writePrivate(statusPath, Json.stringify({ready: relay.connected && invitationReady,
					pending: candidates, approved: approved, activeClients: server.clientCount(),
					failure: failure, workspaceRoot: workspaceRoot}));
				nextStatusWrite = clock() + 200;
			}
			if (server.clientCount() > 0 && approved && sys.FileSystem.exists(successPath)) {
				var result:Dynamic = Json.parse(sys.io.File.getContent(successPath));
				require(result.machineId == machineId && result.deviceId == registeredDevice
					&& result.workspaceRoot == workspaceRoot, "browser reported a different workspace identity");
				Sys.println("PASS: browser completed Noise pairing, desktop approval and authenticated workspace RPC");
				return;
			}
		}
		pairing.dispose();
		relay.dispose();
		server.dispose();
		hub.dispose();
		throw failure == null ? "Browser pairing test timed out" : failure;
	}

	static function writePrivate(path:String, contents:String):Void {
		var newlyCreated = !sys.FileSystem.exists(path);
		var temporary = path + ".tmp";
		sys.io.File.saveContent(temporary, contents);
		if (newlyCreated) try Sys.command("chmod", ["600", temporary]) catch (_:Dynamic) {}
		sys.FileSystem.rename(temporary, path);
	}
}

private class MemoryDeviceStore implements WorkspaceDevicePersistence {
	final records:Map<String, WorkspaceDeviceRecord> = [];

	public function new() {}

	public function loadDevices():Array<WorkspaceDeviceRecord>
		return [for (record in records) copy(record)];

	public function saveDevice(record:WorkspaceDeviceRecord):Void
		records.set(record.deviceId, copy(record));

	public function revokeDevice(deviceId:String):Void {
		var record = records.get(deviceId);
		if (record != null) records.set(deviceId, {deviceId: record.deviceId, staticPublicKey: cloneBytes(record.staticPublicKey), grants: record.grants.copy(), revoked: true});
	}

	public function deleteDevice(deviceId:String):Void
		records.remove(deviceId);

	static function copy(record:WorkspaceDeviceRecord):WorkspaceDeviceRecord
		return {deviceId: record.deviceId, staticPublicKey: cloneBytes(record.staticPublicKey), grants: record.grants.copy(), revoked: record.revoked};

	static function cloneBytes(source:Bytes):Bytes {
		var result = Bytes.alloc(source.length);
		result.blit(0, source, 0, source.length);
		return result;
	}
}
