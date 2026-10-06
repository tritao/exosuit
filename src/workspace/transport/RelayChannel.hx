package workspace.transport;

import haxe.io.Bytes;
import haxeon.rpc.MessageTransport;

/** Bounded logical channel carried through one machine-to-relay WebSocket. */
class RelayChannel implements MessageTransport {
	public final channelId:String;
	public var failure(default, null):Null<String>;

	final link:RelaySocketLink;
	final maxQueuedBytes:Int;
	final maxMessages:Int;
	final incoming:Array<Bytes> = [];
	var queuedBytes:Int = 0;
	var terminal:Bool = false;

	@:allow(workspace.transport.RelaySocketLink)
	private function new(link:RelaySocketLink, channelId:String, maxQueuedBytes:Int, maxMessages:Int) {
		this.link = link;
		this.channelId = channelId;
		this.maxQueuedBytes = maxQueuedBytes;
		this.maxMessages = maxMessages;
	}

	public function isOpen():Bool
		return !terminal && link.isOpen();

	public function send(message:Bytes):Bool {
		if (!isOpen())
			return false;
		return link.send(channelId, message);
	}

	public function receive():Null<Bytes> {
		if (!terminal)
			link.poll();
		if (incoming.length == 0)
			return null;
		var value = incoming.shift();
		queuedBytes -= value.length;
		return value;
	}

	public function close():Void {
		if (terminal)
			return;
		terminal = true;
		failure = "closed";
		incoming.resize(0);
		queuedBytes = 0;
		link.forgetChannel(this, true);
	}

	@:allow(workspace.transport.RelaySocketLink)
	private function enqueue(message:Bytes):Bool {
		if (terminal)
			return false;
		if (message == null || incoming.length >= maxMessages || message.length > maxQueuedBytes - queuedBytes)
			return false;
		incoming.push(message);
		queuedBytes += message.length;
		return true;
	}

	@:allow(workspace.transport.RelaySocketLink)
	private function linkClosed(reason:String):Void {
		terminal = true;
		failure = reason;
		incoming.resize(0);
		queuedBytes = 0;
	}
}
