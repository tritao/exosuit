package suit;

import haxe.Json;
import haxe.io.Path;

/**
	`stop-request.json` in a workspace manager's state directory: suit's request that the manager of one
	generation stop for good. suit writes it (SuitTerminator) and the manager consumes it (AgentManager),
	both through this module.

	Like a restart request, it names the generation it is for, so a request left behind for an older
	manager never stops a newer one.
**/
class WorkspaceStopRequest {
	public static inline var FILE_NAME:String = "stop-request.json";
	public static inline var VERSION:Int = 1;

	/** Requests larger than this are not stop requests. */
	public static inline var MAX_BYTES:Int = 4096;

	public static function path(stateDir:String):String
		return Path.join([stateDir, FILE_NAME]);

	/** Asks the manager of `generation` to stop. Written atomically into its private state directory. */
	public static function write(stateDir:String, generation:String):Void
		sys.io.AtomicFile.write(path(stateDir), Json.stringify({version: VERSION, generation: generation}) + "\n");

	/** True when a parsed request asks the manager of `generation` to stop. */
	public static function matches(document:Dynamic, generation:String):Bool
		return SuitRecords.intField(document, "version") == VERSION && SuitRecords.stringField(document, "generation") == generation;
}
