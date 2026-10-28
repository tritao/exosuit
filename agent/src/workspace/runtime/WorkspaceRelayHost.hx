package workspace.runtime;

import haxeon.platform.NativeKitEvents;
import suit.relay.SuitRelayAttach;
import suit.relay.SuitRelayProtocol.SuitRelayAttachRequest;
import suit.relay.SuitRelayStream;
import workspace.transport.NativeRpcHub;
import workspace.transport.RelayChannel;
import workspace.transport.RelayMachineConnectAttempt;
import workspace.transport.RelayMachineConnector;
import workspace.transport.RelayMachineEndpoint;
import workspace.transport.RelaySocketLink;

/**
	The daemon's relay connection. Inbound channels wait for Noise binding.

	With a suit attach request it reaches the relay through suit, which holds the single machine socket
	(see docs/roadmap/16-remote-workspaces.md, "Relay hosting under suit"): every (re)connect tries suit
	first and dials the relay itself only when suit is not running or refuses. While connected directly
	it retries suit every 30 s and drops its own socket once suit accepts, since the Worker keeps only one
	machine socket and suit's must win. Pairing calls (HTTPS with the machine bearer) stay in the daemon.
**/
class WorkspaceRelayHost implements WorkspacePairingRelay {
	static inline final MAX_RETRY_MILLISECONDS:Float = 30000;
	static inline final SUIT_PROBE_MILLISECONDS:Float = 30000;

	public var onChannel:Null<RelayChannel->Void>;
	public var lastError(get, never):Null<String>;
	public var connected(get, never):Bool;

	/** True while suit holds the machine socket and this daemon reaches it over suit's relay link. */
	public var viaSuit(get, never):Bool;

	final hub:NativeRpcHub;
	final connector:RelayMachineConnector;
	final endpoint:RelayMachineEndpoint;
	final machineToken:String;
	final suitRequest:Null<SuitRelayAttachRequest>;
	var error:Null<String>;
	var attempt:Null<RelayMachineConnectAttempt>;
	var suitAttempt:Null<SuitRelayAttach>;
	var link:Null<RelaySocketLink>;
	var suitStream:Null<SuitRelayStream>;
	var retryAt:Float = 0;
	var retryDelay:Float = 1000;
	var suitProbeAt:Float = 0;
	var permanentFailure:Bool = false;
	var disposed:Bool = false;

	public function new(events:NativeKitEvents, hub:NativeRpcHub, settings:WorkspaceRelaySettings,
		allowLoopbackHttp:Bool = false, ?suit:SuitRelayAttachRequest) {
		if (settings == null)
			throw "Workspace relay settings are required";
		this.hub = hub;
		endpoint = settings.endpoint;
		machineToken = settings.machineToken;
		suitRequest = suit;
		connector = new RelayMachineConnector(events, hub, allowLoopbackHttp);
	}

	/**
		A directly held relay socket deliberately keeps the workspace service available. Through suit it
		does not: suit keeps the machine socket and starts the service again when a device needs it.
	**/
	public function activeCount():Int
		return disposed || permanentFailure || viaSuit ? 0 : 1;

	public function pairingEndpoint():RelayMachineEndpoint
		return endpoint;

	public function isConnected():Bool
		return connected;

	public function createPairing(channelId:String, secret:String, ttlSeconds:Int, complete:Null<String>->Void):Void {
		if (disposed || permanentFailure || !connected) {
			complete("relay_machine_offline");
			return;
		}
		connector.createPairing(endpoint, machineToken, channelId, secret, ttlSeconds, complete);
	}

	public function registerDevice(channelId:String, token:String, complete:Null<String>->Void):Void {
		if (disposed || permanentFailure || !connected) {
			complete("relay_machine_offline");
			return;
		}
		connector.registerDevice(endpoint, machineToken, channelId, token, complete);
	}

	public function revokeDevice(channelId:String, complete:Null<String>->Void):Void
		connector.revokeDevice(endpoint, machineToken, channelId, complete);

	function get_connected():Bool {
		var current = link, stream = suitStream;
		return current != null && current.isOpen() && (stream == null || stream.relayConnected);
	}

