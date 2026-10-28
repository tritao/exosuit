package suit.relay;

import haxe.io.Bytes;
import haxeon.rpc.MessageTransport;
import workspace.transport.RelayByteStream;

/**
	The daemon's end of its relay link to suit, read as the byte stream a `RelaySocketLink` expects: the
	relay envelopes suit forwards, concatenated. suit's status messages are taken out on the way.
**/
class SuitRelayStream implements RelayByteStream {
	/** Whether suit's machine socket is up; the link can be open while suit reconnects to the relay. */
	public var relayConnected(default, null):Bool = false;

	public var relayError(default, null):Null<String> = "relay_connecting";

	final transport:MessageTransport;
	var current:Null<Bytes> = null;
	var offset:Int = 0;
	var failure:Null<String> = null;

	public function new(transport:MessageTransport) {
		this.transport = transport;
	}

	public function isOpen():Bool
		return failure == null && transport.isOpen();

	public function send(bytes:Bytes):Bool {
		if (!isOpen())
			return false;
		var sent = transport.send(bytes);
		if (!sent && !transport.isOpen())
			fail("suit_disconnected");
		return sent;
	}

	public function receive(buffer:Bytes):Int {
		if (!isOpen()) {
			if (failure == null)
				fail("suit_disconnected");
			return -1;
		}
		var written = 0;
		while (written < buffer.length) {
			var source = current;
			if (source == null) {
				var message = transport.receive();
				if (message == null)
					break;
				if (message.length == 0)
					continue;
				var kind = message.get(0);
				if (kind == SuitRelayProtocol.STATUS_KIND) {
					var status:Null<SuitRelayLinkStatus> = null;
					try status = SuitRelayProtocol.parseStatus(message) catch (_:Dynamic) {}
					if (status == null) {
						fail("invalid_suit_status");
						return -1;
					}
					relayConnected = status.connected;
					relayError = status.error;
					continue;
				}
				if (kind != 1 && kind != 2) {
					fail("invalid_suit_frame");
					return -1;
				}
				current = message;
				source = message;
				offset = 0;
			}
			var count = Std.int(Math.min(source.length - offset, buffer.length - written));
			buffer.blit(written, source, offset, count);
			offset += count;
			written += count;
			if (offset == source.length)
				current = null;
		}
		if (written == 0 && !transport.isOpen()) {
			fail("suit_disconnected");
			return -1;
		}
		return written;
	}

	public function failureReason():Null<String>
		return failure;

	function fail(reason:String):Void {
		if (failure == null)
			failure = reason;
		relayConnected = false;
		transport.close();
	}

	public function close():Void
		fail("closed");
}
