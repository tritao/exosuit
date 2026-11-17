package workspace;

/**
	Starts another editor window on a context (M19 Phase 8, "Open in New Window"): the same program with
	`--context=<machine/workspace/group>`, the environment of this window (so the same state folder and the same suit),
	detached so closing this window leaves it open. A window started with a context never hands its paths to another
	window (GraphicalMain's launch forwarding), so `suitctl open --new-window` gets its own window.
**/
class NewWindow {
	public static inline final ARGUMENT = "--context=";
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
	public static function arguments(program:String, key:String, ?liveModule:String, ?liveEntry:String, ?paths:Array<String>):Array<String> {
		var application = [ARGUMENT + key].concat(paths == null ? [] : paths);
		if (liveModule != null && liveModule != "" && liveEntry != null && liveEntry != "")
			return [program, liveModule, liveEntry, haxe.Json.stringify(application)];
		return [program].concat(application);
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

	/** Starts the window, with `paths` to open there; null when it started, else why not. */
	public static function open(key:String, ?paths:Array<String>):Null<String> {
		var began = Sys.time();
		try {
			var program = Sys.programPath();
			var keys:Array<String> = ["EXOSUIT_TERMINAL_CLIENT_KEY"], values:Array<String> = [""];
			var child = sys.io.Process.spawn(Sys.executablePath(), arguments(program, key, Sys.getEnv(LIVE_MODULE_VARIABLE), Sys.getEnv(LIVE_ENTRY_VARIABLE), paths),
				Sys.getCwd(), keys, values, true);
			child.close();
			slowestOpen = Math.max(slowestOpen, Sys.time() - began);
			return null;
		} catch (error:Dynamic)
			return "Could not start another window: " + Std.string(error);
	}
}
