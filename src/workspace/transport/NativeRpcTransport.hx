package workspace.transport;

import haxe.io.Bytes;
import haxeon.rpc.MessageTransport;
import haxeon.wire.MessagePackFrame;
import haxeon.wire.MessagePackFrameReader;
import nativekit.ffi.NativeKitTypes;

/** NativeKit exposes byte streams on local sockets and browser/native WebSockets.
 * Receive storage is borrowed only during feed; take transfers an assembled payload.
 * Send framing and NativeKit's asynchronous send queue each copy bytes. */
class NativeRpcTransport implements MessageTransport {
	public final handle:OwnedTransportHandle;
	public var connected:Bool = false;
	public var terminal:Bool = false;
	public var failure:Null<String>;

	final maxMessageBytes:Int;
	final stream:NativeKitByteStream;
	var reader:Null<MessagePackFrameReader>;
	var input:Null<Bytes> = Bytes.alloc(16384);
	var offset:Int = 0;
	var length:Int = 0;

	public function new(stream:NativeKitByteStream, maxMessageBytes:Int = 262144) {
		this.stream = stream;
		this.handle = stream.handle;
		this.connected = stream.connected;
		this.maxMessageBytes = maxMessageBytes;
		reader = new MessagePackFrameReader(maxMessageBytes, maxMessageBytes, 1);
	}

	public function isOpen():Bool
		return connected && !terminal && stream.isOpen();

	public function send(message:Bytes):Bool {
		if (!isOpen())
			return false;
		if (message == null || message.length > maxMessageBytes)
			throw "RPC transport message limit";
		var bytes = MessagePackFrame.pack(message);
		var sent = stream.send(bytes);
		if (!sent && stream.failure != null) {
			failure = stream.failure;
			close();
		}
		return sent;
	}

	public function receive():Null<Bytes> {
		if (!isOpen())
			return null;
		var frames = reader, buffer = input;
		if (frames == null || buffer == null)
			return null;
		var ready = frames.take();
		if (ready != null)
			return ready;
		var budget = 32768;
		try {
			while (budget > 0) {
				if (offset == length) {
					var read = stream.receive(buffer);
					if (read == 0)
						return null;
					if (read < 0) {
						failure = stream.failure == null ? "disconnected" : stream.failure;
						close();
						return null;
					}
					length = read;
					offset = 0;
					if (length <= 0 || length > buffer.length) {
						failure = "invalid_transport_read";
						close();
						return null;
					}
				}
				var consumed = frames.feed(buffer, offset, length - offset, budget);
				offset += consumed;
				budget -= consumed;
				ready = frames.take();
				if (ready != null)
					return ready;
				if (consumed == 0)
					return null;
			}
		} catch (_:Dynamic) {
			failure = "invalid_frame";
			close();
		}
		return null;
	}

	public function close():Void {
		if (terminal)
			return;
		terminal = true;
		connected = false;
		reader = null;
		input = null;
		offset = 0;
		length = 0;
		stream.close();
	}
}
