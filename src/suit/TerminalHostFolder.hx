package suit;

import haxe.Json;
import haxe.io.Path;
import suit.SuitRecord.SuitRecords;
import sys.FileSystem;
import sys.io.File;

/** What a terminal host's folder says about it: which terminal of which workspace, and the running host's pid and program. */
typedef TerminalHostInfo = {
	var directory:String;
	/** The terminal's id and name, from `terminal.json`. */
	var terminal:Null<String>;
	var name:Null<String>;
	/** The workspace's id (null for a folder's service) and the folder its service started in. */
	var workspace:Null<String>;
	var root:Null<String>;
	/** From `host.json`, which the running host wrote: its pid, the program in the terminal and the host's instance id. */
	var pid:Null<Int>;
	var program:Null<String>;
	var instance:Null<String>;
}

/**
	The files in one terminal host's folder (`<workspace state>/terminal-hosts/<key>/`) that others than the host and
	its attached service read. Shared by the workspace service, the host and suit.

	- `terminal.json`: written by the service that starts the host. Names the terminal and its workspace, so suit can
	  show a host under its workspace and the host can tell when its workspace is gone.
	- `host.json`: written by the host (app.TerminalHostMain): its pid, pipe, token and instance id. Only the pid,
	  program and instance id are read here.

	A host is ended over its pipe (TerminalHostProtocol END) by a service, or killed by suit.
**/
class TerminalHostFolder {
	public static inline var TERMINAL_FILE:String = "terminal.json";
	public static inline var HOST_FILE:String = "host.json";
	static inline var MAX_BYTES:Int = 16384;

	/** Called by the service before it starts the host. */
	public static function writeTerminal(directory:String, terminal:String, name:Null<String>, workspace:Null<String>, root:Null<String>):Void
		sys.io.AtomicFile.write(Path.join([directory, TERMINAL_FILE]),
			Json.stringify({version: 1, terminal: terminal, name: name, workspace: workspace, root: root}) + "\n");

	static function parse(path:String):Dynamic {
		try {
			if (!FileSystem.exists(path))
				return null;
			var metadata = FileSystem.metadata(path);
			if (metadata == null || metadata.size > MAX_BYTES)
				return null;
			return Json.parse(File.getContent(path));
		} catch (_:Dynamic) {
			return null;
		}
	}

	public static function read(directory:String):TerminalHostInfo {
		var terminal = parse(Path.join([directory, TERMINAL_FILE]));
		var host = parse(Path.join([directory, HOST_FILE]));
		return {
			directory: directory,
			terminal: SuitRecords.stringField(terminal, "terminal"),
			name: SuitRecords.stringField(terminal, "name"),
			workspace: SuitRecords.stringField(terminal, "workspace"),
			root: SuitRecords.stringField(terminal, "root"),
			pid: SuitRecords.intField(host, "pid"),
			program: SuitRecords.stringField(host, "program"),
			instance: SuitRecords.stringField(host, "instance")
		};
	}
}
