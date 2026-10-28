package processkit;

import processkit.ffi.ProcessKit;
import processkit.ffi.ProcessKitConstants;

/** One running process. `started` is milliseconds since the Unix epoch (0 when unknown); with `pid` it identifies the process. */
typedef ProcessInfo = {
	var pid:Int;
	var parent:Int;
	var started:Float;
	var name:String;
	var commandLine:String;

	/** The requested environment variables, as "NAME=value" lines; empty when none was read. */
	var environment:String;
}

/**
	Same-user process inspection and termination. Every action re-checks the pid's start time in processkit
	before it acts, and refuses a process whose start time is unknown. Results are the `PROCESSKIT_*` statuses.
**/
class Processes {
	/**
		Every running process. Command lines are read only for processes whose executable base name is in
		the `;`-separated `commandLineNames` list ("*" for all, empty for none), and so are the environment
		variables named in the `;`-separated `variables` list. Returns null when listing is unsupported.
	**/
	public static function list(commandLineNames:String, variables:String = ""):Null<Array<ProcessInfo>> {
		var opened = ProcessKit.processkit_list_open(commandLineNames, variables);
		if (opened.status != ProcessKitConstants.PROCESSKIT_OK)
			return null;
		var owner = opened.out_list;
		var handle = owner.borrow();
		var result:Array<ProcessInfo> = [];
		try {
			for (index in 0...ProcessKit.processkit_list_count(handle))
				result.push({
					pid: ProcessKit.processkit_list_pid(handle, index),
					parent: ProcessKit.processkit_list_parent(handle, index),
					started: ProcessKit.processkit_list_started(handle, index),
					name: ProcessKit.processkit_list_name(handle, index),
					commandLine: ProcessKit.processkit_list_command_line(handle, index),
					environment: ProcessKit.processkit_list_environment(handle, index)
				});
		} catch (error:Dynamic) {
			owner.close();
			throw error;
		}
		owner.close();
		return result;
	}

	/** What `started` returns for a running process this user may not open. */
	public static inline var STARTED_DENIED:Float = -2;

	/** Start time of a running process, 0 when it cannot be read, -1 when it is not running, or STARTED_DENIED. */
	public static function started(pid:Int):Float
		return ProcessKit.processkit_started(pid);

	/** True when `pid` is running and is still the process that started at `started`. */
	public static function alive(pid:Int, started:Float):Bool
		return ProcessKit.processkit_identify(pid, started) == ProcessKitConstants.PROCESSKIT_OK;

	public static function terminate(pid:Int, started:Float):Int
		return ProcessKit.processkit_terminate(pid, started);

	/** Asks for a graceful close (WM_CLOSE to its windows on Windows, SIGTERM elsewhere). */
	public static function requestClose(pid:Int, started:Float):Int
		return ProcessKit.processkit_request_close(pid, started);

	/** The value of `name` in an environment read by `list`, or null when the process did not have it. */
	public static function variable(info:ProcessInfo, name:String):Null<String> {
		var foldCase = Sys.systemName() == "Windows";
		var wanted = foldCase ? name.toUpperCase() : name;
		for (line in info.environment.split("\n")) {
			var equals = line.indexOf("=");
			if (equals <= 0)
				continue;
			var key = line.substr(0, equals);
			if ((foldCase ? key.toUpperCase() : key) == wanted)
				return line.substr(equals + 1);
		}
		return null;
	}

	public static function currentPid():Int
		return ProcessKit.processkit_current_pid();
}
