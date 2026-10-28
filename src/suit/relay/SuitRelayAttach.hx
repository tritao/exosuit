package suit.relay;

import haxe.Json;
import haxeon.rpc.RpcConnectAttempt;
import suit.SuitPaths;
import haxeon.rpc.RpcConnectResult;
import suit.relay.SuitRelayProtocol.SuitRelayAttachRequest;
import workspace.transport.NativeRpcHub;
import workspace.transport.NativeRpcTransport;

/**
	One attempt by a workspace daemon to reach the relay through suit: connect to suit's control endpoint,
	send `relay-attach`, wait for the answer. It completes from `poll` only, never synchronously, with a
	stream or a reason: `suit_unavailable` when no suit answers, otherwise suit's refusal.
**/
class SuitRelayAttach {
	static inline var TIMEOUT_MILLISECONDS:Float = 3000;

	final done:Null<SuitRelayStream>->Null<String>->Void;
	final deadline:Float;
	final request:SuitRelayAttachRequest;
	var connect:Null<RpcConnectAttempt> = null;
	var transport:Null<NativeRpcTransport> = null;
	var failure:Null<String> = null;
	var sent:Bool = false;
	var finished:Bool = false;

	public function new(hub:NativeRpcHub, request:SuitRelayAttachRequest, now:Float, done:Null<SuitRelayStream>->Null<String>->Void) {
		this.request = request;
		this.done = done;
		deadline = now + TIMEOUT_MILLISECONDS;
		try {
			connect = hub.connect(NativeRpcHub.local(SuitPaths.endpoint()), function(result:RpcConnectResult) {
				switch result {
					case Opened(opened):
						if (finished)
							opened.close();
						else
							transport = cast opened;
					default:
						if (failure == null)
							failure = "suit_unavailable";
				}
			});
		} catch (_:Dynamic) {
			failure = "suit_unavailable";
		}
	}

	public function poll(now:Float):Void {
		if (finished)
			return;
		if (failure != null) {
			finish(null, failure);
			return;
		}
		if (now >= deadline) {
			finish(null, "suit_unavailable");
			return;
		}
		var current = transport;
		if (current == null)
			return;
		if (!current.isOpen()) {
			finish(null, "suit_unavailable");
			return;
		}
		if (!sent)
			sent = current.send(SuitRelayProtocol.attachMessage(request));
		if (!sent)
			return;
		var reply = current.receive();
		if (reply == null)
			return;
		var value:Dynamic = null;
		try value = Json.parse(reply.toString()) catch (_:Dynamic) {}
		if (value == null || Reflect.field(value, "ok") != true) {
			var error:Dynamic = value == null ? null : Reflect.field(value, "error");
			finish(null, Std.isOfType(error, String) ? cast error : "suit_refused");
			return;
		}
		transport = null;
		finish(new SuitRelayStream(current), null);
	}

	function finish(stream:Null<SuitRelayStream>, error:Null<String>):Void {
		if (finished)
			return;
		finished = true;
		if (stream == null) {
			var current = transport;
			if (current != null)
				current.close();
			var pending = connect;
			if (pending != null)
				pending.cancel();
		}
		transport = null;
		done(stream, error);
	}

	public function cancel():Void {
		if (finished)
			return;
		finished = true;
		var current = transport;
		if (current != null)
			current.close();
		transport = null;
		var pending = connect;
		if (pending != null)
			pending.cancel();
	}
}
