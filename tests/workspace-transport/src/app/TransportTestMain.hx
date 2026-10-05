package app;

import NativeKitRuntime;
import nativekit.ffi.NativeKit;
import workspace.transport.*;
import workspace.service.*;
import workspace.service.WorkspaceProtocol;
import haxeon.rpc.*;

class TransportTestMain {
	static function require(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}

	static function main():Void {
		var args = Sys.args();
		if (args.length != 3)
			throw "Expected private socket, port and credential file";
		var token = sys.io.File.getContent(args[2]);
		var runtime = NativeKitRuntime.start(),
			hub = new NativeRpcHub(runtime.events);
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
				new RpcPeerOptions("test/1", [WorkspaceProtocol.READ, WorkspaceProtocol.EVENTS, WorkspaceProtocol.WRITE], [], 1000, 262144, 32, 1048576),
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
			var connection = client.current();
			if (connection == null)
				throw "Missing connection";
			require(ready == 1 && replica.view()[0].cwd == "/workspace", "Workspace snapshot lost cwd");
			var revision = service.snapshot().groups[0].revision,
				sequence = service.snapshot().cursor;
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
		server.dispose();
		hub.forget(local);
		hub.forget(ws);
		hub.dispose();
		runtime.dispose();
		Sys.println("PASS: authentication refusal is terminal before privileged dispatch");
	}
}
