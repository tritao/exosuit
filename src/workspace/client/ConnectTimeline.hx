package workspace.client;

/**
	When the steps of connecting to a workspace happen, in seconds since the process began: suit's reply, the helper
	processes, the handshake, the first catalog read. Kept in memory (the last MAX events) and shown in the
	automation state, so a scenario can time a connection without parsing logs. With EXOSUIT_CONNECT_LOG set, each
	event is also printed to stderr. Marking is a push to an array: cheap enough for every frame's edge, never on its hot path.
**/
class ConnectTimeline {
	static inline final MAX = 400;
	static final began = Sys.time();
	static final events:Array<{t:Float, event:String, workspace:String, detail:String}> = [];
	static final once:Map<String, Bool> = [];
	static final atFrame:Array<{event:String, workspace:Null<String>, detail:Null<String>}> = [];
	static final echo:Bool = wantsEcho();

	static function wantsEcho():Bool {
		var value = Sys.getEnv("EXOSUIT_CONNECT_LOG");
		return value != null && value.length > 0;
	}

	public static function mark(event:String, ?workspace:String, ?detail:String):Void {
		var t = Sys.time() - began;
		if (events.length >= MAX)
			events.shift();
		events.push({t: t, event: event, workspace: workspace == null ? "" : workspace, detail: detail == null ? "" : detail});
		if (echo)
			Sys.stderr().writeString("connect " + Std.int(t * 1000) + "ms " + event + " " + (workspace == null ? "" : workspace) + " "
				+ (detail == null ? "" : detail) + "\n");
	}

	/** Marks the first time only, for `key` (events that repeat every frame while a state holds); true when it marked. */
	public static function markOnce(key:String, event:String, ?workspace:String, ?detail:String):Bool {
		if (once.exists(key))
			return false;
		once.set(key, true);
		mark(event, workspace, detail);
		return true;
	}

	/** Marks `event` when the next frame has been drawn: the moment a state the app just reached is on screen. */
	public static function markAtNextFrame(event:String, ?workspace:String, ?detail:String):Void
		atFrame.push({event: event, workspace: workspace, detail: detail});

	/** Called by the host after each drawn frame; marks what waited for it. */
	public static function frameDrawn():Void {
		if (atFrame.length == 0)
			return;
		for (e in atFrame.splice(0, atFrame.length))
			mark(e.event, e.workspace, e.detail);
	}

	/** Whether `markOnce` recorded `key` (and it was not rearmed since). */
	public static function marked(key:String):Bool
		return once.exists(key);

	/** Forgets that `key` was marked, so its next markOnce records again (a state that begins anew). */
	public static function rearm(key:String):Void
		once.remove(key);

	public static function snapshot():Array<Dynamic>
		return [for (e in events) {t: Math.round(e.t * 1000), event: e.event, workspace: e.workspace, detail: e.detail}];
}
