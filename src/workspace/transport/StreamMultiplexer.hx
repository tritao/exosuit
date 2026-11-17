package workspace.transport;

import haxe.io.Bytes;
import haxeon.rpc.MessageTransport;
import workspace.service.MachineDirectoryProtocol.MachineStreamFrame;

/** One stream of a `StreamMultiplexer`: an ordinary message transport for one RPC connection. */
class MuxStream implements MessageTransport {
	public final id:Int;
	final owner:StreamMultiplexer;
	final inbox:Array<Bytes> = [];
	var inboxBytes = 0;
	@:allow(workspace.transport.StreamMultiplexer)
	var ended = false;

	@:allow(workspace.transport.StreamMultiplexer)
	function new(owner:StreamMultiplexer, id:Int) {
		this.owner = owner;
		this.id = id;
	}

	/** False once either side closed the stream or the channel ended. */
	public function isOpen():Bool
		return !ended && owner.isOpen();

	/**
		Queues one RPC message as a data frame. True means the multiplexer owns it now (it may still be waiting for the
		Noise channel, in order); false means it was not taken and the same message may be offered again. A message too
		large for a frame ends the stream, since it can never be sent.
	**/
	public function send(message:Bytes):Bool {
		if (!isOpen() || message == null)
			return false;
		if (message.length > MachineStreamFrame.MAX_PAYLOAD) {
			close();
			return false;
		}
		return owner.sendFrame(MachineStreamFrame.encode(MachineStreamFrame.DATA, id, message));
	}

	public function receive():Null<Bytes> {
		if (ended)
			return null;
		if (inbox.length == 0)
			owner.pump();
		if (ended || inbox.length == 0)
			return null;
		var message = inbox.shift() ?? throw "Inbox is empty";
		inboxBytes -= message.length;
		return message;
	}

	/** Ends the stream here and tells the peer. Stream 0 ends only with the channel, so closing it closes the channel. */
	public function close():Void {
		if (ended)
			return;
		if (id == MachineStreamFrame.MACHINE_STREAM) {
			owner.close();
			return;
		}
		owner.release(this, true);
	}

	@:allow(workspace.transport.StreamMultiplexer)
	function deliver(payload:Bytes):Bool {
		if (inbox.length >= StreamMultiplexer.INBOX_MESSAGES || inboxBytes + payload.length > StreamMultiplexer.INBOX_BYTES)
			return false;
		inbox.push(payload);
		inboxBytes += payload.length;
		return true;
	}

	@:allow(workspace.transport.StreamMultiplexer)
	function end():Void {
		ended = true;
		inbox.resize(0);
		inboxBytes = 0;
	}
}

/**
	Either end of the stream frames a paired Noise channel carries (`MachineStreamFrame`, ADR 0005 section 4): the
	device's, and exohost's (`MachineDeviceSession`). `machineStream()` is stream 0, always open; `open(id)` registers a
	stream the machine made for an OPEN. Each stream is a `MessageTransport` for an ordinary RPC connection, so the
	machine directory and every workspace connection run over one channel.

	Pumping is lazy: any stream's `receive`, or `poll`, reads up to PUMP_FRAMES frames from the channel and files each
	under its stream. A frame for a stream that is not open is dropped and answered with a close frame (once per id). A
	stream whose inbox overflows is closed (the protocol has no flow control, so a peer that floods it is broken). A
	malformed frame, or a close for stream 0, closes the channel. Outgoing frames keep their order: when the channel
	refuses one it waits in a bounded queue and `poll` retries it, so a Noise transport that wants the same message
	offered again sees exactly that.
**/
class StreamMultiplexer {
	/** Frames read from the channel per pump. */
	public static inline final PUMP_FRAMES = 64;
	public static inline final INBOX_MESSAGES = 512;
	public static inline final INBOX_BYTES = 4 * 1024 * 1024;
	/** Outgoing frames held while the channel is busy. */
	public static inline final OUTBOX_FRAMES = 64;
	/** Streams a device may hold, the machine stream included (`MachineDirectoryProtocol.STREAM_LIMIT`). */
	public static inline final STREAMS = 16;

