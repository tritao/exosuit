package workspace.transport;

import haxe.io.Bytes;

/**
	The byte stream under a `RelaySocketLink`: a relay WebSocket (`NativeKitByteStream`), or a test's in-memory stand-in.
**/
interface RelayByteStream {
	function isOpen():Bool;

	/** Sends one complete relay envelope; false on queue pressure or a closed stream. */
	function send(bytes:Bytes):Bool;

	/** Copies available bytes into `buffer`: the count, 0 when none are ready, -1 once closed. */
	function receive(buffer:Bytes):Int;

	/** Why the stream closed, when it did. */
	function failureReason():Null<String>;

	function close():Void;
}
