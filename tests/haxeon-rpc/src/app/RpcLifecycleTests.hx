package app;

import haxeon.rpc.*;
import haxe.io.Bytes;

private class Attempt implements RpcConnectAttempt {
	public var cancelled:Bool = false;

	public function new() {}

	public function cancel():Void {
		cancelled = true;
	}
}

private class Connector implements RpcConnector {
	public final callbacks:Array<RpcConnectResult->Void> = [];
	public final attempts:Array<Attempt> = [];

	public function new() {}

	public function connect(complete:RpcConnectResult->Void):RpcConnectAttempt {
		callbacks.push(complete);
		var attempt = new Attempt();
		attempts.push(attempt);
		return attempt;
	}
}

class RpcLifecycleTests {
	static function require(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}

	static function pump(client:RpcClient, server:RpcHandshake):Void {
		for (index in 0...8) {
			client.poll();
			server.poll();
		}
	}

	public static function run():Void {
		var now = 0.0;
		var clock = function() return now;
		var connector = new Connector();
		var offers = ["read", "events"];
		var options = new RpcPeerOptions("client/1", offers, ["read"], 50, 1024, 4, 4096);
		offers.push("secret");
		var ready:Array<RpcConnection> = [],
			generations:Array<Int> = [],
			capabilities:Array<Array<String>> = [];
		var client = new RpcClient(connector, clock, function() return 1.0, options, function(connection, generation, accepted) {
			ready.push(connection);
			generations.push(generation);
			capabilities.push(accepted);
			accepted.push("mutated-hook");
		}, 10, 40, 30);
		require(client.state == Disconnected && client.nextWakeAt() == 0, "initial scheduling");
		client.poll();
		require(client.state == Connecting && connector.callbacks.length == 1 && client.generation == 1, "connect not started");
		var pair = MemoryTransport.pair(4096, 16);
		connector.callbacks[0](Opened(pair.client));
		connector.callbacks[0](Opened(pair.client));
		require(pair.client.isOpen(), "duplicate callback closed adopted transport");
		require(client.state == Handshaking && client.current() == null, "privileged connection exposed before handshake");
		var server = RpcHandshake.server(pair.server, clock, new RpcPeerOptions("server/2", ["read", "events", "secret"], [], 50, 1024, 4, 4096));
		pump(client, server);
		require(client.state == Connected && ready.length == 1 && generations[0] == 1 && client.remoteApplication == "server/2", "handshake did not establish");
		require(client.capabilities().length == 2
			&& client.capabilities().indexOf("secret") < 0
			&& client.capabilities().indexOf("mutated-hook") < 0,
			"policy widened or hook mutated it");
		var first = ready[0];
		require(client.isCurrent(1), "fresh generation guard false");
		var method = new RpcMethod<String, String>(100, Bytes.ofString, function(bytes:Bytes) return bytes.toString(), Bytes.ofString,
			function(bytes:Bytes) return bytes.toString());
		var service = server.connection;
		if (service == null)
			throw "missing server connection";
		var retained:Array<RpcContext<String>> = [];
		service.register(method, function(request, context) {
			retained.push(context);
		});
		var failures = 0, ambiguous = false;
		first.call(method, "mutation", 25, function(value) {
			throw "old request completed";
		}, function(error) {
			failures++;
			ambiguous = error.ambiguous;
		});
		require(client.nextWakeAt() == 25, "host timer missed pending call deadline");
		service.poll();
		require(retained.length == 1, "request did not reach handler");
		pair.server.close();
		client.poll();
		service.poll();
		require(failures == 1 && ambiguous && !retained[0].respond("late") && !client.isCurrent(1), "old generation callback resurrected mutation");
		require(client.state == Disconnected && client.current() == null && !first.isOpen() && client.nextWakeAt() == 10, "disconnect lifecycle");
		client.poll();
		require(connector.callbacks.length == 1, "backoff ignored");
		now = 10;
		client.poll();
		require(client.generation == 2, "new generation missing");
		var second = MemoryTransport.pair(4096, 16);
		connector.callbacks[1](Opened(second.client));
		var reducedServer = RpcHandshake.server(second.server, clock, new RpcPeerOptions("server/2", ["read"], [], 50, 1024, 4, 4096));
		pump(client, reducedServer);
		require(ready.length == 2 && client.capabilities().length == 1 && generations[1] == 2, "capability reduction lost");
		require(ready[1].pendingCalls() == 0 && reducedServer.connection != null && reducedServer.connection.activeRequests() == 0,
			"old request replayed after reconnect");
		var late = MemoryTransport.pair();
		connector.callbacks[0](Opened(late.client));
		require(!late.client.isOpen() && client.current() == ready[1], "stale connect callback replaced generation");
		second.server.close();
		client.poll();
		now = 30;
		client.poll();
		var third = MemoryTransport.pair(4096, 16);
		connector.callbacks[2](Opened(third.client));
		pump(client, RpcHandshake.server(third.server, clock, new RpcPeerOptions("server/3", ["read", "events"], [], 50, 1024, 4, 4096)));
		require(client.capabilities().length == 1 && client.capabilities()[0] == "read", "reconnect silently regained capability");
		client.close();
		now = 1000;
		client.poll();
		require(client.state == Closed && client.current() == null && client.nextWakeAt() == null && connector.callbacks.length == 3, "explicit close retried");

		// Timeout cancels its attempt; late completion loses ownership immediately.
		connector = new Connector();
		client = new RpcClient(connector, clock, function() return 0.0, options, function(_, _, _) {}, 10, 40, 30);
		client.poll();
		now = 1030;
		client.poll();
		require(connector.attempts[0].cancelled && client.state == Disconnected && client.nextWakeAt() == 1035, "connect timeout or jitter ignored");
		late = MemoryTransport.pair();
		connector.callbacks[0](Opened(late.client));
		require(!late.client.isOpen(), "timed-out attempt leaked transport");
		now = 1035;
		client.poll();
		client.close();
		require(connector.attempts[1].cancelled, "close did not cancel pending attempt");
		late = MemoryTransport.pair();
		connector.callbacks[1](Opened(late.client));
		require(!late.client.isOpen(), "closed client accepted late transport");

		// Backoff doubles to a cap; non-retryable refusal is visible and terminal.
		now = 0;
		connector = new Connector();
		client = new RpcClient(connector, clock, function() return 1.0, options, function(_, _, _) {}, 10, 40, 30);
		for (index in 0...4) {
			client.poll();
			connector.callbacks[index](Failed({code: "offline", message: "offline", ambiguous: false}, true));
			var expected = index == 0 ? 10.0 : index == 1 ? 20.0 : 40.0;
			require(client.nextWakeAt() == now + expected, "backoff failed to double/cap");
			now += expected;
		}
		client.poll();
		connector.callbacks[4](Failed({code: "authentication_refused", message: "denied", ambiguous: false}, true));
		require(client.state == Closed
			&& client.lastError != null
			&& client.lastError.code == "authentication_refused", "authentication refusal retried");
		client.poll();
		require(connector.callbacks.length == 5, "terminal refusal attempted reconnect");

		// Server rejection must arrive before cleanup; no handler becomes accessible.
		now = 0;
		connector = new Connector();
		client = new RpcClient(connector, clock, function() return 1.0, options, function(_, _, _) {
			throw "incompatible peer established";
		}, 10, 40, 30);
		client.poll();
		pair = MemoryTransport.pair(4096, 16);
		connector.callbacks[0](Opened(pair.client));
		server = RpcHandshake.server(pair.server, clock, new RpcPeerOptions("future/1", ["read"], [], 50, 1024, 4, 4096, 2));
		pump(client, server);
		require(client.state == Closed
			&& client.lastError != null
			&& client.lastError.code == "unsupported_protocol"
			&& server.connection == null
			&& server.isFinished(),
			"incompatible version not refused");
		// An unanswered Hello expires without publishing a connection.
		now = 0;
		connector = new Connector();
		client = new RpcClient(connector, clock, function() return 1.0, options, function(_, _, _) {
			throw "timeout established";
		}, 10, 40, 30);
		client.poll();
		pair = MemoryTransport.pair();
		connector.callbacks[0](Opened(pair.client));
		client.poll();
		now = 50;
		client.poll();
		require(client.state == Disconnected
			&& client.lastError != null
			&& client.lastError.code == "handshake_timeout"
			&& !pair.client.isOpen(),
			"handshake timeout leaked connection");
		client.close();

		// Application authorization refusal travels across the handshake.
		now = 0;
		pair = MemoryTransport.pair();
		var negotiating = RpcHandshake.client(pair.client, clock, options, options.offered());
		server = RpcHandshake.server(pair.server, clock, options, function(_, _) return {code: "unauthorized", message: "denied", ambiguous: false});
		for (index in 0...8) {
			negotiating.poll();
			server.poll();
		}
		require(negotiating.failure != null
			&& negotiating.failure.code == "unauthorized"
			&& negotiating.connection == null
			&& server.isFinished(),
			"authorization refusal lost");

		// Codec compatibility is independent; required capabilities cannot disappear.
		for (codec in 1...3) {
			pair = MemoryTransport.pair();
			negotiating = RpcHandshake.client(pair.client, clock, options, options.offered());
			server = RpcHandshake.server(pair.server, clock, new RpcPeerOptions("peer", codec == 1 ? [] : ["read"], [], 50, 1024, 4, 4096, 1, codec));
			for (index in 0...8) {
				negotiating.poll();
				server.poll();
			}
			require(negotiating.failure != null && negotiating.failure.code == (codec == 1 ? "missing_capability" : "unsupported_codec"),
				"compatibility gate failed");
		}
		pair = MemoryTransport.pair();
		negotiating = RpcHandshake.client(pair.client, clock, options, options.offered());
		negotiating.poll();
		pair.server.receive();
		pair.server.send(RpcProtocol.encode(Welcome(1, 1, "peer", ["read", "secret"]), 1024));
		negotiating.poll();
		require(negotiating.failure != null && negotiating.failure.code == "capability_widening" && negotiating.connection == null,
			"forged Welcome widened policy");

		Sys.println("PASS: RPC handshake, capability ceiling, reconnect, jitter, attempt cancellation and stale-generation fencing");
	}
}
