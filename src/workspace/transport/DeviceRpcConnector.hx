package workspace.transport;

import haxe.io.Bytes;
import haxeon.platform.NativeKitEvents;
import haxeon.rpc.MessageTransport;
import haxeon.rpc.RpcConnectAttempt;
import haxeon.rpc.RpcConnectResult;
import haxeon.rpc.RpcConnector;

private class CompletedDeviceAttempt implements RpcConnectAttempt {
	public function new() {}
	public function cancel():Void {}
}

private class DeviceConnectAttempt implements RpcConnectAttempt {
	final owner:DeviceRpcConnector;
	final done:RpcConnectResult->Void;
	var finished:Bool = false;
	var ticket:Null<RelayTicketAttempt>;
	var socket:Null<RpcConnectAttempt>;
	var handshake:Null<NoiseClientHandshake>;
	var secure:Null<NoiseMessageTransport>;
	var channel:Null<RelayDeviceTransport>;

	public function new(owner:DeviceRpcConnector, done:RpcConnectResult->Void) {
		this.owner = owner;
		this.done = done;
	}

	public function start():Void {
		var request = owner.tickets.request(owner.endpoint, owner.deviceToken, function(value, error) {
			if (finished) return;
			ticket = null;
			if (error != null || value == null) {
				fail(error == null ? "invalid_relay_ticket" : error, owner.ticketRetryable(error));
				return;
			}
			openSocket(value);
		});
		if (finished) request.cancel() else ticket = request;
	}

	function openSocket(value:RelaySocketTicket):Void {
		try {
			var options = NativeRpcHub.websocketUrl(owner.endpoint.websocketUrl(value));
			var attempt = owner.hub.connectBytes(options, function(stream, error) {
				if (finished) {
					if (stream != null) stream.close();
					return;
				}
				socket = null;
				if (stream == null) {
					fail(error == null ? "relay_connect_failed" : error, true);
					return;
				}
				try {
					channel = new RelayDeviceTransport(stream, owner.deviceId);
					handshake = new NoiseClientHandshake(channel, owner.privateKey, owner.machineKey,
						NoisePrologue.encode(owner.machineId, owner.deviceId), owner.clock,
						function(transport) secure = transport);
				} catch (_:Dynamic) {
					stream.close();
					fail("noise_handshake_start_failed", true);
				}
			});
			if (finished) attempt.cancel() else socket = attempt;
		} catch (_:Dynamic) {
			fail("relay_connect_failed", true);
		}
	}

	public function poll():Void {
		if (finished || handshake == null) return;
		var current = handshake;
		current.poll();
		if (!current.finished) return;
		handshake = null;
		if (current.failure != null || secure == null) {
			var reason = current.failure == null ? "noise_handshake_failed" : current.failure;
			fail(reason, owner.noiseRetryable(reason));
			return;
		}
		var transport = secure;
		secure = null;
		channel = null;
		finish(haxeon.rpc.RpcConnectResult.Opened(transport));
	}

	function fail(code:String, retryable:Bool):Void
		finish(haxeon.rpc.RpcConnectResult.Failed({code: code, message: code, ambiguous: false}, retryable));

	function finish(result:RpcConnectResult):Void {
		if (finished) {
			switch result {
				case Opened(transport): transport.close();
				case Failed(_, _):
			}
			return;
		}
		finished = true;
		owner.remove(this);
		closeResources(false);
		done(result);
	}

	function closeResources(closeSecure:Bool):Void {
		var request = ticket;
		ticket = null;
		if (request != null) request.cancel();
		var pending = socket;
		socket = null;
		if (pending != null) pending.cancel();
		var current = handshake;
		handshake = null;
		if (current != null) current.close();
		var transport = secure;
		secure = null;
		if (closeSecure && transport != null) transport.close();
		var relay = channel;
		channel = null;
		if (relay != null) relay.close();
	}

	public function cancel():Void {
		if (finished) return;
		finished = true;
		owner.remove(this);
		closeResources(true);
	}

	public function abort():Void cancel();
}

/** Reopens a relay route and authenticates its pinned machine before each RPC retry. */
class DeviceRpcConnector implements RpcConnector {
	public final hub:NativeRpcHub;
	public final tickets:RelayTicketClient;
	public final endpoint:RelayMachineEndpoint;
	public final machineId:String;
	public final deviceId:String;
	public final deviceToken:String;
	public final privateKey:Bytes;
	public final machineKey:Bytes;
	public final clock:Void->Float;
	var first:Null<MessageTransport>;
	final pending:Array<DeviceConnectAttempt> = [];
	var disposed:Bool = false;

	public function new(events:NativeKitEvents, hub:NativeRpcHub, clock:Void->Float,
		endpoint:RelayMachineEndpoint, machineId:String, deviceId:String, deviceToken:String,
		privateKey:Bytes, machineKey:Bytes, ?first:MessageTransport) {
		if (events == null || hub == null || clock == null || endpoint == null
			|| machineId == null || deviceId == null || machineId != endpoint.machineId
			|| deviceToken == null || privateKey == null || privateKey.length != 32
			|| machineKey == null || machineKey.length != 32
			|| !RelaySocketTicket.isToken(deviceToken)
			|| first != null && !first.isOpen())
			throw "Invalid authenticated device connector configuration";
		this.hub = hub;
		this.clock = clock;
		this.endpoint = endpoint;
		this.machineId = machineId;
		this.deviceId = deviceId;
		this.deviceToken = deviceToken;
		this.privateKey = privateKey;
		this.machineKey = machineKey;
		this.first = first;
		tickets = new RelayTicketClient(events, endpoint.isLoopbackHttp);
	}

	public function connect(complete:RpcConnectResult->Void):RpcConnectAttempt {
		if (complete == null) throw "Device RPC completion callback cannot be null";
		if (disposed) {
			complete(haxeon.rpc.RpcConnectResult.Failed({code: "connector_closed", message: "connector_closed", ambiguous: false}, false));
			return new CompletedDeviceAttempt();
		}
		var initial = first;
		if (initial != null) {
			first = null;
			complete(haxeon.rpc.RpcConnectResult.Opened(initial));
			return new CompletedDeviceAttempt();
		}
		if (pending.length >= 4) {
			complete(haxeon.rpc.RpcConnectResult.Failed({code: "connector_overloaded", message: "connector_overloaded", ambiguous: false}, true));
			return new CompletedDeviceAttempt();
		}
		var attempt = new DeviceConnectAttempt(this, complete);
		pending.push(attempt);
		attempt.start();
		return attempt;
	}

	public function poll():Void {
		for (attempt in pending.copy()) attempt.poll();
	}

	@:allow(workspace.transport.DeviceConnectAttempt)
	function remove(attempt:DeviceConnectAttempt):Void pending.remove(attempt);

	function ticketRetryable(code:Null<String>):Bool
		return code == "relay_unavailable" || code == "relay_rate_limited"
			|| code == "ticket_transport_failed" || code == "ticket_request_failed";

	function noiseRetryable(code:String):Bool
		return code == "noise_disconnected" || code == "noise_timeout"
			|| code == "noise_send_failed";

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		for (attempt in pending.copy()) attempt.abort();
		pending.resize(0);
		var transport = first;
		first = null;
		if (transport != null) transport.close();
		tickets.dispose();
		for (index in 0...privateKey.length) privateKey.set(index, 0);
	}
}
