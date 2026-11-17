package app;

import haxe.io.Bytes;
import haxeon.platform.Runtime;
import nativekit.ffi.NativeKit;
import workspace.transport.*;
import workspace.service.*;
import workspace.service.WorkspaceProtocol;
import workspace.runtime.WorkspaceRelayHost;
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
		RelayProtocolTests.run();
		NoiseTransportTests.run();
		WorkspacePairingTests.run();
		if (args.length != 2)
			throw "Expected a private socket and a private relay config";
		var relayConfig:Dynamic = haxe.Json.parse(sys.io.File.getContent(args[1]));
		var runtime = Runtime.start(),
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
		var server = new WorkspaceRpcServer(service, clock);
		var local = hub.listen(NativeRpcHub.local(args[0]), server.acceptLocal);
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
		{
			var connector = new NativeRpcConnector(hub, NativeRpcHub.local(args[0]));
			// What QUERY answered on the latest connection; null until it has.
			var snapshot:Null<WorkspaceSnapshot> = null;
			function shown():WorkspaceSnapshot {
				var value = snapshot;
				if (value == null) throw "No snapshot";
				return value;
			}
			var client:Null<RpcClient> = null;
			var ready = 0;
			client = new RpcClient(connector, clock, function() return 1.0,
				new RpcPeerOptions("test/1", [WorkspaceProtocol.READ, WorkspaceProtocol.WRITE,
					WorkspaceProtocol.TREE], [], 1000, 262144, 32, 1048576),
				function(connection, generation, _) {
					ready++;
					var current = client;
					if (current == null)
						throw "Missing client";
					snapshot = null;
					connection.call(WorkspaceProtocol.QUERY, {workspace: "workspace"}, 1000, function(value) {
						if (current.isCurrent(generation)) snapshot = value;
					}, function(_) {});
				}, 10, 40, 1000);
			var activeClient = client;
			var step = function() {
				runtime.events.wait(0.001);
				for (_ in 0...128)
					if (!runtime.events.poll())
						break;
				server.poll();
				activeClient.poll();
			};
			var deadline = clock() + 5000;
			while (snapshot == null) {
				require(clock() < deadline, "Real handshake/query timed out");
				step();
			}
			require(server.clientCount() == 1, "Connected client missing from daemon lifetime count");
			var connection = client.current();
			if (connection == null)
				throw "Missing connection";
			require(ready == 1 && shown().groups[0].cwd == "/workspace", "Workspace snapshot lost cwd");

			var revision = service.snapshot().groups[0].revision,
				sequence = service.snapshot().cursor;
			var failures = 0, ambiguous = false;
			var operation = "local-rename";
			var change:RenameGroup = {
				workspace: "workspace",
				epoch: "epoch-1",
				operation: operation,
				group: "work",
				expectedRevision: revision,
				name: operation,
				action: "update", parent: null, cwd: "/workspace", order: 0
			};
			connection.call(WorkspaceProtocol.GROUP, change, 1000, function(_) {
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
			while (ready < 2 || snapshot == null) {
				require(clock() < deadline, "Real reconnect did not restore view");
				step();
			}
			require(shown().cursor == sequence + 1 && shown().groups[0].name == operation, "Reconnected QUERY missed the mutation");
			var next = client.current();
			if (next == null)
				throw "No reconnected client";
			// The interrupted call, sent again with its operation id, answers the recorded outcome.
			var known = false;
			next.call(WorkspaceProtocol.GROUP, change, 1000, function(value) {
				known = value.sequence == sequence + 1;
			}, function(_) {
				throw "Retried group change failed";
			});
			while (!known) {
				require(clock() < deadline, "Retried group change timed out");
				step();
			}
			require(service.snapshot().cursor == sequence + 1, "Mutation was replayed by reconnect");
			client.close();
			server.closeClients();
			Sys.println("PASS: same-user local socket RPC, reconnect, cursor resume and idempotent retry");
		}
		NetworkLifecycleTests.run(runtime, hub, args[0] + ".life", clock);
		var deadline = 0.0;
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
		var relayHost = new WorkspaceRelayHost(runtime.events, hub, relayEndpoint, Reflect.field(relayConfig, "machineToken"), true),
			machineChannel:Null<RelayChannel> = null;
		relayHost.onChannel = function(channel) machineChannel = channel;
		deadline = clock() + 20000;
		while (!relayHost.connected) {
			require(clock() < deadline, "Machine relay host enrollment and connection timed out: " + Std.string(relayHost.lastError));
			runtime.events.wait(0.001);
			for (_ in 0...128)
				if (!runtime.events.poll())
					break;
			server.poll();
			relayHost.poll(clock());
		}
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
		hub.dispose();
		runtime.dispose();
	}

	static function testPairingRelayHttp(runtime:Runtime, config:Dynamic):Void {
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

	static function waitForRelayHttp(runtime:Runtime, finished:Void->Bool):Void {
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
