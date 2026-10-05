package workspace.transport;

import haxeon.rpc.RpcConnector;
import haxeon.rpc.RpcConnectAttempt;
import haxeon.rpc.RpcConnectResult;
import nativekit.ffi.NativeKitTypes;

/** Local same-user transport. WebSocket authentication is a separate preflight. */
class NativeRpcConnector implements RpcConnector {
	final hub:NativeRpcHub;
	final options:TransportOptions;

	public function new(hub:NativeRpcHub, options:TransportOptions) {
		this.hub = hub;
		this.options = options;
	}

	public function connect(done:RpcConnectResult->Void):RpcConnectAttempt
		return hub.connect(options, done);
}
