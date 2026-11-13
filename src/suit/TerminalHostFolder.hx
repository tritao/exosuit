package suit;

import haxe.Json;
import haxe.io.Path;
import suit.SuitRecord.SuitRecords;
import sys.FileSystem;
import sys.io.File;

/** What a terminal host's folder says about it: which terminal of which workspace, and the running host's pid and program. */
typedef TerminalHostInfo = {
	var directory:String;
	/** The terminal's id and name, from `terminal.json`; null for a host started before that file was written. */
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

/** A pending `end-request.json`: why, and which host it is for (null pid and instance: any host, as older writers wrote it). */
typedef TerminalHostEndRequest = {
	var reason:String;
	var pid:Null<Int>;
	var instance:Null<String>;
}

/**
	The files in one terminal host's folder (`<workspace state>/terminal-hosts/<key>/`) that others than the host and
	its attached service read or write. Shared by the workspace service, the host and suit.

	- `terminal.json`: written by the service that starts the host. Names the terminal and its workspace, so suit can
	  show a host under its workspace and the host can tell when its workspace is gone.
	- `end-request.json`: anyone's request that the host end its program and itself. The host looks for it about once a
	  second, attached or not. It is the way to end a host that no service can reach over its pipe: one that has not
	  answered yet, one whose service runs without hosts, or one suit ends. Like a stop request for a service. It names
	  the host it is for by pid and instance id (`requestEnd`).
	- `end-request-<pid>.json`: the same request, written beside it when it names a host. There is one `end-request.json`
	  and the last writer wins: while two hosts poll the folder after Restart Terminal, suit's request for the new host
	  would replace the service's for the old one, which then kept running with its shell. A host of this build reads
	  its own file first; `end-request.json` is still written for hosts of older builds, which read only that.
	- `host.json`: written by the host (app.TerminalHostMain): its pid, pipe, token and instance id. Only the pid,
	  program and instance id are read here.
**/
class TerminalHostFolder {
	public static inline var TERMINAL_FILE:String = "terminal.json";
	public static inline var END_REQUEST_FILE:String = "end-request.json";
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

	/**
		Asks a host in `directory` to end its program and itself; `reason` goes to its log. Throws when it cannot be
		written. `pid` and `instance` (from `host.json`) address the request to one host: after Restart Terminal two hosts
		may poll the same folder for a moment, and a request for the old one must not end the new one. A host ignores, and
		leaves for its addressee, a request for another; one with neither ends whichever host reads it.
	**/
	public static function requestEnd(directory:String, reason:String, ?pid:Int, ?instance:String):Void {
		var content = Json.stringify({version: 2, reason: reason, pid: pid, instance: instance}) + "\n";
		if (pid != null)
			sys.io.AtomicFile.write(hostRequestPath(directory, pid), content);
		sys.io.AtomicFile.write(Path.join([directory, END_REQUEST_FILE]), content);
	}

	/** `end-request-<pid>.json`: the request for the host with this pid only. */
	static function hostRequestPath(directory:String, pid:Int):String
		return Path.join([directory, "end-request-" + pid + ".json"]);

	/**
		The pending request in this host's own file (`end-request-<pid>.json`) when it is for this host, or null. One
		with this pid and another instance was for an earlier process that had this pid: it is removed.
	**/
	public static function ownEndRequest(directory:String, pid:Int, instance:String):Null<TerminalHostEndRequest> {
		var request = endRequestOf(parse(hostRequestPath(directory, pid)));
		if (request == null)
			return null;
		if (addressedTo(request, pid, instance))
			return request;
		clearOwnEndRequest(directory, pid);
		return null;
	}

	/** Removes the request in the file for the host with this pid: taken by it, or left for a host that is gone. */
	public static function clearOwnEndRequest(directory:String, pid:Int):Void
		try FileSystem.deleteFile(hostRequestPath(directory, pid)) catch (_:Dynamic) {}

	/**
		The pending end request in `directory`, or null when there is none or it cannot be read. A file that vanished
		between looking and reading, is being replaced (a sharing violation), is too large or is not a request's JSON is
		no request: it is left where it is and read again on the next poll. Read as "any host" it would end whichever host
		got the failure, such as the new host of a restarted terminal reading a request its old host was taking.
	**/
	public static function endRequest(directory:String):Null<TerminalHostEndRequest>
		return endRequestOf(parse(Path.join([directory, END_REQUEST_FILE])));

	/**
		A parsed `end-request.json` as a request, or null when it is not one. Version 1 (older writers) named no host, so
		it is for any host. From version 2 the pid and instance are as written: both null only when the writer knew no
		host (`requestEnd` before the host wrote `host.json`).
	**/
	public static function endRequestOf(parsed:Dynamic):Null<TerminalHostEndRequest> {
		var version = SuitRecords.intField(parsed, "version");
		if (version == null || version < 1)
			return null;
		var reason = SuitRecords.stringField(parsed, "reason");
		return {
			reason: reason == null ? "no reason given" : reason,
			pid: version >= 2 ? SuitRecords.intField(parsed, "pid") : null,
			instance: version >= 2 ? SuitRecords.stringField(parsed, "instance") : null
		};
	}

	/** Whether `request` is for the host with this pid and instance id. */
	public static function addressedTo(request:TerminalHostEndRequest, pid:Int, instance:String):Bool
		return (request.pid == null || request.pid == pid) && (request.instance == null || request.instance == instance);

	/** Removes a request the host has taken, or one left for a host that is gone. */
	public static function clearEndRequest(directory:String):Void
		try FileSystem.deleteFile(Path.join([directory, END_REQUEST_FILE])) catch (_:Dynamic) {}
}
