package app;

import haxe.io.Bytes;
import haxeon.platform.NativeKitRuntime;
import haxeon.rpc.*;
import haxeon.wire.MessagePack;
import workspace.service.*;
import workspace.service.WorkspaceProtocol;
import workspace.transport.*;

private typedef Link = {var stream:MessageTransport; var client:RpcConnection; var server:RpcConnection;}

class NetworkLifecycleTests {
	static function require(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}

	static function events(runtime:NativeKitRuntime):Void {
		runtime.events.wait(0.001);
		for (_ in 0...128)
			if (!runtime.events.poll())
				break;
	}

	static function policy(capabilities:Array<String>):RpcPeerOptions
		return new RpcPeerOptions("policy-test/1", capabilities, [], 1000, 262144, 32, 1048576);

	static function service():WorkspaceService
		return new WorkspaceService("w", "e", [
			{
				id: "g",
				name: "Work",
				cwd: "/workspace",
				revision: 1
			}
		]);

	public static function run(runtime:NativeKitRuntime, hub:NativeRpcHub, path:String, clock:Void->Float):Void {
		capabilities(runtime, hub, path, clock);
		slowConsumer(runtime, hub, path, clock);
	}

	static function capabilities(runtime:NativeKitRuntime, hub:NativeRpcHub, path:String, clock:Void->Float):Void {
		var catalog = service();
		var all = [WorkspaceProtocol.READ, WorkspaceProtocol.WRITE];
		var host = new WorkspaceRpcServer(catalog, clock, all);
		// The listener keeps serving; replacing host policy retires only its client connections.
		var listener = hub.listen(NativeRpcHub.local(path), function(stream) {
			host.acceptLocal(stream);
		});
		var ready = 0, snapshots = 0;
		var grants:Array<Array<String>> = [];
		var client = new RpcClient(new NativeRpcConnector(hub, NativeRpcHub.local(path)), clock, function() return 1.0, policy(all),
			function(connection, _, accepted) {
				ready++;
				grants.push(accepted);
				connection.call(WorkspaceProtocol.QUERY, {workspace: "w"}, 1000, function(value) {
					require(value.epoch == "e", "Policy reconnect changed workspace epoch");
					snapshots++;
				}, function(error) {
					throw "Query failed after policy change: " + error.code;
				});
			}, 5, 20, 1000);
		var step = function() {
			events(runtime);
			host.poll();
			client.poll();
		};
		var deadline = clock() + 5000;
		while (snapshots < 1) {
			require(clock() < deadline, "Initial policy connection timed out");
			step();
		}
		require(grants[0].indexOf(WorkspaceProtocol.WRITE) >= 0, "Initial write grant missing");
		for (restore in [false, true]) {
			host.dispose();
			host = new WorkspaceRpcServer(catalog, clock, restore ? all : [WorkspaceProtocol.READ]);
			var wanted = restore ? 3 : 2;
			deadline = clock() + 5000;
			while (snapshots < wanted) {
				require(clock() < deadline, "Policy reconnect timed out");
				step();
			}
			require(ready == wanted && grants[wanted - 1].length == 1 && grants[wanted - 1][0] == WorkspaceProtocol.READ,
				"Reconnect regained revoked capability");
			var connection = client.current();
			if (connection == null)
				throw "Missing policy connection";
			var denied = false;
			connection.call(WorkspaceProtocol.RENAME, {
				workspace: "w",
				epoch: "e",
				operation: "denied",
				group: "g",
				expectedRevision: 1,
				name: "New"
			}, 1000, function(_) {
				throw "Revoked rename succeeded";
			}, function(error) {
				denied = error.code == "unauthorized" && !error.ambiguous;
			});
			while (!denied) {
				require(clock() < deadline, "Denied rename timed out");
				step();
			}
			require(catalog.snapshot().cursor == 0, "Revoked write changed workspace state");
		}
		// Enough completed reconnects to expose leaked hub (32) or service (16) slots.
		for (_ in 0...40) {
			var connection = client.current();
			if (connection == null)
				throw "Missing churn connection";
			var wanted = snapshots + 1;
			connection.close();
			deadline = clock() + 5000;
			while (snapshots < wanted) {
				require(clock() < deadline, "Completed connection churn leaked capacity");
				step();
			}
			require(client.capabilities().length == 1, "Connection churn widened permissions");
		}
		client.close();
		host.dispose();
		hub.forget(listener);
		Sys.println("PASS: real completed-connection churn retires slots; reduced grants never regain revoked write permission");
	}

