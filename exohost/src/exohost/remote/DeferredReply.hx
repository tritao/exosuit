package exohost.remote;

/** A reply a control request gets later, when the pairing step it started completes. */
class DeferredReply {
	public var reply(default, null):Null<Dynamic> = null;
	public final started:Float = Sys.time();

	public function new() {}

	public function resolve(value:Dynamic):Void
		reply = value;
}
