package workspace;

/**
	Tells suit which context this editor window has focused, so the other windows can mark it in their Workbench
	(M19 Phase 8). `focus` is called every frame with the active context's key and costs a string compare; a change is
	passed to `publish` only after it has stayed for DEBOUNCE seconds, so dragging through contexts writes once.
	`publish` must not block (SuitClient.editorFocus writes on another thread).
**/
class WindowPresence {
	public static inline final DEBOUNCE = 0.3;

	final clock:Void->Float;
	final publish:String->Void;
	var wanted:Null<String>;
	var published:Null<String>;
	var dueAt:Float = 0;

	public function new(clock:Void->Float, publish:String->Void) {
		this.clock = clock; this.publish = publish;
	}

	/** The context the window shows now. */
	public function focus(key:String):Void {
		if (key == wanted)
			return;
		wanted = key;
		dueAt = clock() + DEBOUNCE;
	}

	/** Passes a settled change on; true when it did. Call every frame. */
	public function poll():Bool {
		var key = wanted;
		if (key == null || key == published || clock() < dueAt)
			return false;
		published = key;
		publish(key);
		return true;
	}
}
