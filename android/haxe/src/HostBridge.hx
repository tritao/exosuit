import haxe.io.Bytes;

/**
	The channel between the Haxe module and the Android host (Kotlin) for things only the host can do. The host calls
	`UiBridge.commandJSON` to deliver and `UiBridge.takeHostRequest` to collect; both run on the Activity's UI thread.

	A request is one frame: kind, request id, payload bytes. The host answers with a `hostResult` command carrying the
	request id. Today the one kind is credential storage (KIND_SAVE_CREDENTIALS): the payload is the whole credential
	document, which the host encrypts under a key that never leaves the Android Keystore.
**/
class HostBridge {
	public static inline final KIND_SAVE_CREDENTIALS = 1;

	static var next = 1;
	static final queue:Array<Bytes> = [];
	static final waiting:Map<Int, Bool->Void> = [];

	/** Asks the host to do `kind` with `payload`; `done` runs with the host's answer, on the UI thread. */
	public static function request(kind:Int, payload:Bytes, done:Bool->Void):Void {
		var id = next++;
		var frame = Bytes.alloc(5 + payload.length);
		frame.set(0, kind);
		frame.set(1, id >>> 24);
		frame.set(2, id >>> 16);
		frame.set(3, id >>> 8);
		frame.set(4, id);
		frame.blit(5, payload, 0, payload.length);
		waiting.set(id, done);
		queue.push(frame);
	}

	public static function peek():Null<Bytes>
		return queue.length == 0 ? null : queue[0];

	/** Removes the next frame for the host, or null. */
	public static function take():Null<Bytes>
		return queue.shift();

	public static function result(id:Int, ok:Bool):Void {
		var done = waiting.get(id);
		waiting.remove(id);
		if (done != null) done(ok);
	}
}
