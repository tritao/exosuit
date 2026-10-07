package workspace.transport;

import haxe.io.Bytes;
import haxeon.rpc.MessageTransport;

/** Browser/device side of a Worker route: frames one channel over its WebSocket. */
class RelayDeviceTransport implements MessageTransport {
	public static inline final MAX_MESSAGE_BYTES:Int = RelaySocketLink.MAX_MESSAGE_BYTES;
	public var failure(default, null):Null<String>;

	final stream:NativeKitByteStream;
	final channelId:String;
	final reader = new RelayFrameReader(MAX_MESSAGE_BYTES, 1048576, 32);
	var input:Null<Bytes> = Bytes.alloc(16384);
	var offset:Int = 0;
	var length:Int = 0;
	var terminal:Bool = false;

	public function new(stream:NativeKitByteStream, channelId:String) {
		if (stream == null || !stream.isOpen()) throw "Relay device socket must be connected";
		RelayFrameCodec.decodeChannelId(channelId);
		this.stream = stream;
		this.channelId = channelId;
	}

	public function isOpen():Bool return !terminal && stream.isOpen();

	public function send(message:Bytes):Bool {
		if (!isOpen()) return false;
		if (message == null || message.length > MAX_MESSAGE_BYTES) {
			fail("relay_message_too_large");
			return false;
		}
		try return stream.send(RelayFrameCodec.encode(channelId, message, MAX_MESSAGE_BYTES))
		catch (_:Dynamic) {
			fail("relay_send_failed");
			return false;
		}
	}

	public function receive():Null<Bytes> {
		if (!isOpen()) return null;
		try {
			var frame = reader.take();
			if (frame != null) return takeFrame(frame);
			var buffer = input;
			if (buffer == null) return null;
			var budget = 32768;
			while (budget > 0) {
				if (offset == length) {
					var read = stream.receive(buffer);
					if (read == 0) return null;
					if (read < 0) {
						fail(stream.failure == null ? "relay_disconnected" : stream.failure);
						return null;
					}
					length = read;
					offset = 0;
				}
				var consumed = reader.feed(buffer, offset, length - offset, budget);
				offset += consumed;
				budget -= consumed;
				frame = reader.take();
				if (frame != null) return takeFrame(frame);
				if (consumed == 0) return null;
			}
		} catch (_:Dynamic) {
			fail("invalid_relay_frame");
		}
		return null;
	}

	function takeFrame(frame:RelayFrame):Null<Bytes> {
		if (frame.reset) {
			fail("unexpected_relay_control");
			return null;
		}
		if (frame.channelId != channelId) {
			fail("relay_channel_mismatch");
			return null;
		}
		return frame.payload;
	}

	public function close():Void fail("closed");

	function fail(reason:String):Void {
		if (terminal) return;
		terminal = true;
		failure = reason;
		input = null;
		offset = length = 0;
		stream.close();
	}
}
