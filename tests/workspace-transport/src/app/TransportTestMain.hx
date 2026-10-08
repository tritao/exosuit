package app;

import haxe.io.Bytes;
import haxeon.platform.NativeKitRuntime;
import nativekit.ffi.NativeKit;
import workspace.transport.*;
import workspace.service.*;
import workspace.service.WorkspaceProtocol;
import workspace.runtime.WorkspaceRelayHost;
import workspace.runtime.WorkspaceRelaySettings;
import workspace.runtime.WorkspaceCredentialStore;
import app.AgentManagerNative;
import app.AgentRelayBootstrap;
import haxeon.rpc.*;

class TransportTestMain {
	static function require(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}

	static function main():Void {
		var args = Sys.args();
		if (args.length == 1 && args[0] == "--relay-only") {
			RelayProtocolTests.run();
			return;
		}
		if (args.length == 1 && args[0] == "--noise-only") {
			NoiseTransportTests.run();
			WorkspacePairingTests.run();
			return;
		}
		if (args.length == 3 && args[0] == "--manager-bootstrap") {
			AgentManagerNative.setPrivateUmask();
			if (!AgentManagerNative.prepareDirectory(args[1])) throw "Could not prepare relay bootstrap fixture directory";
			var firstPath = AgentRelayBootstrap.create(args[1], args[2]);
			if (firstPath == null) throw "Relay bootstrap was not created";
			var first:Dynamic = haxe.Json.parse(sys.io.File.getContent(firstPath));
			if (!AgentManagerNative.privateFile(firstPath)) throw "Relay bootstrap was not private";
			sys.FileSystem.deleteFile(firstPath);
			var secondPath = AgentRelayBootstrap.create(args[1], args[2]);
			if (secondPath == null) throw "Second relay bootstrap was not created";
			var second:Dynamic = haxe.Json.parse(sys.io.File.getContent(secondPath));
			if (!AgentManagerNative.privateFile(secondPath)) throw "Second relay bootstrap was not private";
			if (Reflect.field(first, "origin") != args[2] || Reflect.field(second, "origin") != args[2]
				|| Reflect.field(first, "machineId") != Reflect.field(second, "machineId")
				|| Reflect.field(first, "bootstrapToken") == Reflect.field(second, "bootstrapToken"))
				throw "Relay identity did not persist or bootstrap bearer did not rotate";
			sys.FileSystem.deleteFile(secondPath);
			Sys.println("PASS: Haxe manager persists relay identity and rotates private one-shot bootstrap tokens");
			return;
		}
		RelayProtocolTests.run();
		NoiseTransportTests.run();
		WorkspacePairingTests.run();
		if (args.length != 4)
			throw "Expected private socket, port, credential file and private relay config";
		var token = sys.io.File.getContent(args[2]);
		var relayConfig:Dynamic = haxe.Json.parse(sys.io.File.getContent(args[3]));
		var runtime = NativeKitRuntime.start(),
			hub = new NativeRpcHub(runtime.events);
		testPairingRelayHttp(runtime, relayConfig);
		var clock = function() return NativeKit.nk_time_seconds() * 1000;
		var service = new WorkspaceService("workspace", "epoch-1", [
			{
				id: "work",
				name: "Work",
				cwd: "/workspace",
				revision: 1
			}
		]);
		var server = new WorkspaceRpcServer(service, clock, null, null, null, null, new TestPairingAdmin());
		server.enableLifecycle(function():workspace.service.WorkspaceLifecycleProtocol.WorkspaceServiceStatus return {
            protocol:1, build:"test", terminals:0, agents:0, updatePending:false
        }, function(mode:String):Bool { throw "Transport fixture must not restart"; });
        var local = hub.listen(NativeRpcHub.local(args[0]), server.acceptLocal);
		var ws = hub.listen(NativeRpcHub.websocket(Std.parseInt(args[1]), "/workspace", true), function(stream) {
			server.acceptWebSocket(stream, token);
		});
		// Cancel before CONNECTED: stale events must neither publish nor retain a stream slot.
		var canceledCallbacks = 0;
		for (_ in 0...64) {
			var canceled = hub.connect(NativeRpcHub.local(args[0]), function(_) {
				canceledCallbacks++;
			});
			canceled.cancel();
		}
		for (_ in 0...16) {
			runtime.events.wait(0.001);
			for (_ in 0...128)
				if (!runtime.events.poll())
					break;
			server.poll();
		}
		require(canceledCallbacks == 0, "Canceled native attempt published stale completion");
		Sys.println("PASS: canceled native connection churn retires attempts before late events");
		for (websocket in [false, true]) {
			var nativeConnector = new NativeRpcConnector(hub, websocket ? NativeRpcHub.websocket(Std.parseInt(args[1])) : NativeRpcHub.local(args[0]));
			var authenticated = websocket ? new SessionRpcConnector(nativeConnector, token, clock) : null;
			var connector:RpcConnector = authenticated == null ? nativeConnector : authenticated;
			var replica = new WorkspaceReplica("workspace", 1000);
			var client:Null<RpcClient> = null;
			var ready = 0;
			client = new RpcClient(connector, clock, function() return 1.0,
				new RpcPeerOptions("test/1", [WorkspaceProtocol.READ, WorkspaceProtocol.EVENTS, WorkspaceProtocol.WRITE,
					WorkspacePairingProtocol.ADMIN, workspace.service.WorkspaceLifecycleProtocol.CAPABILITY], [], 1000, 262144, 32, 1048576),
				function(connection, generation, _) {
					ready++;
					var current = client;
					if (current == null)
						throw "Missing client";
					replica.restore(connection, function() return current.isCurrent(generation));
				}, 10, 40, 1000);
			var activeClient = client;
			var step = function() {
				runtime.events.wait(0.001);
				for (_ in 0...128)
					if (!runtime.events.poll())
						break;
				server.poll();
				if (authenticated != null)
					authenticated.poll();
				activeClient.poll();
			};
			var deadline = clock() + 5000;
			while (!replica.ready) {
				require(clock() < deadline, "Real handshake/query timed out");
				step();
			}
			require(server.clientCount() == 1, "Authenticated client missing from daemon lifetime count");
			var connection = client.current();
			if (connection == null)
				throw "Missing connection";
			require(ready == 1 && replica.view()[0].cwd == "/workspace", "Workspace snapshot lost cwd");
            require((client.capabilities().indexOf(workspace.service.WorkspaceLifecycleProtocol.CAPABILITY) >= 0) == !websocket,
                "Lifecycle control must only be offered on same-user local sockets");
            if (websocket) {
                var updateDenied:Null<RpcError> = null;
                connection.call(workspace.service.WorkspaceLifecycleProtocol.UPDATE, {mode:"now"}, 1000,
                    function(_) throw "WebSocket restarted local daemon", function(error) updateDenied = error);
                while (updateDenied == null) { require(clock() < deadline, "Lifecycle refusal timed out"); step(); }
                require(updateDenied.code == "unknown_method", "WebSocket can invoke lifecycle method");
            }

			var revision = service.snapshot().groups[0].revision,
				sequence = service.snapshot().cursor;
			if (!websocket) {
				var invitation:Null<workspace.service.WorkspacePairingProtocol.PairingInvitation> = null;
				var pairingFailure:Null<RpcError> = null;
				connection.call(WorkspacePairingProtocol.CREATE, {ttlSeconds: 60}, 1000,
					function(value) invitation = value, function(error) pairingFailure = error);
				deadline = clock() + 5000;
				while (invitation == null && pairingFailure == null) {
					require(clock() < deadline, "Local pairing administration call timed out");
					step();
				}
				require(invitation != null && pairingFailure == null
					&& invitation.pairingSocketUrl.indexOf(invitation.secret) >= 0,
					"same-user local RPC can create a one-use pairing invitation");
			} else {
				var pairingDenied:Null<RpcError> = null;
				connection.call(WorkspacePairingProtocol.CREATE, {ttlSeconds: 60}, 1000,
					function(_) throw "Remote WebSocket invoked local pairing administration",
					function(error) pairingDenied = error);
				deadline = clock() + 5000;
				while (pairingDenied == null) {
					require(clock() < deadline, "Remote pairing administration refusal timed out");
					step();
				}
				require(pairingDenied.code == "unknown_method",
					"remote WebSocket has no pairing administration method");
			}
			var failures = 0, ambiguous = false;
			var operation = websocket ? "websocket-rename" : "local-rename";
			connection.call(WorkspaceProtocol.RENAME, {
				workspace: "workspace",
				epoch: "epoch-1",
				operation: operation,
				group: "work",
				expectedRevision: revision,
				name: operation
			}, 1000, function(_) {
				throw "Reply should be interrupted";
			}, function(error) {
				failures++;
				ambiguous = error.ambiguous;
			});
			// Let the server commit while deliberately not polling the caller's RPC queue.
			deadline = clock() + 5000;
			while (service.snapshot().cursor == sequence) {
				require(clock() < deadline, "Mutation did not reach real socket");
				runtime.events.wait(0.001);
				for (_ in 0...128)
					if (!runtime.events.poll())
						break;
				server.poll();
			}
			server.closeClients();
			deadline = clock() + 5000;
			while (failures == 0) {
				require(clock() < deadline, "Disconnect did not fail accepted call");
				step();
			}
			require(failures == 1 && ambiguous, "Real disconnect lost uncertainty");
			while (ready < 2 || !replica.ready) {
				require(clock() < deadline, "Real reconnect did not restore view");
				step();
			}
			require(replica.cursor == sequence + 1 && replica.view()[0].name == operation, "Real event resume missed mutation");
			var next = client.current();
			if (next == null)
				throw "No reconnected client";
			var known = false;
			next.call(WorkspaceProtocol.OPERATION, {workspace: "workspace", epoch: "epoch-1", operation: operation}, 1000, function(value) {
				known = value.known && value.outcome != null && value.outcome.sequence == sequence + 1;
			}, function(_) {
				throw "Outcome lookup failed";
			});
			while (!known) {
				require(clock() < deadline, "Real outcome lookup timed out");
				step();
			}
			require(service.snapshot().cursor == sequence + 1, "Mutation was replayed by reconnect");
			client.close();
			if (authenticated != null)
				authenticated.dispose();
			server.closeClients();
			Sys.println(websocket ? "PASS: authenticated real WebSocket RPC, reconnect, cursor resume and outcome lookup" : "PASS: same-user local socket RPC, reconnect, cursor resume and outcome lookup");
		}
		NetworkLifecycleTests.run(runtime, hub, args[0] + ".life", clock);
		// Wrong credentials terminate reconnect and never expose a privileged connection.
		var bad = new SessionRpcConnector(new NativeRpcConnector(hub, NativeRpcHub.websocket(Std.parseInt(args[1]))), StringTools.lpad("", "0", 64), clock);
		var rejected = new RpcClient(bad, clock, function() return 1.0, new RpcPeerOptions("test/1", [WorkspaceProtocol.READ], [], 1000, 262144, 32, 1048576),
			function(_, _, _) {
				throw "Bad credential published RPC";
			}, 10, 40, 1000);
		var deadline = clock() + 5000;
		while (rejected.state != Closed) {
			require(clock() < deadline, "Authentication refusal timed out");
			runtime.events.wait(0.001);
			for (_ in 0...128)
				if (!runtime.events.poll())
					break;
			server.poll();
			bad.poll();
			rejected.poll();
		}
		require(rejected.lastError != null && rejected.lastError.code == "authentication_refused" && rejected.generation == 1,
				"Authentication refusal retried");
		bad.dispose();
		var relayEndpoint = new RelayMachineEndpoint(Reflect.field(relayConfig, "origin"), Reflect.field(relayConfig, "machineId")),
			ticketClient = new RelayTicketClient(runtime.events, true),
			ticketDone = false,
			ticketValue:Null<RelaySocketTicket> = null,
			ticketError:Null<String> = null;
		ticketClient.request(relayEndpoint, Reflect.field(relayConfig, "machineToken"), function(ticket, error) {
			ticketValue = ticket;
			ticketError = error;
			ticketDone = true;
		});
		deadline = clock() + 5000;
		while (!ticketDone) {
			require(clock() < deadline, "NativeKit relay ticket HTTP request timed out");
			runtime.events.wait(0.001);
			for (_ in 0...128)
				if (!runtime.events.poll())
					break;
		}
		ticketClient.dispose();
		require(ticketError == null && ticketValue != null,
			"NativeKit could not obtain a machine ticket from the local Worker: " + Std.string(ticketError));
		Sys.println("PASS: NativeKit authenticated HTTP ticket exchange with local Worker");
		var credentialStore = new MemoryWorkspaceCredentialStore(),
			relayBootstrapPath = args[3] + ".bootstrap",
			bootstrapToken:String = Reflect.field(relayConfig, "machineToken");
		sys.io.File.saveContent(relayBootstrapPath, haxe.Json.stringify({
			version: 1,
			origin: relayEndpoint.origin,
			machineId: relayEndpoint.machineId,
			bootstrapToken: bootstrapToken
		}));
		var relaySettings = WorkspaceRelaySettings.loadBootstrap(relayBootstrapPath, credentialStore);
		require(!sys.FileSystem.exists(relayBootstrapPath), "Relay bootstrap secret file was not removed");
		require(relaySettings.machineToken == bootstrapToken, "Relay bootstrap bearer was not stored");
		sys.io.File.saveContent(relayBootstrapPath, haxe.Json.stringify({
			version: 1,
			origin: relayEndpoint.origin,
			machineId: relayEndpoint.machineId,
			bootstrapToken: StringTools.lpad("", "b", 64)
		}));
		relaySettings = WorkspaceRelaySettings.loadBootstrap(relayBootstrapPath, credentialStore);
		require(relaySettings.machineToken == bootstrapToken, "A new bootstrap token replaced the saved machine credential");
		var otherRelayBootstrapToken = StringTools.lpad("", "c", 64);
		sys.io.File.saveContent(relayBootstrapPath, haxe.Json.stringify({
			version: 1,
			origin: "https://relay.example.test",
			machineId: relayEndpoint.machineId,
			bootstrapToken: otherRelayBootstrapToken
		}));
		var otherRelaySettings = WorkspaceRelaySettings.loadBootstrap(relayBootstrapPath, credentialStore);
		require(otherRelaySettings.machineToken == otherRelayBootstrapToken,
			"A relay credential was reused across different relay origins");
		var relayHost = new WorkspaceRelayHost(runtime.events, hub,
			relaySettings, true),
			machineChannel:Null<RelayChannel> = null;
		relayHost.onChannel = function(channel) machineChannel = channel;
		deadline = clock() + 20000;
		while (!relayHost.connected) {
			require(clock() < deadline, "Workspace relay host enrollment and connection timed out: " + Std.string(relayHost.lastError));
			runtime.events.wait(0.001);
			for (_ in 0...128)
				if (!runtime.events.poll())
					break;
			server.poll();
			relayHost.poll(clock());
		}
		require(relayHost.activeCount() == 1, "Configured relay host did not retain workspace lifetime");
		Sys.println("PASS: NativeKit machine ticket exchange and WebSocket connect to local Worker");
		var deviceTicketClient = new RelayTicketClient(runtime.events, true),
			deviceTicketDone = false,
			deviceTicket:Null<RelaySocketTicket> = null,
			deviceTicketError:Null<String> = null;
		deviceTicketClient.request(relayEndpoint, Reflect.field(relayConfig, "deviceToken"), function(ticket, error) {
			deviceTicket = ticket;
			deviceTicketError = error;
			deviceTicketDone = true;
		});
		deadline = clock() + 5000;
		while (!deviceTicketDone) {
			require(clock() < deadline, "NativeKit device ticket request timed out");
			runtime.events.wait(0.001);
			for (_ in 0...128)
				if (!runtime.events.poll())
					break;
		}
		deviceTicketClient.dispose();
		require(deviceTicketError == null && deviceTicket != null,
			"NativeKit could not obtain a device ticket from the local Worker: " + Std.string(deviceTicketError));
		var deviceConnectDone = false,
			deviceStream:Null<NativeKitByteStream> = null,
			deviceConnectError:Null<String> = null;
		hub.connectBytes(NativeRpcHub.websocketUrl(relayEndpoint.websocketUrl(deviceTicket)), function(stream, error) {
			deviceStream = stream;
			deviceConnectError = error;
			deviceConnectDone = true;
		});
		deadline = clock() + 20000;
		while (!deviceConnectDone) {
			require(clock() < deadline, "NativeKit device WebSocket handshake timed out");
			runtime.events.wait(0.001);
			for (_ in 0...128)
				if (!runtime.events.poll())
					break;
			server.poll();
		}
		require(deviceConnectError == null && deviceStream != null && deviceStream.isOpen(),
			"NativeKit could not connect the device WebSocket while the machine is live: " + Std.string(deviceConnectError));
		var deviceLink = new RelaySocketLink(deviceStream),
			deviceId:String = Reflect.field(relayConfig, "deviceId"),
			deviceChannel = deviceLink.openChannel(deviceId);
		require(deviceChannel.send(Bytes.ofString("device-to-machine")), "Device relay send failed");
		var atMachine:Null<Bytes> = null;
		deadline = clock() + 5000;
		while (atMachine == null) {
			require(clock() < deadline, "Worker did not route device data to the machine");
			runtime.events.wait(0.001);
			for (_ in 0...128)
				if (!runtime.events.poll())
					break;
			server.poll();
			relayHost.poll(clock());
			if (machineChannel != null)
				atMachine = machineChannel.receive();
			deviceChannel.receive();
		}
		require(atMachine.toString() == "device-to-machine", "Worker corrupted device-to-machine data");
		if (machineChannel == null)
			throw "Device route did not create a machine channel";
		require(machineChannel.send(Bytes.ofString("machine-to-device")), "Machine relay send failed");
		var atDevice:Null<Bytes> = null;
		deadline = clock() + 5000;
		while (atDevice == null) {
			require(clock() < deadline, "Worker did not route machine data to the device");
			runtime.events.wait(0.001);
			for (_ in 0...128)
				if (!runtime.events.poll())
					break;
			server.poll();
			relayHost.poll(clock());
			atDevice = deviceChannel.receive();
			machineChannel.receive();
		}
		require(atDevice.toString() == "machine-to-device", "Worker corrupted machine-to-device data");
		deviceLink.close();
		relayHost.dispose();
		Sys.println("PASS: NativeKit machine and device sockets route bounded binary data bidirectionally through local Worker");
		server.dispose();
		hub.forget(local);
		hub.forget(ws);
		hub.dispose();
		runtime.dispose();
		Sys.println("PASS: authentication refusal is terminal before privileged dispatch");
	}

