package suit;

import haxe.Json;
import haxe.io.Bytes;
import haxeon.platform.Runtime;
import haxeon.rpc.RpcConnectResult;
import workspace.transport.NativeRpcHub;
import workspace.transport.NativeRpcTransport;

/** One request/response exchange with a running daemon over its local endpoint. */
class SuitControl {
	/** Returns the daemon's reply, or null when no daemon answers within `timeoutSeconds`. */
	public static function request(message:Dynamic, timeoutSeconds:Float = 3):Null<Dynamic> {
		var runtime = Runtime.start();
		var hub = new NativeRpcHub(runtime.events);
		var transport:Null<NativeRpcTransport> = null;
		var failed = false;
		var reply:Null<Dynamic> = null;
		try {
			hub.connect(NativeRpcHub.local(SuitPaths.endpoint()), function(result:RpcConnectResult) {
				switch result {
					case Opened(opened):
						transport = cast opened;
					default:
						failed = true;
				}
			});
			var sent = false;
			var deadline = Sys.time() + timeoutSeconds;
			while (!failed && Sys.time() < deadline) {
				runtime.events.wait(0.05);
				for (_ in 0...64)
					if (!runtime.events.poll())
						break;
				var current = transport;
				if (current == null)
					continue;
				if (!current.isOpen())
					break;
				if (!sent)
					sent = current.send(Bytes.ofString(Json.stringify(message)));
				var received = current.receive();
				if (received != null) {
					reply = Json.parse(received.toString());
					break;
				}
			}
		} catch (_:Dynamic) {
			reply = null;
		}
		if (transport != null)
			transport.close();
		hub.dispose();
		runtime.dispose();
		return reply;
	}
}
