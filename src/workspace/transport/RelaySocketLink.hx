package workspace.transport;

import haxe.io.Bytes;

/**
	Owns the machine-side Worker socket and demultiplexes opaque device channels.
	Each logical channel is a MessageTransport; callers layer Noise before RPC.
*/
class RelaySocketLink {
	public static inline final MAX_WORKER_FRAME_BYTES:Int = 64 * 1024;
	public static inline final MAX_MESSAGE_BYTES:Int = MAX_WORKER_FRAME_BYTES - RelayFrameCodec.ENVELOPE_BYTES - haxeon.wire.MessagePackFrame.HEADER_BYTES;
	public static inline final MAX_CHANNELS:Int = 8;
	public static inline final MAX_CHANNEL_QUEUE_BYTES:Int = 1048576;
	public static inline final MAX_CHANNEL_QUEUE_MESSAGES:Int = 32;

	public var onChannel:Null<RelayChannel->Void>;
	public var failure(default, null):Null<String>;

	final stream:NativeKitByteStream;
	final reader = new RelayFrameReader(MAX_MESSAGE_BYTES, 1048576, 32);
	final channels:Map<String, RelayChannel> = [];
	final rejected:Map<String, Bool> = [];
	var input:Null<Bytes> = Bytes.alloc(16384);
	var offset:Int = 0;
	var length:Int = 0;
	var terminal:Bool = false;
	var polling:Bool = false;

	public function new(stream:NativeKitByteStream) {
		if (stream == null || !stream.isOpen())
			throw "Relay socket must be connected";
		this.stream = stream;
	}

	public function isOpen():Bool
		return !terminal && stream.isOpen();

	/** Creates a channel for an already known, approved device route. */
	public function openChannel(channelId:String):RelayChannel {
		RelayFrameCodec.decodeChannelId(channelId);
		if (!isOpen() || rejected.exists(channelId))
			throw "Relay channel unavailable";
		var existing = channels.get(channelId);
		if (existing != null)
			return existing;
		if (channelCount() >= MAX_CHANNELS)
			throw "Relay channel limit";
		var channel = new RelayChannel(this, channelId, MAX_CHANNEL_QUEUE_BYTES, MAX_CHANNEL_QUEUE_MESSAGES);
		channels.set(channelId, channel);
		return channel;
	}

	/** Pumps socket bytes and dispatches any newly received device channels. */
	public function poll():Void {
		if (polling || !isOpen())
			return;
		polling = true;
		try {
			pump();
		} catch (_:Dynamic) {
			fail("invalid_relay_frame");
		}
		polling = false;
	}

	function pump():Void {
		var buffer = input;
		if (buffer == null)
			return;
		var budget = 32768;
		while (budget > 0) {
			if (offset == length) {
				var read = stream.receive(buffer);
				if (read == 0)
					return;
				if (read < 0) {
					fail(stream.failure == null ? "relay_disconnected" : stream.failure);
					return;
				}
			length = read;
			offset = 0;
			}
			var consumed = reader.feed(buffer, offset, length - offset, budget);
			offset += consumed;
			budget -= consumed;
			dispatchFrames();
			if (!isOpen())
				return;
			if (consumed == 0)
				return;
		}
	}

	function dispatchFrames():Void {
		var frame = reader.take();
		while (frame != null) {
			var current = frame;
			if (!rejected.exists(current.channelId)) {
				var channel = channels.get(current.channelId);
				var newChannel = false;
				if (channel == null) {
					if (channelCount() >= MAX_CHANNELS) {
						fail("relay_channel_limit");
						return;
					}
					channel = new RelayChannel(this, current.channelId, MAX_CHANNEL_QUEUE_BYTES, MAX_CHANNEL_QUEUE_MESSAGES);
					channels.set(current.channelId, channel);
					newChannel = true;
				}
				if (!channel.enqueue(current.payload)) {
					fail("relay_slow_consumer");
					return;
				}
				var callback = onChannel;
				if (callback != null && newChannel)
					callback(channel);
			}
			frame = reader.take();
		}
	}

	public function send(channelId:String, message:Bytes):Bool {
		if (!isOpen())
			return false;
		if (!channels.exists(channelId) || rejected.exists(channelId))
			return false;
		var packet = RelayFrameCodec.encode(channelId, message, MAX_MESSAGE_BYTES);
		var sent = stream.send(packet);
		if (!sent && stream.failure != null)
			fail(stream.failure);
		return sent;
	}

	@:allow(workspace.transport.RelayChannel)
	private function forgetChannel(channel:RelayChannel, reject:Bool):Void {
		channels.remove(channel.channelId);
		if (reject) {
			if (rejectedCount() >= 128) {
				fail("relay_channel_limit");
				return;
			}
			rejected.set(channel.channelId, true);
		}
	}

	function channelCount():Int {
		var count = 0;
		for (_ in channels)
			count++;
		return count;
	}

	function rejectedCount():Int {
		var count = 0;
		for (_ in rejected)
			count++;
		return count;
	}

	function fail(reason:String):Void {
		if (terminal)
			return;
		terminal = true;
		failure = reason;
		stream.close();
		input = null;
		offset = length = 0;
		for (channel in channels)
			channel.linkClosed(reason);
		channels.clear();
	}

	public function close():Void
		fail("closed");
}