	// Two real sockets share a service. The slow peer never drains its incoming bytes
	// after admission; real native/RPC queues must reject it without closing its sibling.
	static function slowConsumer(runtime:NativeKitRuntime, hub:NativeRpcHub, path:String, clock:Void->Float):Void {
		var catalog = service();
		var admitted:Array<NativeRpcTransport> = [];
		var listener = hub.listen(NativeRpcHub.local(path), function(stream) {
			admitted.push(stream);
		});
		var options = policy([WorkspaceProtocol.READ]);
		var open = function():Link {
			var stream:Null<MessageTransport> = null;
			var attempt = hub.connect(NativeRpcHub.local(path), function(result) switch result {
				case Opened(transport):
					stream = transport;
				case Failed(error, _):
					throw "Socket connect failed: " + error.code;
			});
			var deadline = clock() + 5000;
			while (stream == null || admitted.length == 0) {
				require(clock() < deadline, "Socket admission timed out");
				events(runtime);
			}
			var remote = admitted.shift();
			if (stream == null || remote == null)
				throw "Missing admitted socket";
			var outgoing = stream;
			attempt.cancel(); // A completed attempt must no longer own the transferred stream.
			require(outgoing.isOpen(), "Completed-attempt cancel closed the adopted transport");
			var a = RpcHandshake.client(outgoing, clock, options, options.offered());
			var b = RpcHandshake.server(remote, clock, options);
			while (!a.isFinished() || !b.isFinished()) {
				require(clock() < deadline, "Socket handshake timed out");
				events(runtime);
				a.poll();
				b.poll();
			}
			var client = a.connection, server = b.connection;
			if (client == null || server == null)
				throw "Socket handshake failed";
			catalog.bind(server, b.capabilities());
			return {stream: outgoing, client: client, server: server};
		};
		var slow = open(), healthy = open();
		var success = false;
		healthy.client.call(WorkspaceProtocol.QUERY, {workspace: "w"}, 1000, function(value) {
			success = value.cursor == 0 && value.groups[0].cwd == "/workspace";
		}, function(error) {
			throw "Healthy peer failed: " + error.code;
		});
		var payload = Bytes.alloc(65536);
		// More than RPC, native send and native receive capacities combined, all bounded.
		for (_ in 0...256) {
			if (!slow.server.notify(201, payload, function(value:Bytes) return MessagePack.encode(value)))
				break;
			require(slow.server.bufferedBytes() <= options.maxQueuedBytes, "Slow-peer RPC queue grew beyond admission limit");
		}
		var deadline = clock() + 5000;
		while (slow.server.isOpen() || !success) {
			require(clock() < deadline, "Slow consumer was not retired or sibling stopped progressing");
			events(runtime);
			slow.server.poll();
			healthy.server.poll();
			healthy.client.poll();
		}
		require(slow.server.bufferedBytes() == 0 && healthy.server.isOpen() && healthy.client.isOpen(), "Overload retained bytes or closed unrelated peer");
		// The surviving peer can still perform a later request after overload cleanup.
		success = false;
		healthy.client.call(WorkspaceProtocol.QUERY, {workspace: "w"}, 1000, function(_) {
			success = true;
		}, function(_) {
			throw "Healthy follow-up failed";
		});
		while (!success) {
			require(clock() < deadline, "Healthy follow-up timed out");
			events(runtime);
			healthy.server.poll();
			healthy.client.poll();
		}
		slow.client.close();
		slow.server.close();
		healthy.client.close();
		healthy.server.close();
		hub.forget(listener);
		Sys.println("PASS: real slow-consumer overload retires bounded queues and preserves unrelated peer progress");
	}
}
