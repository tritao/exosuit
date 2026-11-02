package workspace;

/**
	Starts another editor window on a context (M19 Phase 8, "Open in New Window"): the same program with
	`--context=<machine/workspace/group>`, the environment of this window (so the same state folder and the same suit),
	detached so closing this window leaves it open.

	A test that drives windows through the automation folder (EXOSUIT_AUTOMATION_DIR) names the new window's folder in
	`EXOSUIT_NEW_WINDOW_AUTOMATION_DIR`; without it the new window has none, so two windows never share one. The first
	window this process opens gets that folder, the second `<folder>-2`, and so on.
**/
class NewWindow {
	public static inline final ARGUMENT = "--context=";
	public static inline final AUTOMATION_VARIABLE = "EXOSUIT_NEW_WINDOW_AUTOMATION_DIR";
	static var opened = 0;
	/** The longest `open` blocked its caller, in seconds: the spawn runs on the frame that asked. */
	public static var slowestOpen:Float = 0;

	/** Set by `haxeon run --live`'s host (LiveHost) in the process it starts: the application module it runs and its entry class. */
	public static inline final LIVE_MODULE_VARIABLE = "HAXEON_LIVE_MODULE";
	public static inline final LIVE_ENTRY_VARIABLE = "HAXEON_LIVE_ENTRY";

	/**
		The arguments after the interpreter. Started plainly, `program` is the application and the context follows it. Under
		`run.py --live` the program is the live host, which takes the module, the entry class and the application's
		arguments as JSON; the new window then runs the same module through its own host, so it starts the way the first did
		and receives the compiler's patches from the same files.
	**/
	public static function arguments(program:String, key:String, ?liveModule:String, ?liveEntry:String):Array<String> {
		if (liveModule != null && liveModule != "" && liveEntry != null && liveEntry != "")
			return [program, liveModule, liveEntry, haxe.Json.stringify([ARGUMENT + key])];
		return [program, ARGUMENT + key];
	}

	/** The automation folder of the `count`th window this process opens (1 is the first), or "" when none is configured. */
	public static function automationDirectory(configured:Null<String>, count:Int):String {
		if (configured == null || configured == "") return "";
		return count <= 1 ? configured : configured + "-" + count;
	}

	/** The context a command line asks for, or null. */
	public static function contextOf(args:Array<String>):Null<String> {
		for (argument in args)
			if (StringTools.startsWith(argument, ARGUMENT)) {
				var key = argument.substr(ARGUMENT.length);
				return ContextKey.isScoped(key) ? key : null;
			}
		return null;
	}

	/** Starts the window; null when it started, else why not. */
	public static function open(key:String):Null<String> {
		var began = Sys.time();
		try {
			var program = Sys.programPath();
			var configured = Sys.getEnv(AUTOMATION_VARIABLE);
			var keys:Array<String> = ["EXOSUIT_AUTOMATION_DIR"], values:Array<String> = [automationDirectory(configured, ++opened)];
			var child = sys.io.Process.spawn(Sys.executablePath(), arguments(program, key, Sys.getEnv(LIVE_MODULE_VARIABLE), Sys.getEnv(LIVE_ENTRY_VARIABLE)),
				Sys.getCwd(), keys, values, true);
			child.close();
			slowestOpen = Math.max(slowestOpen, Sys.time() - began);
			return null;
		} catch (error:Dynamic)
			return "Could not start another window: " + Std.string(error);
	}
}
