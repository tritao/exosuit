package workspace.transport;

/**
	One machine-socket dial at a time, with capped exponential backoff between failures (exohost's WorkspaceRelayHost), in
	whatever time unit the caller's loop uses.
**/
class RelayMachineDialer {
	public final connector:RelayMachineConnector;
	final initialDelay:Float;
	final maxDelay:Float;
	var attempt:Null<RelayMachineConnectAttempt> = null;
	var retryAt:Float = 0;
	var retryDelay:Float;

	public function new(connector:RelayMachineConnector, initialDelay:Float, maxDelay:Float) {
		this.connector = connector;
		this.initialDelay = initialDelay;
		this.maxDelay = maxDelay;
		retryDelay = initialDelay;
	}

	/** Errors a retry cannot fix: the bearer is wrong or another machine owns the id. */
	public static function isPermanent(error:Null<String>):Bool
		return error == "relay_unauthorized" || error == "machine_identity_conflict";

	/** No dial is running and the backoff has passed. */
	public function due(now:Float):Bool
		return attempt == null && now >= retryAt;

	/**
		Dials once. `done` gets the open link, or null and an error (`relay_connect_failed` when the connector
		gave none); it is not called after `cancel`.
	**/
	public function dial(endpoint:RelayMachineEndpoint, token:String, done:Null<RelaySocketLink>->String->Void):Void {
		if (attempt != null)
			return;
		var completed = false;
		var returned:Null<RelayMachineConnectAttempt> = null;
		returned = connector.connect(endpoint, token, function(opened, error) {
			completed = true;
			if (returned != null && attempt != returned)
				return; // cancelled
			attempt = null;
			done(opened, opened != null ? "" : error == null ? "relay_connect_failed" : error);
		});
		if (!completed)
			attempt = returned;
	}

	/** A dial succeeded: the next failure retries quickly again. */
	public function connected():Void {
		retryDelay = initialDelay;
		retryAt = 0;
	}

	/** Waits before the next dial, doubling the wait up to the cap; returns the error to show. */
	public function backOff(now:Float, reason:Null<String>):String {
		retryAt = now + retryDelay;
		retryDelay = Math.min(retryDelay * 2, maxDelay);
		return reason == null || reason == "closed" ? "relay_disconnected" : reason;
	}

	/** The next dial waits at least `delay` (never less than the backoff already set), without changing the backoff. */
	public function retryAfter(now:Float, delay:Float):Void
		retryAt = Math.max(retryAt, now + delay);

	public function cancel():Void {
		var pending = attempt;
		attempt = null;
		if (pending != null)
			pending.cancel();
	}

	public function dispose():Void {
		cancel();
		connector.dispose();
	}
}
