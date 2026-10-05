package app;

import haxe.io.Bytes;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcContext;
import haxeon.rpc.RpcMethod;
import haxeon.wire.MessagePack;

@:wire typedef Query = {@:id(1) var name:String;}
@:wire typedef Answer = {@:id(1) var text:String;}

class RpcDispatchTests {
	static function require(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}

	public static function run():Void {
		var method = new RpcMethod<Query, Answer>(100, function(value:Query) return MessagePack.encode(value),
			function(bytes:Bytes):Query return MessagePack.decode(bytes), function(value:Answer) return MessagePack.encode(value),
			function(bytes:Bytes):Answer return MessagePack.decode(bytes));
		var now = 0.0;
		var pair = MemoryTransport.pair(4096, 16);
		var client = new RpcConnection(pair.client, function() return now, 1024, 2, 4096);
		var server = new RpcConnection(pair.server, function() return now, 1024, 2, 4096);
		var contexts:Array<RpcContext<Answer>> = [];
		var names:Array<String> = [];
		server.register(method, function(request, context) {
			names.push(request.name);
			contexts.push(context);
		});
		var results:Array<String> = [],
			errors:Array<String> = [],
			ambiguous:Array<Bool> = [];
		var success = function(value:Answer):Void {
			results.push(value.text);
		};
		var failure = function(error:haxeon.rpc.RpcError) {
			errors.push(error.code);
			ambiguous.push(error.ambiguous);
		};
		client.call(method, {name: "one"}, 100, success, failure);
		require(server.poll() == 1 && names[0] == "one" && results.length == 0, "handler did not defer");
		require(contexts[0].respond({text: "answer"}) && !contexts[0].respond({text: "twice"}), "completion not at most once");
		client.poll();
		require(results.length == 1 && results[0] == "answer", "typed response lost");
		var cancelled = client.call(method, {name: "cancel"}, 100, success, failure);
		server.poll();
		require(client.cancel(cancelled), "cancel rejected");
		server.poll();
		require(contexts[1].isCancelled() && !contexts[1].respond({text: "late"}), "cancelled work replied");
		require(errors[0] == "cancelled" && ambiguous[0], "cancel failure semantics");
		client.call(method, {name: "expire"}, 10, success, failure);
		server.poll();
		now = 10;
		require(contexts[2].isCancelled() && !contexts[2].respond({text: "expired"}), "deadline ignored before polling");
		client.poll();
		server.poll();
		client.poll();
		require(errors[1] == "timeout" && client.pendingCalls() == 0 && server.activeRequests() == 0, "deadline retirement failed");
		client.call(method, {name: "a"}, 100, success, failure);
		client.call(method, {name: "b"}, 100, success, failure);
		require(client.call(method, {name: "busy"}, 100, success, failure) == 0
			&& errors[2] == "busy"
			&& !ambiguous[2], "pending cap ignored");
		require(server.poll(1, 1024) == 1 && server.activeRequests() == 1, "poll message budget ignored");
		server.poll();
		pair.server.close();
		client.poll();
		server.poll();
		require(errors.length == 5 && ambiguous[3] && ambiguous[4] && client.pendingCalls() == 0, "disconnect lost pending calls");
		require(!contexts[3].respond({text: "old generation"}), "disconnected context replied");
		require(client.call(method, {name: "closed"}, 100, success, failure) == 0 && !ambiguous[5], "pre-dispatch disconnect ambiguous");

		pair = MemoryTransport.pair(4096, 1);
		client = new RpcConnection(pair.client, function() return now, 1024, 2, 4096);
		server = new RpcConnection(pair.server, function() return now, 1024, 2, 4096);
		client.call(method, {name: "unknown"}, 100, success, failure);
		server.poll();
		client.poll();
		require(errors[6] == "unknown_method" && !ambiguous[6], "unknown method not rejected");
		server.register(method, function(request, context) {
			context.respond({text: request.name});
		});
		pair.server.loseNext();
		client.call(method, {name: "lost"}, 10, success, failure);
		server.poll();
		now = 20;
		client.poll();
		server.poll();
		require(errors[7] == "timeout" && ambiguous[7] && results.length == 1, "lost reply silently succeeded");
		var notices:Array<String> = [];
		client.onNotification(101, function(bytes:Bytes):Answer return MessagePack.decode(bytes), function(value):Void {
			notices.push(value.text);
		});
		require(server.notify(101, {text: "event"}, function(value:Answer) return MessagePack.encode(value)), "notification rejected");
		client.poll();
		require(notices.length == 1 && notices[0] == "event", "typed notification lost");
		client.close();
		server.close();

		// A slow consumer cannot grow the response/notification queue indefinitely.
		pair = MemoryTransport.pair(4096, 1);
		server = new RpcConnection(pair.server, function() return now, 1024, 2, 4096);
		for (index in 0...3)
			require(server.notify(101, {text: "queued"}, function(value:Answer) return MessagePack.encode(value)), "bounded queue rejected early");
		require(server.bufferedBytes() > 0 && server.bufferedBytes() <= 4096, "queued notification bytes unbounded");
		require(!server.notify(101, {text: "overflow"}, function(value:Answer) return MessagePack.encode(value))
			&& !server.isOpen()
			&& server.bufferedBytes() == 0,
			"slow consumer did not retire bounded queue");

		// The server bounds independently retained asynchronous handlers.
		pair = MemoryTransport.pair(4096, 16);
		client = new RpcConnection(pair.client, function() return now, 1024, 4, 4096);
		server = new RpcConnection(pair.server, function() return now, 1024, 1, 4096);
		var saved:Array<RpcContext<Answer>> = [];
		server.register(method, function(request, context) {
			saved.push(context);
		});
		client.call(method, {name: "first"}, 100, success, failure);
		client.call(method, {name: "second"}, 100, success, failure);
		server.poll();
		client.poll();
		require(saved.length == 1 && server.activeRequests() == 1 && errors[8] == "busy" && !ambiguous[8], "active handler limit ignored");
		var malformedRequest = Bytes.alloc(1);
		malformedRequest.set(0, 0xc1);
		saved[0].respond({text: "done"});
		client.poll();
		pair.client.send(haxeon.rpc.RpcProtocol.encode(haxeon.rpc.RpcEnvelope.Request(3, 100, 100, malformedRequest), 1024));
		server.poll();
		var invalidReply = pair.client.receive();
		require(invalidReply != null, "invalid payload lacked response");
		if (invalidReply != null)
			switch haxeon.rpc.RpcProtocol.decode(invalidReply, 1024) {
				case Failed(_, error):
					require(error.code == "invalid_request" && !error.ambiguous, "invalid request failure semantics");
				default:
					throw "malformed payload accepted";
			}
		server.register(new RpcMethod<Query, Answer>(102, method.encodeRequest, method.decodeRequest, method.encodeResponse, method.decodeResponse),
			function(request, context) {
				throw "private server exception";
			});
		pair.client.send(haxeon.rpc.RpcProtocol.encode(haxeon.rpc.RpcEnvelope.Request(4, 102, 100, method.encodeRequest({name: "throw"})), 1024));
		server.poll();
		var failedReply = pair.client.receive();
		if (failedReply == null)
			throw "handler exception lacked response";
		switch haxeon.rpc.RpcProtocol.decode(failedReply, 1024) {
			case Failed(_, error):
				require(error.code == "handler_failed" && error.message.indexOf("private") < 0 && error.ambiguous,
					"server exception exposed or ambiguity lost");
			default:
				throw "handler exception accepted";
		}
		client.close();
		server.close();
		// Handler-generated messages share the outgoing poll budget.
		pair = MemoryTransport.pair(4096, 16);
		server = new RpcConnection(pair.server, function() return now, 1024, 4, 4096);
		require(server.isOpen(), "budget server closed directly after construction");
		var expectedServer = server;
		server.register(method, function(request, context) {
			server.notify(101, {text: "first"}, function(value:Answer) return MessagePack.encode(value));
			server.notify(101, {text: "second"}, function(value:Answer) return MessagePack.encode(value));
			context.respond({text: "third"});
		});
		require(server == expectedServer, "register changed server reference");
		require(pair.client.isOpen(), "register closed peer");
		require(expectedServer.isOpen(), "register closed expected server");
		require(server.isOpen(), "budget server closed before input");
		require(pair.client.send(haxeon.rpc.RpcProtocol.encode(haxeon.rpc.RpcEnvelope.Request(1, 100, 100, method.encodeRequest({name: "budget"})), 1024)),
			"budget request rejected");
		var pollCount = server.poll(1, 1024);
		require(pollCount == 1 && pair.client.bufferedMessages() == 1 && server.bufferedBytes() > 0,
			"handler bypassed send budget: "
			+ pollCount
			+ ", "
			+ pair.client.bufferedMessages()
			+ ", "
			+ server.bufferedBytes());
		server.poll(1, 1024);
		require(pair.client.bufferedMessages() == 2, "queued output ignored message budget");
		server.poll(1, 1024);
		require(pair.client.bufferedMessages() == 3 && server.bufferedBytes() == 0, "queued output failed to drain");
		server.close();

		// Byte budgets retain one bounded message and resume it on the next poll.
		pair = MemoryTransport.pair(4096, 16);
		server = new RpcConnection(pair.server, function() return now, 1024, 4, 4096);
		var received = 0;
		server.onNotification(101, function(bytes:Bytes):Answer return MessagePack.decode(bytes), function(value) {
			received++;
		});
		var longText = "";
		for (index in 0...600)
			longText += "x";
		var notification = haxeon.rpc.RpcProtocol.encode(haxeon.rpc.RpcEnvelope.Notification(101, MessagePack.encode(({text: longText} : Answer))), 1024);
		for (index in 0...3)
			pair.client.send(notification);
		require(server.poll(32, 1024) == 1
			&& received == 1
			&& server.bufferedBytes() == notification.length, "incoming byte budget ignored");
		require(server.poll(32, 1024) == 1 && received == 2, "held input failed to resume");
		server.poll(32, 1024);
		require(received == 3 && server.bufferedBytes() == 0, "held input leaked");
		server.close();

		// A queued successful reply cannot resurrect a cancelled client call.
		pair = MemoryTransport.pair(4096, 16);
		client = new RpcConnection(pair.client, function() return now, 1024, 4, 4096);
		server = new RpcConnection(pair.server, function() return now, 1024, 4, 4096);
		server.register(method, function(request, context) {
			context.respond({text: "already queued"});
		});
		var lateResults = 0, cancelledResults = 0;
		var raced = client.call(method, {name: "race"}, 100, function(answer) {
			lateResults++;
		}, function(error) {
			cancelledResults++;
		});
		server.poll();
		client.cancel(raced);
		client.poll();
		server.poll();
		require(lateResults == 0 && cancelledResults == 1, "late success resurrected cancelled call");
		// All waiters receive disconnect even if one application callback throws.
		var retired = 0;
		client.call(method, {name: "throws"}, 100, success, function(error) {
			retired++;
			throw "application callback failed";
		});
		client.call(method, {name: "other"}, 100, success, function(error) {
			retired++;
		});
		var callbackRaised = false;
		try
			client.close()
		catch (_:Dynamic) {
			callbackRaised = true;
		}
		require(callbackRaised && retired == 2 && client.pendingCalls() == 0, "throwing callback stranded another waiter");
		server.close();
		Sys.println("PASS: typed asynchronous RPC calls, deadlines, cancellation, loss, disconnect and poll bounds");
	}
}
