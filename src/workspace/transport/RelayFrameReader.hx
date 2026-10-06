package workspace.transport;

import haxe.io.Bytes;
import haxeon.wire.MessagePackFrame;

/** Incrementally decodes routed HMPK messages without assuming socket read boundaries. */
class RelayFrameReader {
	final maxMessageBytes:Int;
	final maxQueuedBytes:Int;
	final maxMessages:Int;
	final routeHeader:Bytes = Bytes.alloc(RelayFrameCodec.ENVELOPE_BYTES);
	final frameHeader:Bytes = Bytes.alloc(MessagePackFrame.HEADER_BYTES);
	final queued:Array<RelayFrame> = [];
	var routeUsed:Int = 0;
	var headerUsed:Int = 0;
	var payload:Null<Bytes>;
	var payloadUsed:Int = 0;
	var channelId:Null<String>;
	var queuedBytes:Int = 0;
	var failed:Bool = false;

	public function new(maxMessageBytes:Int = 262144, maxQueuedBytes:Int = 1048576, maxMessages:Int = 32) {
		if (maxMessageBytes < 0 || maxQueuedBytes < maxMessageBytes || maxMessages < 1)
			throw "Invalid relay frame reader limits";
		this.maxMessageBytes = maxMessageBytes;
		this.maxQueuedBytes = maxQueuedBytes;
		this.maxMessages = maxMessages;
	}

	public function feed(bytes:Bytes, offset:Int, length:Int, budget:Int = 32768):Int {
		if (failed)
			throw "Relay frame reader failed; start a fresh connection";
		if (bytes == null || offset < 0 || length < 0 || offset > bytes.length || length > bytes.length - offset || budget < 0)
			throw "Invalid relay frame input range";
		var limit = Std.int(Math.min(length, budget));
		var consumed = 0;
		while (consumed < limit) {
			if (queued.length >= maxMessages)
				break;
			if (channelId == null) {
				var count = Std.int(Math.min(routeHeader.length - routeUsed, limit - consumed));
				routeHeader.blit(routeUsed, bytes, offset + consumed, count);
				routeUsed += count;
				consumed += count;
				if (routeUsed < routeHeader.length)
					break;
				if (routeHeader.get(0) != RelayFrameCodec.VERSION) {
					failed = true;
					throw "Unsupported relay envelope version";
				}
				var route = Bytes.alloc(RelayFrameCodec.ROUTE_BYTES);
				route.blit(0, routeHeader, 1, route.length);
				channelId = RelayFrameCodec.encodeChannelId(route);
				routeUsed = 0;
			}
			if (headerUsed < frameHeader.length) {
				var count = Std.int(Math.min(frameHeader.length - headerUsed, limit - consumed));
				frameHeader.blit(headerUsed, bytes, offset + consumed, count);
				headerUsed += count;
				consumed += count;
				if (headerUsed < frameHeader.length)
					break;
				var size:Int;
				try
					size = MessagePackFrame.payloadLength(frameHeader, maxMessageBytes)
				catch (error:Dynamic) {
					failed = true;
					throw error;
				}
				if (size > maxQueuedBytes - queuedBytes) {
					failed = true;
					throw "Relay receive queue limit";
				}
				queuedBytes += size;
				payload = Bytes.alloc(size);
				payloadUsed = 0;
				if (size == 0)
					completeFrame();
			}
			var current = payload;
			if (current != null) {
				var count = Std.int(Math.min(current.length - payloadUsed, limit - consumed));
				current.blit(payloadUsed, bytes, offset + consumed, count);
				payloadUsed += count;
				consumed += count;
				if (payloadUsed == current.length)
					completeFrame();
			}
		}
		return consumed;
	}

	public function take():Null<RelayFrame> {
		if (queued.length == 0)
			return null;
		var value = queued.shift();
		queuedBytes -= value.payload.length;
		return value;
	}

	function completeFrame():Void {
		var route = channelId, body = payload;
		if (route == null || body == null) {
			failed = true;
			throw "Invalid relay frame state";
		}
		queued.push(new RelayFrame(route, body));
		channelId = null;
		payload = null;
		payloadUsed = 0;
		headerUsed = 0;
	}
}
