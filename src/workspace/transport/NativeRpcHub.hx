package workspace.transport;

import haxeon.rpc.RpcConnectAttempt;
import haxeon.rpc.RpcConnectResult;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import NativeKitEvents;
import NativeKitEvents.NativeKitEventSubscription;
import NativeKitEventValue;
import NativeKitEventBytes;

private class CompletedAttempt implements RpcConnectAttempt {
	public function new() {}

	public function cancel():Void {}
}

private class NativeAttempt implements RpcConnectAttempt {
	final transport:NativeRpcTransport;
	final remove:Void->Void;

	public var complete:Bool = false;

	public function new(transport:NativeRpcTransport, remove:Void->Void) {
		this.transport = transport;
		this.remove = remove;
	}

	public function cancel():Void {
		if (!complete) {
			complete = true;
			remove();
			transport.close();
		}
	}
}

private typedef Pending = {var attempt:NativeAttempt; var done:RpcConnectResult->Void;}

/** Observes the shared NativeKit event pump; never steals another subsystem's events. */
class NativeRpcHub {
	final streams:Map<Int, NativeRpcTransport> = [];
	final pending:Map<Int, Pending> = [];
	final listeners:Map<Int, {owned:OwnedListenerHandle, callback:NativeRpcTransport->Void}> = [];
	final subscription:NativeKitEventSubscription;
	var disposed:Bool = false;

	public function new(events:NativeKitEvents) {
		subscription = events.listen(onEvent);
	}

	public function connect(options:TransportOptions, done:RpcConnectResult->Void):RpcConnectAttempt {
		if (disposed || streamsCount() >= 32)
			throw "RPC transport hub unavailable";
		var opened = NativeKit.nk_transport_connect(options);
		if (opened.status != 0) {
			done(Failed({code: "connect_failed", message: "Connect failed", ambiguous: false}, true));
			return new CompletedAttempt();
		}
		var stream = new NativeRpcTransport(opened.out_transport),
			key = opened.out_transport.borrow().rawValue(),
			attempt = new NativeAttempt(stream, function() {
				streams.remove(key);
				pending.remove(key);
			});
		streams.set(key, stream);
		pending.set(key, {attempt: attempt, done: done});
		return attempt;
	}

	public function listen(options:TransportOptions, accepted:NativeRpcTransport->Void):OwnedListenerHandle {
		if (disposed || listenersCount() >= 4)
			throw "RPC listener limit";
		var listener = NativeKit.nk_transport_listen_checked(options);
		listeners.set(listener.borrow().rawValue(), {owned: listener, callback: accepted});
		return listener;
	}

	public function forget(listener:OwnedListenerHandle):Void {
		listeners.remove(listener.borrow().rawValue());
		listener.close();
	}

	function streamsCount():Int {
		var count = 0;
		for (_ in streams)
			count++;
		return count;
	}

	function listenersCount():Int {
		var count = 0;
		for (_ in listeners)
			count++;
		return count;
	}

	function onEvent(value:NativeKitEventValue):Void {
		switch value {
			case Raw(kind, source, _, result, _, _, data):
				var key = source.rawValue();
				if (kind == EventKind.TransportAccepted) {
					var payload:TransportAcceptedEvent = data;
					var handle = OwnedTransportHandle.adopt(payload.get_transport());
					var callback = listeners.get(key);
					if (callback == null || streamsCount() >= 32) {
						handle.close();
						return;
					}
					var stream = new NativeRpcTransport(handle);
					stream.connected = true;
					streams.set(handle.borrow().rawValue(), stream);
					try
						callback.callback(stream)
					catch (error:Dynamic) {
						stream.close();
						throw error;
					}
					return;
				}
				var stream = streams.get(key);
				if (stream == null)
					return;
				var connecting = pending.get(key);
				if (kind == EventKind.TransportConnected && !stream.terminal) {
					stream.connected = true;
					if (connecting != null && !connecting.attempt.complete) {
						pending.remove(key);
						connecting.attempt.complete = true;
						connecting.done(Opened(stream));
					}
				} else if (kind == EventKind.TransportFailed || kind == EventKind.TransportClosed) {
					pending.remove(key);
					if (connecting != null && !connecting.attempt.complete) {
						pending.remove(key);
						connecting.attempt.complete = true;
						stream.close();
						connecting.done(Failed({code: "connect_failed", message: "Connect failed", ambiguous: false}, true));
					} else
						stream.close();
					streams.remove(key);
				}
			default:
		}
	}

	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		subscription.dispose();
		var callbacks = [for (item in pending) item];
		pending.clear();
		for (stream in streams)
			stream.close();
		streams.clear();
		for (listener in listeners)
			listener.owned.close();
		listeners.clear();
		for (item in callbacks)
			if (!item.attempt.complete) {
				item.attempt.complete = true;
				item.done(Failed({code: "connector_closed", message: "Connector closed", ambiguous: false}, false));
			}
	}

	public static function local(path:String):TransportOptions {
		var options = new TransportOptions();
		options.set_kind(TransportKind.Local);
		options.set_path(path);
		options.set_receive_buffer_size(1048576);
		options.set_send_buffer_size(1048576);
		options.set_timeout_ms(5000);
		return options;
	}

	public static function websocket(port:Int, path:String = "/workspace", listener:Bool = false):TransportOptions {
		if (port < 1 || port > 65535)
			throw "Invalid WebSocket port";
		var options = new TransportOptions();
		options.set_kind(TransportKind.Websocket);
		options.set_flags(listener ? TransportFlags.ReuseAddress | TransportFlags.NoDelay : TransportFlags.NoDelay);
		options.set_host("127.0.0.1");
		options.set_port(port);
		options.set_path(path);
		options.set_subprotocols("exosuit.rpc.v1");
		options.set_receive_buffer_size(1048576);
		options.set_send_buffer_size(1048576);
		options.set_timeout_ms(5000);
		return options;
	}
}