	static function testPairingRelayHttp(runtime:NativeKitRuntime, config:Dynamic):Void {
		var origin:String = Reflect.field(config, "origin");
		var machineId:String = Reflect.field(config, "machineId");
		var machineToken:String = Reflect.field(config, "machineToken");
		var endpoint = new RelayMachineEndpoint(origin, machineId);
		var client = new RelayTicketClient(runtime.events, true);
		var channelId = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
		var invitationSecret = StringTools.lpad("", "b", 64);
		var deviceId = "c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2";
		var deviceToken = StringTools.lpad("", "d", 64);
		var completed = false, failure:Null<String> = null;
		client.createPairing(endpoint, machineToken, channelId, invitationSecret, 1, function(error) {
			completed = true;
			failure = error;
		});
		waitForRelayHttp(runtime, function() return completed);
		require(failure == null, "Haxe relay client creates a one-use pairing invitation");
		completed = false;
		client.registerDevice(endpoint, machineToken, deviceId, deviceToken, function(error) {
			completed = true;
			failure = error;
		});
		waitForRelayHttp(runtime, function() return completed);
		require(failure == null, "Haxe relay client registers an approved device bearer");
		completed = false;
		client.revokeDevice(endpoint, machineToken, deviceId, function(error) {
			completed = true;
			failure = error;
		});
		waitForRelayHttp(runtime, function() return completed);
		require(failure == null, "Haxe relay client revokes a registered device bearer");
		client.dispose();
		Sys.println("PASS: Haxe relay pairing creation, device registration and revocation HTTP paths");
	}

