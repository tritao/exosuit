package app;

import exohost.ExohostControl;

/** A path to open, with the 1-based line and column to put the cursor on when the command line named them. */
typedef LaunchPath = {path:String, line:Null<Int>, column:Null<Int>};

/**
	`exosuit <folder|file>...` with an Exosuit window already open hands the paths to it instead of opening another
	window (docs/design/exohostctl/TDD-exosuit-ctl.md §8.3, Q3=a). Each path goes to exohost as `editor.open`, which exohost routes
	to the window whose workspaces hold it, else to the most recently used window (§6); that window opens it the way it
	opens any path (a folder: the workspace that holds it, or a new one named after it; a file: a tab), and is raised.

	It has one second in all. Paths a window took are not opened here; when none was taken (exohost is not running, no window
	is open, or the time ran out) this process opens its own window with everything. A window started for a context
	(`--context=`, Open in New Window), with `--new-window`, for a capture or benchmark, or under `run.py --live` (which
	does not come through `GraphicalMain.main`) never forwards.

	`path:line[:column]` (Q16) is read when the suffix is digits and the whole argument is not an existing file, and
	`--goto LINE[:COLUMN]` gives the line for the paths that follow.
**/
class LaunchForwarding {
	static inline final BUDGET_SECONDS = 1.0;
	/** Arguments after which this process always opens its own window. */
	static final OWN_WINDOW = ["--new-window", "--context=", "--capture-dir=", "--record-path=", "--input-script=", "--smoke-frames=", "--title="];

	/**
		The arguments this process still has to handle, or null when every path went to another window. A path's
		`:line[:column]` suffix and `--goto` are read here: the arguments returned name the plain paths, and `positions`
		the ones of them with a line, for the window this process opens.
	**/
	public static function forward(arguments:Array<String>):Null<{arguments:Array<String>, positions:Array<LaunchPath>}> {
		var paths:Array<LaunchPath> = [];
		var local:Array<String> = [];
		var ownWindow = false;
		var gotoLine:Null<Int> = null, gotoColumn:Null<Int> = null;
		var index = 0;
		while (index < arguments.length) {
			var argument = arguments[index++];
			for (prefix in OWN_WINDOW)
				if (StringTools.startsWith(argument, prefix)) ownWindow = true;
			if (argument == "--goto" && index < arguments.length) {
				var spec = arguments[index++].split(":");
				gotoLine = decimal(spec[0]);
				gotoColumn = spec.length > 1 ? decimal(spec[1]) : null;
				continue;
			}
			if (StringTools.startsWith(argument, "--")) {
				local.push(argument);
				continue;
			}
			var located = locate(argument);
			if (gotoLine != null) {
				located.line = gotoLine;
				located.column = gotoColumn;
			}
			paths.push(located);
			local.push(located.path);
		}
		var positions = [for (item in paths) if (item.line != null) item];
		if (ownWindow || paths.length == 0) return {arguments: local, positions: positions};
		var deadline = Sys.time() + BUDGET_SECONDS;
		var taken:Array<String> = [];
		var windows:Array<String> = [];
		for (item in paths) {
			var left = deadline - Sys.time();
			if (left <= 0) break;
			var params:Dynamic = {path: item.path};
			if (item.line != null) params.line = item.line;
			if (item.column != null) params.column = item.column;
			var reply = ExohostControl.request({op: "control", version: 1, client_id: "exosuit-launch:" + Sys.getPid(), method: "editor.open",
				params: params, target: {path: item.path}}, left);
			if (reply == null || Reflect.field(reply, "ok") != true) break;
			taken.push(item.path);
			var window:Null<String> = Reflect.field(reply, "instance_id");
			if (window != null && windows.indexOf(window) < 0) windows.push(window);
		}
		if (windows.length == 0) return {arguments: local, positions: positions};
		// Every window that took a path is raised, the last one on top.
		for (window in windows)
			ExohostControl.request({op: "control", version: 1, client_id: "exosuit-launch:" + Sys.getPid(), method: "window.focus", params: {},
				target: {instance_id: window}}, Math.max(0.2, deadline - Sys.time()));
		if (taken.length == paths.length) return null;
		// The rest open here, in a window of this process's own.
		return {arguments: [for (argument in local) if (taken.indexOf(argument) < 0) argument],
			positions: [for (item in positions) if (taken.indexOf(item.path) < 0) item]};
	}

	/** `path:line[:column]` when the suffix is digits and the argument is not an existing file. */
	static function locate(argument:String):{path:String, line:Null<Int>, column:Null<Int>} {
		var suffix = ~/^(.+?):([0-9]+)(?::([0-9]+))?$/;
		if (!sys.FileSystem.exists(argument) && suffix.match(argument) && suffix.matched(1).length > 1) {
			var column = suffix.matched(3);
			return {path: sys.FileSystem.absolutePath(suffix.matched(1)), line: decimal(suffix.matched(2)), column: column == null ? null : decimal(column)};
		}
		return {path: sys.FileSystem.absolutePath(argument), line: null, column: null};
	}

	/** A decimal number written with digits only. */
	static function decimal(text:String):Null<Int>
		return ~/^[0-9]+$/.match(text) ? Std.parseInt(text) : null;
}
