package workspace.transport;

import haxe.io.Bytes;
import haxeon.rpc.MessageTransport;
import haxeon.rpc.RpcError;

/** Loopback-only session credential exchange before RPC. Not remote encryption.
 * Caller supplies a cryptographically generated 256-bit token as 64 hex digits. */
class SessionPreflight {
	public var authenticated(default, null):Bool = false;
	public var finished(default, null):Bool = false;
	public var failure(default, null):Null<RpcError>;
	public final transport:MessageTransport;

	final clock:Void->Float;
	final deadline:Float;
	final server:Bool;
	final key:Bytes;
	var sent:Bool = false;
	var received:Bool = false;
	var accepted:Bool = false;
	var acknowledgement:Null<Bytes>;

	public function new(transport:MessageTransport, token:String, clock:Void->Float, server:Bool, timeoutMs:Int = 5000) {
		validateToken(token);
		if (timeoutMs < 1)
			throw "Invalid authentication timeout";
		this.transport = transport;
		this.clock = clock;
		this.server = server;
		this.key = Bytes.ofString(token);
		deadline = clock() + timeoutMs;
	}

	public static function validateToken(token:String):Void {
		if (token == null || token.length != 64)
			throw "Session token must be 64 lowercase hex digits";
		for (index in 0...token.length) {
			var value = token.charCodeAt(index);
			if (!(value >= 48 && value <= 57 || value >= 97 && value <= 102))
				throw "Invalid session token";
		}
	}

	function fail(code:String):Void {
		failure = {code: code, message: code, ambiguous: false};
		finished = true;
		transport.close();
	}

	public function close():Void {
		finished = true;
		transport.close();
	}

	public function poll():Void {
		if (finished)
			return;
		if (!transport.isOpen()) {
			fail("disconnected");
			return;
		}
		if (clock() >= deadline) {
			fail(failure == null ? "authentication_timeout" : failure.code);
			return;
		}
		if (!server) {
			if (!sent) {
				if (!transport.send(key))
					return;
				sent = true;
			}
			var answer = transport.receive();
			if (answer == null)
				return;
			if (answer.length == 1 && answer.get(0) == 1) {
				authenticated = true;
				finished = true;
			} else
				fail("authentication_refused");
		} else {
			if (!received) {
				var offered = transport.receive();
				if (offered == null)
					return;
				var difference = offered.length ^ key.length;
				if (offered.length == key.length)
					for (index in 0...key.length)
						difference |= offered.get(index) ^ key.get(index);
				accepted = difference == 0;
				received = true;
				acknowledgement = Bytes.alloc(1);
				acknowledgement.set(0, accepted ? 1 : 0);
				if (!accepted)
					failure = {code: "authentication_refused", message: "authentication_refused", ambiguous: false};
			}
			if (!sent && acknowledgement != null) {
				if (!transport.send(acknowledgement))
					return;
				sent = true;
				acknowledgement = null;
			}
			if (accepted) {
				authenticated = true;
				finished = true;
			}
			// On refusal, let the peer read the accepted acknowledgement before abrupt close.
		}
	}
}
