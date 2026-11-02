package workspace;

/**
	Starts another editor window on a context (M19 Phase 8, "Open in New Window"): the same program with
	`--context=<machine/workspace/group>`, the environment of this window (so the same state folder and the same suit),
	detached so closing this window leaves it open.

	A test that drives windows through the automation folder (EXOSUIT_AUTOMATION_DIR) names the new window's folder in
	`EXOSUIT_NEW_WINDOW_AUTOMATION_DIR`; without it the new window has none, so two windows never share one.
**/
class NewWindow {
	public static inline final ARGUMENT = "--context=";
	public static inline final AUTOMATION_VARIABLE = "EXOSUIT_NEW_WINDOW_AUTOMATION_DIR";

	/** The arguments after the interpreter: the program, then the context. */
	public static function arguments(program:String, key:String):Array<String>
		return [program, ARGUMENT + key];

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
		try {
			var program = Sys.programPath();
			var configured = Sys.getEnv(AUTOMATION_VARIABLE);
			var keys:Array<String> = ["EXOSUIT_AUTOMATION_DIR"], values:Array<String> = [configured == null ? "" : configured];
			var child = sys.io.Process.spawn(Sys.executablePath(), arguments(program, key), Sys.getCwd(), keys, values, true);
			child.close();
			return null;
		} catch (error:Dynamic)
			return "Could not start another window: " + Std.string(error);
	}
}
