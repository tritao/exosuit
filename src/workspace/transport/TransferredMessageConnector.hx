package workspace.transport;

import haxeon.rpc.MessageTransport;
import haxeon.rpc.RpcConnectAttempt;
import haxeon.rpc.RpcConnectResult;
import haxeon.rpc.RpcConnector;

private class FinishedAttempt implements RpcConnectAttempt {
	public function new() {}
	public function cancel():Void {}
}

/** Transfers an already Noise-authenticated transport into the first RPC handshake. */
class TransferredMessageConnector implements RpcConnector {
	var transport:Null<MessageTransport>;
	var used:Bool = false;

	public function new(transport:MessageTransport) {
		if (transport == null || !transport.isOpen()) throw "Authenticated transport must be open";
		this.transport = transport;
	}

	public function connect(complete:RpcConnectResult->Void):RpcConnectAttempt {
		if (used || transport == null) {
			complete(Failed({code: "transport_unavailable", message: "Authenticated transport is unavailable", ambiguous: false}, false));
			return new FinishedAttempt();
		}
		used = true;
		var current = transport;
		transport = null;
		complete(Opened(current));
		return new FinishedAttempt();
	}

	public function dispose():Void {
		var current = transport;
		transport = null;
		if (current != null) current.close();
	}
}