	final secure:MessageTransport;
	final streams:Map<Int, MuxStream> = [];
	final outbox:Array<Bytes> = [];
	/** Ids that were open here and ended: late data for them is dropped without a second close frame. */
	final ended:Map<Int, Bool> = [];
	var machine:MuxStream;
	var closed = false;
	var pumping = false;

	public function new(secure:MessageTransport) {
		if (secure == null || !secure.isOpen())
			throw "A stream multiplexer needs an open channel";
		this.secure = secure;
		machine = new MuxStream(this, MachineStreamFrame.MACHINE_STREAM);
		streams.set(MachineStreamFrame.MACHINE_STREAM, machine);
	}

	public function isOpen():Bool
		return !closed && secure.isOpen();

	public function machineStream():MuxStream
		return machine;

	/** Streams open now, the machine stream included. */
	public function count():Int {
		var total = 0;
		for (stream in streams)
			if (!stream.ended)
				total++;
		return total;
	}

	/** Registers the stream the machine made; null when the id is stream 0 or already used, the channel is closed, or the device is at its limit. */
	public function open(id:Int):Null<MuxStream> {
		if (!isOpen() || id <= MachineStreamFrame.MACHINE_STREAM || streams.exists(id) || ended.exists(id) || count() >= STREAMS)
			return null;
		var stream = new MuxStream(this, id);
		streams.set(id, stream);
		return stream;
	}

	/** Moves frames both ways: retries a refused outgoing frame, then reads what arrived. */
	public function poll():Void {
		flush();
		pump();
	}

	@:allow(workspace.transport.MuxStream)
	function sendFrame(frame:Bytes):Bool {
		if (!isOpen())
			return false;
		if (outbox.length == 0) {
			if (secure.send(frame))
				return true;
			if (!secure.isOpen()) {
				close();
				return false;
			}
			// The Noise transport keeps what it was given until it takes it, so this frame is the next one it must see.
		}
		if (outbox.length >= OUTBOX_FRAMES)
			return false;
		outbox.push(frame);
		return true;
	}

	function flush():Void {
		while (outbox.length > 0 && isOpen()) {
			if (!secure.send(outbox[0])) {
				if (!secure.isOpen())
					close();
				return;
			}
			outbox.shift();
		}
	}

	@:allow(workspace.transport.MuxStream)
	function release(stream:MuxStream, tell:Bool):Void {
		if (stream.ended)
			return;
		stream.end();
		streams.remove(stream.id);
		ended.set(stream.id, true);
		if (tell && isOpen())
			sendFrame(MachineStreamFrame.encode(MachineStreamFrame.CLOSE, stream.id, null));
	}

	@:allow(workspace.transport.MuxStream)
	function pump():Void {
		if (pumping || !isOpen())
			return;
		pumping = true;
		flush();
		for (_ in 0...PUMP_FRAMES) {
			if (!isOpen())
				break;
			var frame = secure.receive();
			if (frame == null)
				break;
			var kind = MachineStreamFrame.kind(frame);
			if (kind < 0) {
				close();
				break;
			}
			var id = MachineStreamFrame.stream(frame);
			var target = streams.get(id);
			if (target == null) {
				// Data for a stream we do not hold: say so once, then ignore it. A close needs no answer.
				if (kind == MachineStreamFrame.DATA && !ended.exists(id)) {
					if (Lambda.count(ended) < 4096)
						ended.set(id, true);
					sendFrame(MachineStreamFrame.encode(MachineStreamFrame.CLOSE, id, null));
				}
				continue;
			}
			if (kind == MachineStreamFrame.CLOSE) {
				if (id == MachineStreamFrame.MACHINE_STREAM) {
					close();
					break;
				}
				release(target, false);
			} else if (!target.deliver(MachineStreamFrame.payload(frame)))
				release(target, true);
		}
		pumping = false;
	}

	/** Ends every stream and the channel. */
	public function close():Void {
		if (closed)
			return;
		closed = true;
		for (stream in streams)
			stream.end();
		streams.clear();
		outbox.resize(0);
		secure.close();
	}
}
