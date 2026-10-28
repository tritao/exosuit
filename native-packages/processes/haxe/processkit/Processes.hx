package processkit;

import processkit.ffi.ProcessKit;

/** One running process. `started` is milliseconds since the Unix epoch; with `pid` it identifies the process. */
typedef ProcessInfo = {
	var pid:Int;
	var parent:Int;
	var started:Float;
	var name:String;
	var commandLine:String;
}

/** Same-user process inspection and termination. Every action re-checks the start time before it acts. */
class Processes {
	public static inline var OK:Int = 0;
	public static inline var NOT_FOUND:Int = 1;
	public static inline var ACCESS_DENIED:Int = 2;
	public static inline var UNSUPPORTED:Int = 3;

	/**
		Every running process. Command lines are read only for processes whose executable base name is in
		the `;`-separated `names` list (all when empty). Returns null when listing is unsupported.
	**/
	public static function list(names:String):Null<Array<ProcessInfo>> {
		var opened = ProcessKit.processkit_list_open(names);
		if (opened.status != 0 || opened.out_list == null)
			return null;
		var handle = opened.out_list;
		var result:Array<ProcessInfo> = [];
		try {
			for (index in 0...ProcessKit.processkit_list_count(handle))
				result.push({
					pid: ProcessKit.processkit_list_pid(handle, index),
					parent: ProcessKit.processkit_list_parent(handle, index),
					started: ProcessKit.processkit_list_started(handle, index),
					name: ProcessKit.processkit_list_name(handle, index),
					commandLine: ProcessKit.processkit_list_command_line(handle, index)
				});
		} catch (error:Dynamic) {
			ProcessKit.processkit_list_close(handle);
			throw error;
		}
		ProcessKit.processkit_list_close(handle);
		return result;
	}

	/** Start time of a running process, or -1 when it is not running. */
	public static function started(pid:Int):Float
		return ProcessKit.processkit_started(pid);

	/** True when `pid` still names the process that started at `started` (any start time when it is 0). */
	public static function alive(pid:Int, started:Float):Bool {
		var current = ProcessKit.processkit_started(pid);
		return current >= 0 && (started <= 0 || current <= 0 || Math.abs(current - started) < 20);
	}

	public static function terminate(pid:Int, started:Float):Int
		return ProcessKit.processkit_terminate(pid, started);

	/** Asks for a graceful close (WM_CLOSE to its windows on Windows, SIGTERM elsewhere). */
	public static function requestClose(pid:Int, started:Float):Int
		return ProcessKit.processkit_request_close(pid, started);

	public static function currentPid():Int
		return ProcessKit.processkit_current_pid();
}
