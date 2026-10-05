package workspace.transport;

import haxeon.rpc.*;

private class SessionAttempt implements RpcConnectAttempt {
	public var base:Null<RpcConnectAttempt>;
	public var preflight:Null<SessionPreflight>;
	public var finished:Bool = false;
	public final done:RpcConnectResult->Void;

	final remove:SessionAttempt->Void;

	public function new(done:RpcConnectResult->Void, remove:SessionAttempt->Void) {
		this.done = done;
		this.remove = remove;
	}

	public function cancel():Void {
		if (finished)
			return;
		finished = true;
		remove(this);
		if (base != null)
			base.cancel();
		if (preflight != null)
			preflight.close();
	}
}

/** Host polls credential attempts alongside RpcClient. Opened transfers only an authenticated transport. */
class SessionRpcConnector implements RpcConnector {
	final connector:RpcConnector;
	final clock:Void->Float;
	final token:String;
	final pending:Array<SessionAttempt> = [];
	var disposed:Bool = false;

	public function new(connector:RpcConnector, token:String, clock:Void->Float) {
		SessionPreflight.validateToken(token);
		this.connector = connector;
		this.token = token;
		this.clock = clock;
	}

	public function connect(done:RpcConnectResult->Void):RpcConnectAttempt {
		if (disposed || pending.length >= 32)
			throw "Session connector unavailable";
		var attempt = new SessionAttempt(done, function(item) {
			pending.remove(item);
		});
		pending.push(attempt);
		try
			attempt.base = connector.connect(function(result) {
				if (attempt.finished) {
					switch result {
						case Opened(transport):
							transport.close();
						case Failed(_, _):
					}
					return;
				}
				switch result {
					case Opened(transport):
						attempt.preflight = new SessionPreflight(transport, token, clock, false);
					case Failed(error, retryable):
						pending.remove(attempt);
						attempt.finished = true;
						done(Failed(error, retryable));
				}
			})
		catch (error:Dynamic) {
			attempt.cancel();
			throw error;
		}
		return attempt;
	}

	public function poll():Void {
		for (attempt in pending.copy()) {
			var preflight = attempt.preflight;
			if (attempt.finished || preflight == null)
				continue;
			preflight.poll();
			if (!preflight.finished)
				continue;
			pending.remove(attempt);
			attempt.finished = true;
			if (preflight.authenticated)
				attempt.done(Opened(preflight.transport));
			else {
				var error = preflight.failure;
				attempt.done(Failed(error == null ? {code: "authentication_refused", message: "authentication_refused", ambiguous: false} : error, error != null
					&& (error.code == "disconnected" || error.code == "authentication_timeout")));
			}
		}
	}

	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		for (attempt in pending.copy())
			attempt.cancel();
	}
}
