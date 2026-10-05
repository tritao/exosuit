package app;

import haxe.io.Bytes;
import haxeon.rpc.RpcEnvelope;
import haxeon.rpc.RpcProtocol;
import haxeon.rpc.MemoryTransport;
import haxeon.wire.JsonWire;
import haxeon.wire.MessagePackFrame;
import haxeon.wire.MessagePackFrameReader;

class RpcTestMain {
	static function require(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}

	static function rejects(action:Void->Void, message:String):Void {
		var rejected = false;
		try
			action()
		catch (_:Dynamic)
			rejected = true;
		require(rejected, message);
	}

	static function main():Void {
		RpcLifecycleTests.run();
		RpcDispatchTests.run();
		var hello:RpcEnvelope = Hello(1, 1, "exosuit-test", ["workspace.read", "workspace.events"]);
		var encoded = RpcProtocol.encode(hello, 1024);
		var decoded = RpcProtocol.decode(encoded, 1024);
		switch decoded {
			case Hello(protocol, codec, application, capabilities):
				require(protocol == 1 && codec == 1 && application == "exosuit-test" && capabilities.length == 2, "hello round trip");
			default:
				throw "unexpected hello variant";
		}
		var diagnostic:RpcEnvelope = JsonWire.decode(JsonWire.encode(hello));
		require(RpcProtocol.encode(diagnostic, 1024).compare(encoded) == 0, "JSON and MessagePack schemas disagree");
		var request:RpcEnvelope = Request(1, 100, 10000, Bytes.ofString("workspace query"));
		switch RpcProtocol.decode(RpcProtocol.encode(request, 1024), 1024) {
			case Request(id, method, timeout, payload):
				require(id == 1 && method == 100 && timeout == 10000 && payload.toString() == "workspace query", "request round trip");
			default:
				throw "unexpected request";
		}
		rejects(function() RpcProtocol.encode(Request(0, 100, 1000, Bytes.alloc(0)), 1024), "zero request id accepted");
		rejects(function() RpcProtocol.encode(Hello(1, 1, "test", ["a", "a"]), 1024), "duplicate capabilities accepted");
		rejects(function() RpcProtocol.decode(encoded, 1), "oversized envelope accepted");
		var malformed = Bytes.alloc(1);
		malformed.set(0, 0xc1);
		rejects(function() RpcProtocol.decode(malformed, 1024), "malformed envelope accepted");

		var frame = MessagePackFrame.pack(encoded);
		var empty = MessagePackFrame.pack(Bytes.alloc(0));
		var emptyReader = new MessagePackFrameReader(0, 0, 1);
		require(emptyReader.feed(empty, 0, empty.length) == empty.length
			&& emptyReader.bufferedMessages() == 1, "empty frame lost at header boundary");
		var emptyPayload = emptyReader.take();
		require(emptyPayload != null && emptyPayload.length == 0, "empty payload changed");
		rejects(function() new MessagePackFrameReader(1, 0x7fffffff, 1), "header byte budget overflow accepted");
		for (split in 0...frame.length + 1) {
			var reader = new MessagePackFrameReader(1024, 2048, 2);
			require(reader.feed(frame, 0, split) == split, "first split progress");
			require(reader.feed(frame, split, frame.length - split) == frame.length - split, "second split progress");
			var message = reader.take();
			require(message != null && message.compare(encoded) == 0 && reader.bufferedBytes() == 0, "split frame mismatch");
		}
		var coalesced = Bytes.alloc(frame.length * 3);
		for (index in 0...3)
			coalesced.blit(index * frame.length, frame, 0, frame.length);
		var reader = new MessagePackFrameReader(1024, 2048, 2);
		var consumed = reader.feed(coalesced, 0, coalesced.length);
		require(consumed == frame.length * 2 && reader.bufferedMessages() == 2, "message budget failed");
		require(reader.feed(coalesced, consumed, coalesced.length - consumed) == 0, "full queue consumed bytes");
		reader.take();
		require(reader.feed(coalesced, consumed, coalesced.length - consumed) == frame.length, "queue failed to resume");
		var budgeted = new MessagePackFrameReader(1024, 2048, 2);
		require(budgeted.feed(frame, 0, frame.length, 3) == 3 && budgeted.bufferedMessages() == 0, "feed byte budget ignored");
		var oversized = frame.sub(0, 10);
		oversized.set(6, 255);
		oversized.set(7, 255);
		oversized.set(8, 255);
		oversized.set(9, 255);
		rejects(function() MessagePackFrame.unpack(oversized), "unsigned length overflow accepted");
		var poisoned = new MessagePackFrameReader(1024, 2048, 2);
		rejects(function() poisoned.feed(oversized, 0, 10), "oversized header accepted");
		require(poisoned.bufferedBytes() == 10, "oversized header allocated payload");
		rejects(function() poisoned.feed(frame, 0, frame.length), "failed stream continued parsing");
		var byteBound = new MessagePackFrameReader(encoded.length, encoded.length, 10);
		consumed = byteBound.feed(coalesced, 0, coalesced.length);
		require(consumed == frame.length + 10 && byteBound.bufferedBytes() == encoded.length + 10, "byte queue budget failed");
		byteBound.take();
		require(byteBound.feed(coalesced, consumed, coalesced.length - consumed) > 0, "byte budget failed to resume");

		var pair = MemoryTransport.pair(encoded.length, 1);
		require(pair.client.send(encoded), "memory send rejected");
		require(!pair.client.send(encoded) && pair.server.bufferedBytes() == encoded.length, "memory queue unbounded");
		require(pair.server.receive().compare(encoded) == 0, "memory message changed");
		pair.client.loseNext();
		require(pair.client.send(encoded) && pair.server.receive() == null, "accepted loss not simulated");
		pair.server.close();
		require(!pair.client.isOpen() && !pair.client.send(encoded), "closed peer accepted input");
		Sys.println("PASS: typed RPC envelopes, bounded incremental frames, owned message transport and injected loss");
	}
}
