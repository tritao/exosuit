package workspace.transport;

import haxeon.platform.NativeKitEvents;

/** Gets a one-use machine ticket, then opens the single outbound relay socket. */
class RelayMachineConnector {
	final hub:NativeRpcHub;
	final tickets:RelayTicketClient;
	final attempts:Array<RelayMachineConnectAttempt> = [];
	var disposed:Bool = false;

	public function new(events:NativeKitEvents, hub:NativeRpcHub, allowLoopbackHttp:Bool = false) {
		if (hub == null)
			throw "Relay machine connector requires the native transport hub";
		this.hub = hub;
		tickets = new RelayTicketClient(events, allowLoopbackHttp);
	}

	public function connect(endpoint:RelayMachineEndpoint, machineToken:String,
		complete:RelaySocketLink->Null<String>->Void):RelayMachineConnectAttempt {
		if (complete == null)
			throw "Relay connection callback cannot be null";
		var attempt = new RelayMachineConnectAttempt(function(item) attempts.remove(item));
		if (disposed) {
			attempt.finish();
			complete(null, "relay_connector_closed");
			return attempt;
		}
		if (attempts.length >= 8) {
			attempt.finish();
			complete(null, "relay_connection_limit");
			return attempt;
		}
		attempts.push(attempt);
		var registrationAttempt = tickets.register(endpoint, machineToken, function(error) {
			if (!attempt.isActive())
				return;
			if (error != null) {
				if (attempt.finish())
					complete(null, error);
				return;
			}
			var ticketAttempt = tickets.request(endpoint, machineToken, function(ticket, ticketError) {
				if (!attempt.isActive())
					return;
				if (ticket == null) {
					if (attempt.finish())
						complete(null, ticketError == null ? "ticket_request_failed" : ticketError);
					return;
				}
				// Keep the connect attempt cancellable until NativeKit reports WebSocket ready.
				var options = NativeRpcHub.websocketUrl(endpoint.websocketUrl(ticket));
				var socketAttempt = hub.connectBytes(options, function(stream, connectError) {
					if (stream == null) {
						if (attempt.finish())
							complete(null, connectError == null ? "relay_connect_failed" : connectError);
						return;
					}
					if (!attempt.finish()) {
						stream.close();
						return;
					}
					try
						complete(new RelaySocketLink(stream), null)
					catch (failure:Dynamic) {
						stream.close();
						throw failure;
					}
				});
				attempt.useSocket(socketAttempt);
			});
			attempt.useTicket(ticketAttempt);
		});
		attempt.useTicket(registrationAttempt);
		return attempt;
	}

	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		for (attempt in attempts.copy())
			attempt.cancel();
		tickets.dispose();
	}
}
