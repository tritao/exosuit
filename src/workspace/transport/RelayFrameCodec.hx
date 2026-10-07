package workspace.transport;

import haxe.io.Bytes;
import haxeon.wire.MessagePackFrame;

/** Bounded codec for the Worker envelope: version byte, 16-byte route, HMPK frame. */
class RelayFrameCodec {
	public static inline final ROUTE_BYTES:Int = 16;
	public static inline final ENVELOPE_BYTES:Int = 1 + ROUTE_BYTES;
	public static inline final VERSION:Int = 1;
	public static inline final RESET_VERSION:Int = 2;

	public static function encode(channelId:String, payload:Bytes, maxMessageBytes:Int = 262144):Bytes {
		var route = decodeChannelId(channelId);
		if (payload == null || payload.length > maxMessageBytes)
			throw "Relay message limit";
		var frame = MessagePackFrame.pack(payload);
		var packet = Bytes.alloc(ENVELOPE_BYTES + frame.length);
		packet.set(0, VERSION);
		packet.blit(1, route, 0, route.length);
		packet.blit(ENVELOPE_BYTES, frame, 0, frame.length);
		return packet;
	}

	/** Control envelope used by the Worker to invalidate a device's old socket route. */
	public static function encodeReset(channelId:String):Bytes {
		var route = decodeChannelId(channelId);
		var packet = Bytes.alloc(ENVELOPE_BYTES);
		packet.set(0, RESET_VERSION);
		packet.blit(1, route, 0, route.length);
		return packet;
	}

	public static function decodeChannelId(value:String):Bytes {
		if (value == null || value.length != ROUTE_BYTES * 2)
			throw "Relay channel id must be 32 lowercase hex digits";
		var bytes = Bytes.alloc(ROUTE_BYTES);
		for (index in 0...ROUTE_BYTES) {
			var high = hex(value.charCodeAt(index * 2));
			var low = hex(value.charCodeAt(index * 2 + 1));
			if (high < 0 || low < 0)
				throw "Relay channel id must be 32 lowercase hex digits";
			bytes.set(index, high * 16 + low);
		}
		return bytes;
	}

	public static function encodeChannelId(bytes:Bytes):String {
		if (bytes == null || bytes.length != ROUTE_BYTES)
			throw "Relay route must contain 16 bytes";
		var out = new StringBuf();
		for (index in 0...bytes.length) {
			var value = bytes.get(index);
			out.addChar("0123456789abcdef".charCodeAt(value >>> 4));
			out.addChar("0123456789abcdef".charCodeAt(value & 0xf));
		}
		return out.toString();
	}

	static function hex(value:Int):Int {
		if (value >= 48 && value <= 57) return value - 48;
		if (value >= 97 && value <= 102) return value - 87;
		return -1;
	}
}
