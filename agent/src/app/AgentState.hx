package app;

import haxe.Json;
import haxe.crypto.Sha256;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
	A workspace's state folder, as its service uses it: `workspaces/<id>` under the state base, private to this user.
	It holds the lock that makes the service the only one of its workspace, `workspace.json` (whose state it is), the
	catalog database and `service.log`. Nothing in it says how to reach the
	service: exohost started it and answers `workspace.open` with the pipe the service reported.
**/
class AgentState {
	/** The per-user folder holding `workspaces` (each workspace's state) and `terminal-host` (the hosts' runtime copies). */
	public static function base():String
		return exohost.MachineCatalog.agentStateBase();

	/** Workspace `id`'s state folder, spelled the same before and after it exists. */
	public static function directoryOf(id:String):String
		return absolute(Path.join([base(), "workspaces", id]));

	/**
		The pipe (a named pipe on Windows, else a short hashed socket in `workspace-sockets` beside the state folders, see
		MachineCatalog.workspaceSocket) the service of workspace `id` listens on. Call `prepareSocketFolder` before listening.
	**/
	public static function endpointOf(id:String, directory:String):String
		return Sys.systemName() == "Windows" ? "\\\\.\\pipe\\exosuit-" + Sha256.encode(id + "\n" + directory).substr(0, 20)
			: exohost.MachineCatalog.workspaceSocket(directory);

	/** Creates the folder of the service's socket, private to this user (mode 700). A no-op on Windows. */
	public static function prepareSocketFolder(endpoint:String):Void {
		if (Sys.systemName() == "Windows") return;
		var folder = Path.directory(endpoint);
		ensureDirectories(Path.directory(folder));
		if (!AgentNative.prepareDirectory(folder))
			throw "Workspace socket folder must be private and owned by this user";
	}

	/**
		Removes the `agent.sock` an older build left in this workspace's own state folder (`workspaces/<id>`, now unused:
		the service listens in `workspace-sockets`). Only that one file, only when it is a socket and not a link.
	**/
	public static function removeStaleSocket(stateDirectory:String):Void {
		if (Sys.systemName() == "Windows") return;
		var stale = Path.join([stateDirectory, "agent.sock"]);
		try {
			if (!FileSystem.exists(stale) && !isLink(stale)) return;
			if (isLink(stale) || Sys.command("test", ["-S", stale]) != 0) return;
			FileSystem.deleteFile(stale);
		} catch (_) {}
	}

	static function isLink(path:String):Bool
		return Sys.command("test", ["-L", path]) == 0;

	static function absolute(path:String):String {
		// fullPath uses realpath on POSIX, which fails before a new state directory exists. Keep separators identical
		// before and after creation: this path also names the pipe.
		return Path.normalize(FileSystem.exists(path) ? FileSystem.fullPath(path)
			: Path.isAbsolute(path) ? path : Path.join([Sys.getCwd(), path]));
	}

	/** Creates the state folder, private to this user, with its parents; throws when an existing one is not private. */
	public static function prepare(directory:String):Void {
		var parent = Path.directory(directory);
		if (parent == directory || parent == "") throw "Invalid workspace state path";
		ensureDirectories(parent);
		if (!AgentNative.prepareDirectory(directory))
			throw "Workspace state directory must be private and owned by this user";
		var database = Path.join([directory, "catalog.sqlite"]);
		for (path in [database, database + "-wal", database + "-shm", database + ".sqlitekit-lock"])
			if (FileSystem.exists(path) && !AgentNative.privateFile(path))
				throw 'Workspace state file is not private: $path';
	}

	static function ensureDirectories(path:String):Void {
		if (FileSystem.exists(path)) {
			if (!FileSystem.isDirectory(path)) throw 'Expected a directory: $path';
			return;
		}
		var parent = Path.directory(path);
		if (parent == path || parent == "") throw 'Could not create directory: $path';
		ensureDirectories(parent);
		// The check below reports a failure with this function's message.
		try FileSystem.createDirectory(path) catch (_:Dynamic) {}
		if (!FileSystem.isDirectory(path)) throw 'Could not create directory: $path';
	}

	/**
		The workspace this state folder serves, with the folders it serves now: `folders` and `scratch` as exohost passed them,
		else (a start by id alone) those recorded at its last start that still exist. Records them for the next start.
	**/
	public static function claim(directory:String, id:String, folders:Array<String>, scratch:Null<String>):AgentStateIdentity {
		var path = Path.join([directory, "workspace.json"]);
		var recorded = FileSystem.exists(path) ? AgentStateIdentity.read(path) : null;
		if (recorded != null && recorded.workspace != id) throw "Workspace state directory identity mismatch";
		if (folders.length == 0 && scratch == null && recorded != null) {
			folders = [for (folder in recorded.folders) if (FileSystem.exists(folder) && FileSystem.isDirectory(folder)) folder];
			scratch = recorded.scratch;
		}
		var identity = AgentStateIdentity.forWorkspace(id, folders, scratch);
		identity.write(path);
		return identity;
	}

	/** The Codex proxy bridge beside the agent (a bundle's) or in the checkout's scripts folder, or null. */
	public static function codexProxy():Null<String> {
		var directory = Path.directory(FileSystem.fullPath(Sys.programPath()));
		for (_ in 0...8) {
			var packaged = Path.join([directory, "run-codex-proxy.py"]);
			if (FileSystem.exists(packaged)) return packaged;
			var candidate = Path.join([directory, "scripts", "run-codex-proxy.py"]);
			if (FileSystem.exists(candidate)) return candidate;
			var parent = Path.directory(directory);
			if (parent == directory || parent.length == 0) break;
			directory = parent;
		}
		return null;
	}

	public static function readPrivateJson(path:String, limit:Int):Dynamic {
		if (!AgentNative.privateFile(path)) throw 'Expected a private owned file: $path';
		var info = FileSystem.metadata(path);
		if (info == null || info.size > limit) throw 'Invalid private file: $path';
		try return Json.parse(File.getContent(path)) catch (_:Dynamic) throw 'Invalid JSON file: $path';
	}

	public static function isObject(value:Dynamic):Bool
		return value != null && Reflect.isObject(value) && !Std.isOfType(value, Array);

	public static function intField(value:Dynamic, field:String):Int {
		var result:Dynamic = Reflect.field(value, field);
		return Std.isOfType(result, Int) ? cast result : -1;
	}

	public static function stringField(value:Dynamic, field:String):String {
		var result:Dynamic = Reflect.field(value, field);
		return Std.isOfType(result, String) ? cast result : "";
	}
}
