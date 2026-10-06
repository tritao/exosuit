package workspace.runtime;

import haxeon.platform.NativeKitEvents;
import workspace.transport.NativeRpcHub;
import workspace.transport.RelayChannel;
import workspace.transport.RelayMachineConnectAttempt;
import workspace.transport.RelayMachineConnector;
import workspace.transport.RelayMachineEndpoint;
import workspace.transport.RelaySocketLink;

/** Daemon-owned outbound relay connection. Inbound channels wait for Noise binding. */
class WorkspaceRelayHost {
	static inline final MAX_RETRY_MILLISECONDS:Float = 30000;

	public var onChannel:Null<RelayChannel->Void>;
	public var lastError(default, null):Null<String>;
	public var connected(get, never):Bool;

	final connector:RelayMachineConnector;
	final endpoint:RelayMachineEndpoint;
	final machineToken:String;
	var attempt:Null<RelayMachineConnectAttempt>;
	var link:Null<RelaySocketLink>;
	var retryAt:Float = 0;
	var retryDelay:Float = 1000;
	var permanentFailure:Bool = false;
	var disposed:Bool = false;

	public function new(events:NativeKitEvents, hub:NativeRpcHub, settings:WorkspaceRelaySettings,
		allowLoopbackHttp:Bool = false) {
		if (settings == null)
			throw "Workspace relay settings are required";
		endpoint = settings.endpoint;
		machineToken = settings.machineToken;
		connector = new RelayMachineConnector(events, hub, allowLoopbackHttp);
	}

	/** A configured remote endpoint deliberately keeps the workspace service available. */
	public function activeCount():Int
		return disposed || permanentFailure ? 0 : 1;

	function get_connected():Bool
		return link != null && link.isOpen();

	/** Call from the daemon's normal NativeKit event loop. */
	public function poll(now:Float):Void {
		if (disposed || permanentFailure)
			return;
		var current = link;
		if (current != null) {
			current.poll();
			if (!current.isOpen()) {
				link = null;
				scheduleRetry(now, current.failure);
			}
		}
		if (attempt == null && link == null && now >= retryAt)
			connect(now);
	}

	function connect(now:Float):Void {
		var completedSynchronously = false;
		var returned:Null<RelayMachineConnectAttempt> = null;
		returned = connector.connect(endpoint, machineToken, function(opened, error) {
			completedSynchronously = true;
			if (disposed) {
				if (opened != null)
					opened.close();
				return;
			}
			if (returned != null && attempt == returned)
				attempt = null;
			if (opened == null) {
				lastError = error == null ? "relay_connect_failed" : error;
				if (lastError == "relay_unauthorized" || lastError == "machine_identity_conflict") {
					permanentFailure = true;
					return;
				}
				scheduleRetry(nowMilliseconds(), lastError);
				return;
			}
			link = opened;
			link.onChannel = function(channel) {
				var callback = onChannel;
				if (callback == null)
					channel.close();
				else
					callback(channel);
			};
			lastError = null;
			retryDelay = 1000;
			retryAt = 0;
		});
		if (!completedSynchronously)
			attempt = returned;
	}

	function nowMilliseconds():Float
		return nativekit.ffi.NativeKit.nk_time_seconds() * 1000;

	function scheduleRetry(now:Float, error:Null<String>):Void {
		lastError = error == null || error == "closed" ? "relay_disconnected" : error;
		retryAt = now + retryDelay;
		retryDelay = Math.min(retryDelay * 2, MAX_RETRY_MILLISECONDS);
	}

	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		if (attempt != null)
			attempt.cancel();
		attempt = null;
		if (link != null)
			link.close();
		link = null;
		connector.dispose();
	}
}
