package workspace.runtime;

import haxeon.platform.event.EventPump;
import workspace.transport.NativeRpcHub;
import workspace.transport.RelayChannel;
import workspace.transport.RelayMachineConnector;
import workspace.transport.RelayMachineDialer;
import workspace.transport.RelayMachineEndpoint;
import workspace.transport.RelaySocketLink;
import workspace.transport.RelaySocketTicket;

/**
	suit's machine socket to the relay (MachineRemote): it dials with the machine's bearer, keeps the socket and dials
	again with backoff when it drops. Inbound device channels go to `onChannel`, where the pairing manager binds Noise.
	Pairing calls (HTTPS with the same bearer) go through it too.
**/
class WorkspaceRelayHost implements WorkspacePairingRelay {
	static inline final MAX_RETRY_MILLISECONDS:Float = 30000;

	public var onChannel:Null<RelayChannel->Void>;
	public var lastError(default, null):Null<String>;
	public var connected(get, never):Bool;

	final dialer:RelayMachineDialer;
	final connector:RelayMachineConnector;
	public final endpoint:RelayMachineEndpoint;
	final machineToken:String;
	var link:Null<RelaySocketLink>;
	var permanentFailure:Bool = false;
	var disposed:Bool = false;

	public function new(events:EventPump, hub:NativeRpcHub, endpoint:RelayMachineEndpoint, machineToken:String, allowLoopbackHttp:Bool = false) {
		if (endpoint == null || !RelaySocketTicket.isToken(machineToken))
			throw "Invalid relay credentials";
		this.endpoint = endpoint;
		this.machineToken = machineToken;
		connector = new RelayMachineConnector(events, hub, allowLoopbackHttp);
		dialer = new RelayMachineDialer(connector, 1000, MAX_RETRY_MILLISECONDS);
	}

	/** Lets registration prove the machine's key when its relay id is taken (`RelayRegistrationProver`). */
	public function proveIdentityWith(prover:Null<workspace.transport.RelayRegistrationProver>):Void
		connector.prover = prover;

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

	/** The Worker is asked to close the client's socket on the channel, so the device learns at once that the machine let go. */
	public function endPairingChannel(channelId:String):Void {
		var current = link;
		if (current != null)
			current.disconnectChannel(channelId);
	}

	function get_connected():Bool {
		var current = link;
		return current != null && current.isOpen();
	}

	/** Call from the owner's event loop. */
	public function poll(now:Float):Void {
		if (disposed || permanentFailure)
			return;
		var current = link;
		if (current != null) {
			current.poll();
			if (!current.isOpen()) {
				link = null;
				lastError = dialer.backOff(now, current.failure);
			}
		}
		if (link == null && dialer.due(now))
			connect();
	}

	function connect():Void {
		dialer.dial(endpoint, machineToken, function(opened, connectError) {
			if (disposed) {
				if (opened != null)
					opened.close();
				return;
			}
			if (opened == null) {
				lastError = connectError;
				if (RelayMachineDialer.isPermanent(lastError)) {
					permanentFailure = true;
					return;
				}
				var now = nativekit.ffi.NativeKit.nk_time_seconds() * 1000;
				lastError = dialer.backOff(now, lastError);
				// The relay's challenge table was full or this address asked too often: wait what it said.
				if (lastError == "relay_rate_limited" && connector.retryAfterMilliseconds > 0)
					dialer.retryAfter(now, connector.retryAfterMilliseconds);
				return;
			}
			link = opened;
			opened.onChannel = function(channel) {
				var callback = onChannel;
				if (callback == null)
					channel.close();
				else
					callback(channel);
			};
			lastError = null;
			dialer.connected();
		});
	}

	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		if (link != null)
			link.close();
		link = null;
		dialer.dispose();
	}
}
