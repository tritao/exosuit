package workspace.transport;

import haxe.io.Bytes;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes.Result;
import nativekit.ffi.NativeKitTypes.TransportError;
import nativekit.ffi.NativeKitTypes;

/** Owned NativeKit byte stream shared by framed local RPC and relay framing. */
class NativeKitByteStream {
	public final handle:OwnedTransportHandle;
	public var connected:Bool = false;
	public var terminal:Bool = false;
	public var failure:Null<String>;

	public function new(handle:OwnedTransportHandle) {
		this.handle = handle;
	}

	public function isOpen():Bool
		return connected && !terminal;

	/** Sends one copied buffer. NativeKit reports bounded-queue pressure as false. */
	public function send(bytes:Bytes):Bool {
		if (!isOpen())
			return false;
		if (bytes == null)
			throw "Transport bytes cannot be null";
		var result = NativeKit.nk_transport_send(handle.borrow(), bytes);
		if (result == Result.ErrorQueueFull)
			return false;
		if (result != 0) {
			failure = "transport_failed";
			close();
			return false;
		}
		return true;
	}

	/** Reads currently available stream bytes into caller-owned storage. */
	public function receive(buffer:Bytes):Int {
		if (!isOpen())
			return -1;
		if (buffer == null || buffer.length == 0)
			throw "Transport receive buffer must be nonempty";
		var read = NativeKit.nk_transport_receive(handle.borrow(), buffer);
		if (read.status == TransportError.WouldBlock)
			return 0;
		if (read.status != 0) {
			failure = "disconnected";
			close();
			return -1;
		}
		var count = haxe.Int64.toInt(read.out_received);
		if (count <= 0 || count > buffer.length) {
			failure = "invalid_transport_read";
			close();
			return -1;
		}
		return count;
	}

	@:allow(workspace.transport.NativeRpcHub)
	private function markConnected():Void
		connected = true;

	public function close():Void {
		if (terminal)
			return;
		terminal = true;
		connected = false;
		handle.close();
	}
}
