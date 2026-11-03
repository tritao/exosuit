package devtools;

/**
	Marks for measuring a context switch from input to presented frame (docs/benchmarks/input-latency). Enabled only when
	`EXOSUIT_SWITCH_TRACE` names a file; otherwise `mark` costs one check. Every line is `<kind> <ticks> <text>` on the
	performance counter's clock (`haxeon.ProfileNativeTrace.ticks`), the clock of the input driver's send times, the input
	hook and NativeKit's NK_LATENCY_TRACE file, so the files merge on one timeline. Each line is appended and closed, because a test
	driver stops the editor without warning.

	  S key        the active context changed to `key` (the app is about to switch its views)
	  E key cold   the views switched; `cold` is 1 when the target was rebuilt from its snapshot
	  T warm pinned evicted   after the switch: contexts kept attached, how many cannot be evicted, whether one was
	                        (only the host's trim writes it)
	  R key        a frame was rendered (drawn into the surface) while the host showed `key`
**/
class SwitchTrace {
	static var path:Null<String> = null;
	static var checked = false;

	public static function enabled():Bool {
		if (!checked) open();
		return path != null;
	}

	static function open():Void {
		checked = true;
		var value = Sys.getEnv("EXOSUIT_SWITCH_TRACE");
		if (value == null || value.length == 0) return;
		try { sys.io.File.saveContent(value, ""); path = value; } catch (_:Dynamic) path = null;
	}

	public static function mark(kind:String, text:String):Void {
		if (!enabled()) return;
		var target = path;
		if (target == null) return;
		var ticks = haxe.Int64.toStr(haxe.Int64.fromFloat(haxeon.ProfileNativeTrace.ticks()));
		try sys.io.File.appendContent(target, kind + " " + ticks + " " + text + "\n") catch (_:Dynamic) {}
	}
}