	function get_viaSuit():Bool {
		var current = link;
		return suitStream != null && current != null && current.isOpen();
	}

	function get_lastError():Null<String> {
		var stream = suitStream;
		return stream != null && viaSuit ? stream.relayError : error;
	}

	/** Call from the daemon's normal NativeKit event loop. */
	public function poll(now:Float):Void {
		if (disposed || permanentFailure)
			return;
		var current = link;
		if (current != null) {
			current.poll();
			if (!current.isOpen()) {
				var wasSuit = suitStream != null;
				link = null;
				suitStream = null;
				scheduleRetry(now, current.failure);
				if (wasSuit) {
					// suit stopped or another daemon for this workspace attached; come back promptly.
					retryAt = now + 250;
					retryDelay = 1000;
				}
			} else if (suitStream == null && suitRequest != null && suitAttempt == null && now >= suitProbeAt) {
				suitProbeAt = now + SUIT_PROBE_MILLISECONDS;
				startSuitAttach(now, true);
			}
		}
		var pending = suitAttempt;
		if (pending != null)
			pending.poll(now);
		if (attempt == null && suitAttempt == null && link == null && now >= retryAt)
			connect(now);
	}

	function connect(now:Float):Void {
		if (suitRequest != null)
			startSuitAttach(now, false);
		else
			connectDirect();
	}

	/** A probe runs beside a direct socket and replaces it on success; otherwise a refusal falls back to dialling. */
	function startSuitAttach(now:Float, probe:Bool):Void {
		var request = suitRequest;
		if (request == null)
			return;
		var started:Null<SuitRelayAttach> = null;
		started = new SuitRelayAttach(hub, request, now, function(stream, attachError) {
			if (suitAttempt == started)
				suitAttempt = null;
			if (disposed) {
				if (stream != null)
					stream.close();
				return;
			}
			if (stream != null) {
				var direct = link;
				link = null;
				if (direct != null)
					direct.close();
				adopt(new RelaySocketLink(stream), stream);
				return;
			}
			if (probe || link != null || attempt != null)
				return;
			if (attachError == "hosting_paused") {
				// Paused from suit: nobody hosts until it is resumed, so do not dial the relay either.
				error = attachError;
				retryAt = nowMilliseconds() + SUIT_PROBE_MILLISECONDS;
				return;
			}
			connectDirect();
		});
		suitAttempt = started;
	}

	function connectDirect():Void {
		var completedSynchronously = false;
		var returned:Null<RelayMachineConnectAttempt> = null;
		returned = connector.connect(endpoint, machineToken, function(opened, connectError) {
			completedSynchronously = true;
			if (disposed) {
				if (opened != null)
					opened.close();
				return;
			}
			if (returned != null && attempt == returned)
				attempt = null;
			if (opened == null) {
				error = connectError == null ? "relay_connect_failed" : connectError;
				if (error == "relay_unauthorized" || error == "machine_identity_conflict") {
					permanentFailure = true;
					return;
				}
				scheduleRetry(nowMilliseconds(), error);
				return;
			}
			if (link != null) {
				// suit accepted while this socket was being opened; suit's socket wins.
				opened.close();
				return;
			}
			suitProbeAt = nowMilliseconds() + SUIT_PROBE_MILLISECONDS;
			adopt(opened, null);
		});
		if (!completedSynchronously)
			attempt = returned;
	}

	function adopt(opened:RelaySocketLink, stream:Null<SuitRelayStream>):Void {
		link = opened;
		suitStream = stream;
		opened.onChannel = function(channel) {
			var callback = onChannel;
			if (callback == null)
				channel.close();
			else
				callback(channel);
		};
		error = null;
		retryDelay = 1000;
		retryAt = 0;
	}

	function nowMilliseconds():Float
		return nativekit.ffi.NativeKit.nk_time_seconds() * 1000;

	function scheduleRetry(now:Float, reason:Null<String>):Void {
		error = reason == null || reason == "closed" ? "relay_disconnected" : reason;
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
		var pending = suitAttempt;
		if (pending != null)
			pending.cancel();
		suitAttempt = null;
		if (link != null)
			link.close();
		link = null;
		suitStream = null;
		connector.dispose();
	}
}
