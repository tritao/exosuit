package suit;

/**
	An editor window and the context it has focused, as a `machine` reply lists it (M19 Phase 8). `context` is a
	ContextKey (`machine/workspace/group`); `pid` is the editor process that owns the window.
**/
typedef WindowFocus = {
	var window:String;
	var pid:Int;
	var context:String;
}

/** The `windows` field of a `machine` reply. Additive: an older suit sends none, an older editor ignores it. */
class WindowFocuses {
	/** The most windows a reply lists; more is junk. */
	public static inline final LIMIT = 64;

	/** The reply's `windows`: entries that are malformed are left out, and a reply without the field has none. */
	public static function decode(reply:Dynamic):Array<WindowFocus> {
		var result:Array<WindowFocus> = [];
		var listed:Dynamic = reply == null ? null : Reflect.field(reply, "windows");
		if (!Std.isOfType(listed, Array))
			return result;
		for (entry in (listed : Array<Dynamic>)) {
			if (result.length >= LIMIT)
				break;
			var window = SuitRecord.SuitRecords.stringField(entry, "window"), context = SuitRecord.SuitRecords.stringField(entry, "context");
			var pid = SuitRecord.SuitRecords.intField(entry, "pid");
			if (window != null && context != null && pid != null && pid > 0)
				result.push({window: window, pid: pid, context: context});
		}
		return result;
	}

	/** The windows other than `own` that focus `workspace` (and `group` when given). */
	public static function elsewhere(windows:Array<WindowFocus>, own:Null<String>, workspace:String, ?group:String):Array<WindowFocus> {
		var found:Array<WindowFocus> = [];
		for (focus in windows) {
			if (focus.window == own)
				continue;
			var parsed = parseKey(focus.context);
			if (parsed != null && parsed.workspace == workspace && (group == null || parsed.group == group))
				found.push(focus);
		}
		return found;
	}

	static function parseKey(key:String):Null<{machine:String, workspace:String, group:String}>
		return workspace.ContextKey.parse(key);
}