	static function waitForRelayHttp(runtime:NativeKitRuntime, finished:Void->Bool):Void {
		var deadline = NativeKit.nk_time_seconds() * 1000 + 5000;
		while (!finished()) {
			require(NativeKit.nk_time_seconds() * 1000 < deadline, "Haxe relay pairing HTTP request timed out");
			runtime.events.wait(0.001);
			for (_ in 0...128)
				if (!runtime.events.poll())
					break;
		}
	}
}

private class MemoryWorkspaceCredentialStore implements WorkspaceCredentialStore {
	final values:Map<String, Bytes> = [];

	public function new() {}

	public function read(account:String):Null<Bytes> {
		var value = values.get(account);
		if (value == null)
			return null;
		var copy = Bytes.alloc(value.length);
		copy.blit(0, value, 0, value.length);
		return copy;
	}

	public function write(account:String, secret:Bytes):Void {
		var copy = Bytes.alloc(secret.length);
		copy.blit(0, secret, 0, secret.length);
		values.set(account, copy);
	}
}

private class TestPairingAdmin implements WorkspacePairingAdmin {
	public function new() {}

	public function createInvitation(ttlSeconds:Int,
		complete:workspace.service.WorkspacePairingProtocol.PairingInvitation->Null<String>->Void):Void {
		var machineId = "0123456789abcdef0123456789abcdef";
		var deviceId = "abcdef0123456789abcdef0123456789";
		var secret = StringTools.lpad("", "1", 64);
		complete({relayOrigin: "https://relay.example", machineId: machineId, deviceId: deviceId, secret: secret,
			pairingSocketUrl: 'wss://relay.example/v1/machines/${machineId}/pair/${deviceId}?secret=${secret}',
			expiresInSeconds: ttlSeconds}, null);
	}

	public function listPending():Array<workspace.service.WorkspacePairingProtocol.PendingPairing>
		return [];

	public function listDevices():Array<workspace.service.WorkspacePairingProtocol.PairingDevice>
		return [];

	public function approve(deviceId:String, grants:Array<String>, complete:Null<String>->Void):Void
		complete(null);

	public function reject(deviceId:String):Bool
		return true;

	public function revoke(deviceId:String, complete:Null<String>->Void):Void
		complete(null);
}
