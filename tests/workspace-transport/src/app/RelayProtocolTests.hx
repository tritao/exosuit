package app;

import haxe.io.Bytes;
import workspace.transport.RelayFrame;
import workspace.transport.RelayFrameCodec;
import workspace.transport.RelayFrameReader;
import workspace.transport.RelayMachineEndpoint;
import workspace.transport.NativeRpcHub;
import workspace.transport.RelaySocketLink;
import workspace.transport.RelaySocketTicket;

class RelayProtocolTests {
	static function require(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}

	public static function run():Void {
		require(RelaySocketLink.MAX_MESSAGE_BYTES == 65509,
			"relay message cap does not match the Worker's 64 KiB frame limit");
		var firstId = "00112233445566778899aabbccddeeff";
		var secondId = "ffeeddccbbaa99887766554433221100";
		var firstText = Bytes.ofString("firstopaque");
		var firstPayload = Bytes.alloc(firstText.length + 1);
		firstPayload.blit(0, firstText, 0, 5);
		firstPayload.set(5, 0);
		firstPayload.blit(6, firstText, 5, firstText.length - 5);
		var secondPayload = Bytes.alloc(5);
		secondPayload.set(0, 0xff);
		secondPayload.set(1, 0);
		secondPayload.set(2, 0x80);
		secondPayload.set(3, 42);
		secondPayload.set(4, 0x7e);

		var reader = new RelayFrameReader(128, 256, 4);
		var firstPacket = RelayFrameCodec.encode(firstId, firstPayload, 128);
		var secondPacket = RelayFrameCodec.encode(secondId, secondPayload, 128);
		for (index in 0...firstPacket.length) {
			var consumed = reader.feed(firstPacket, index, 1);
			require(consumed == 1, "split relay packet stalled");
		}
		var first = reader.take();
		require(first != null && first.channelId == firstId && same(first.payload, firstPayload),
			"split relay packet changed route or binary payload");

		var combined = Bytes.alloc(firstPacket.length + secondPacket.length);
		combined.blit(0, firstPacket, 0, firstPacket.length);
		combined.blit(firstPacket.length, secondPacket, 0, secondPacket.length);
		require(reader.feed(combined, 0, combined.length) == combined.length, "coalesced relay packets stalled");
		var replayFirst = reader.take();
		var replaySecond = reader.take();
		require(replayFirst != null && replaySecond != null && replayFirst.channelId == firstId &&
			replaySecond.channelId == secondId && same(replayFirst.payload, firstPayload) &&
			same(replaySecond.payload, secondPayload), "coalesced relay packets lost order or bytes");

		var bounded = new RelayFrameReader(8, 8, 1);
		var tinyA = RelayFrameCodec.encode(firstId, Bytes.ofString("a"), 8);
		var tinyB = RelayFrameCodec.encode(secondId, Bytes.ofString("b"), 8);
		var pair = Bytes.alloc(tinyA.length + tinyB.length);
		pair.blit(0, tinyA, 0, tinyA.length);
		pair.blit(tinyA.length, tinyB, 0, tinyB.length);
		var used = bounded.feed(pair, 0, pair.length);
		require(used == tinyA.length, "relay reader exceeded its message-count bound");
		var boundedFirst = bounded.take();
		require(boundedFirst != null && boundedFirst.payload.toString() == "a", "bounded relay queue returned the wrong frame");
		require(bounded.feed(pair, used, pair.length - used) == tinyB.length, "relay reader failed after backpressure");
		var boundedSecond = bounded.take();
		require(boundedSecond != null && boundedSecond.payload.toString() == "b", "relay reader lost data after backpressure");

		var ticket = RelaySocketTicket.parse(Bytes.ofString('{"ticket":"${repeat("a", 64)}","expiresInSeconds":60}'));
		require(ticket.value == repeat("a", 64) && ticket.expiresInSeconds == 60, "relay ticket parse failed");
		var endpoint = new RelayMachineEndpoint("http://127.0.0.1:8787", firstId);
		require(endpoint.websocketUrl(ticket) == "ws://127.0.0.1:8787/v1/machines/" + firstId + "/connect?ticket=" + ticket.value,
			"loopback relay endpoint did not construct its socket URL");
		var secureEndpoint = new RelayMachineEndpoint("https://relay.example", firstId),
			secureUrl = secureEndpoint.websocketUrl(ticket),
			secureOptions = NativeRpcHub.websocketUrl(secureUrl);
		require(secureOptions.get_port() == 443 && secureOptions.get_host() == "relay.example" &&
			secureOptions.get_path() == "/v1/machines/" + firstId + "/connect?ticket=" + ticket.value,
			"default WSS port or relay URL components were not parsed correctly");
		reject(function() { RelayFrameCodec.decodeChannelId("00112233445566778899AABBCCDDEEFF"); }, "uppercase route id accepted");
		reject(function() { new RelayMachineEndpoint("http://relay.example", firstId); }, "insecure non-loopback relay accepted");
		reject(function() { new RelayMachineEndpoint("https://relay.example:0", firstId); }, "zero relay port accepted");
		reject(function() { RelaySocketTicket.parse(Bytes.ofString('{"ticket":"short","expiresInSeconds":60}')); },
			"malformed relay ticket accepted");
		Sys.println("PASS: relay framing handles split/coalesced binary packets, route separation, bounds and ticket validation");
	}

	static function same(left:Bytes, right:Bytes):Bool {
		if (left == null || right == null || left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (left.get(index) != right.get(index))
				return false;
		return true;
	}

	static function repeat(value:String, count:Int):String {
		var result = new StringBuf();
		for (_ in 0...count) result.add(value);
		return result.toString();
	}

	static function reject(action:Void->Void, message:String):Void {
		var failed = false;
		try action() catch (_:Dynamic) failed = true;
		require(failed, message);
	}
}
