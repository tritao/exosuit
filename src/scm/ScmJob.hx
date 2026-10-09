package scm;

/** A provider operation that can be retired without allowing stale publication. */
class ScmJob<T> {
	public final generation:Int;
	final cancelAction:Null<Void->Void>;
	public var cancelled(default, null):Bool = false;
	public var complete(default, null):Bool = false;

	public function new(generation:Int, ?cancelAction:Void->Void) {
		this.generation = generation;
		this.cancelAction = cancelAction;
	}

	public function cancel():Bool {
		if (cancelled || complete) return false;
		cancelled = true;
		if (cancelAction != null) cancelAction();
		return true;
	}

	public function finish():Bool {
		if (cancelled || complete) return false;
		complete = true;
		return true;
	}
}
