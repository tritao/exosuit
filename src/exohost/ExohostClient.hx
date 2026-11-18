package exohost;

import haxe.io.Path;
import exohost.ExohostRecord.ExohostRecords;
import exohost.ExohostRecord.ExohostWorkspace;
import sys.FileSystem;

/**
	The process side of exohost for workspace services and terminal hosts, and starting exohost.

	A service or a host registers with a small JSON record in exohost's registry directory, written atomically. It never
	blocks on exohost and never throws: if exohost is down the record waits for it, and if the directory cannot be written
	the process simply goes unregistered. The daemon checks each record's pid against the process start time, so a stale
	record for a reused pid is discarded rather than trusted. Editors do not register: their link is their record
	(ExohostLink).

	exohost is always on. Tests and other unattended runs isolate it with their own `EXOSUIT_EXOHOST_HOME`, which gives them
	their own registry, catalog and pipe (ExohostPaths).
**/
class ExohostClient {
	static var registered:Bool = false;
	static var daemonRequested:Bool = false;
	/** Why the last attempt to start exohost failed, or null. */
	static var startFailure:Null<String> = null;

	/** True when `path` is inside the system temp folder (TEMP or TMP on Windows, TMPDIR or /tmp elsewhere). */
	public static function underTemp(path:String):Bool {
		var windows = Sys.systemName() == "Windows";
		var roots = windows ? [Sys.getEnv("TEMP"), Sys.getEnv("TMP")] : [Sys.getEnv("TMPDIR"), "/tmp"];
		var candidate = normalized(path) + "/";
		for (root in roots)
			if (root != null && root.length > 0 && StringTools.startsWith(candidate, normalized(root) + "/"))
				return true;
		return false;
	}

	static function normalized(path:String):String {
		var result = StringTools.replace(path, "\\", "/");
		while (result.length > 1 && StringTools.endsWith(result, "/"))
			result = result.substr(0, result.length - 1);
		return Sys.systemName() == "Windows" ? result.toLowerCase() : result;
	}

	/**
		Registers a workspace service. It belongs to every editor that uses its workspace, not to the editor that
		happened to start it, so it is not passed any editor's pid.
	**/
	public static function registerWorkspaceService(kind:ExohostKind, workspace:ExohostWorkspace):Void
		writeRecord(kind, workspace);

	/**
		Registers a terminal host under the workspace whose terminal it keeps (`generation` is unused). A host is
		detached from the service that started it, so nothing but this record ties it to exosuit. It does not start
		the daemon: a host must not bring exohost back after the user quit it.
	**/
	public static function registerTerminalHost(workspace:ExohostWorkspace):Void
		writeRecord(ExohostKind.TerminalHost, workspace);

	/** Removes this process's record on a clean exit. Exohost also prunes records of processes that are gone. */
	public static function unregister():Void {
		if (!registered)
			return;
		try {
			var path = ExohostRecords.path(ExohostPaths.registry(), Sys.getPid());
			if (FileSystem.exists(path))
				FileSystem.deleteFile(path);
			registered = false;
		} catch (_:Dynamic) {}
	}

	static function writeRecord(kind:ExohostKind, workspace:ExohostWorkspace):Void {
		try {
			if (!ExohostPaths.prepare())
				return;
			var record = ExohostRecords.create(Sys.getPid(), kind);
			record.root = workspace.root;
			record.workspace = workspace.workspace;
			record.stateDir = workspace.stateDir;
			record.generation = workspace.generation;
			ExohostRecords.write(ExohostPaths.registry(), record);
			registered = true;
		} catch (_:Dynamic) {}
	}

	/**
		Starts the exohost daemon, detached, unless `EXOSUIT_EXOHOST_AUTOSTART=0` is set or exohost is not installed. A second
		daemon exits at once when one already holds the lock, so this need not check. It starts exohost once until
		`daemonAnswered`: a link that keeps retrying does not spawn a process each time.
	**/
	public static function ensureDaemon():Void {
		if (daemonRequested || Sys.getEnv("EXOSUIT_EXOHOST_AUTOSTART") == "0")
			return;
		daemonRequested = true;
		startFailure = null;
		try {
			var launcher = findLauncher();
			if (launcher != null)
				startDaemon(launcher);
		} catch (error:Dynamic) {
			startFailure = Std.string(error);
		}
	}

	/**
		Why a window that cannot reach exohost cannot: exohost is not built here, its automatic start is off, starting it
		failed, or it was started and does not answer. The Workbench shows this instead of looking for workspaces for ever.
	**/
	public static function unreachableReason():String
		return explainUnreachable(Sys.getEnv("EXOSUIT_EXOHOST_AUTOSTART") == "0", findLauncher() != null, startFailure);

	/** The text for `unreachableReason`, from what it found. */
	public static function explainUnreachable(autostartOff:Bool, built:Bool, startFailure:Null<String>):String {
		if (!built)
			return "exohost is not built here (no exohost/build/host/main.hl or tools/exosuit-exohost.hl), so there are no workspaces to list. Build Exosuit, then retry.";
		if (autostartOff)
			return "exohost is not running, and starting it automatically is off (EXOSUIT_EXOHOST_AUTOSTART=0).";
		if (startFailure != null)
			return "exohost could not be started: " + startFailure;
		return "exohost was started but is not answering.";
	}

	/** exohost answered: the next time it does not, `ensureDaemon` starts it again. */
	public static function daemonAnswered():Void
		daemonRequested = false;

	/** Spawns `hl <launcher> daemon`, detached, with exohost's native libraries on the library path. */
	public static function startDaemon(launcher:String):Void {
		var child = sys.io.ChildProcess.spawn(Sys.executablePath(), [launcher, "daemon"], Path.directory(launcher), [libraryVariable()],
			[nativePath(launcher)], true);
		child.close();
	}

	/** The exohost bytecode: `EXOSUIT_EXOHOST_LAUNCHER`, a source build's exohost/build/host/main.hl, or a bundle's tools/exosuit-exohost.hl. */
	public static function findLauncher():Null<String> {
		var configured = nonempty(Sys.getEnv("EXOSUIT_EXOHOST_LAUNCHER"));
		if (configured != null)
			return FileSystem.exists(configured) ? FileSystem.fullPath(configured) : null;
		var starts:Array<String> = [];
		try starts.push(Path.directory(FileSystem.fullPath(Sys.programPath()))) catch (_:Dynamic) {}
		try starts.push(FileSystem.fullPath(Sys.getCwd())) catch (_:Dynamic) {}
		for (start in starts) {
			var directory = start;
			for (_ in 0...10) {
				for (candidate in [Path.join([directory, "exohost", "build", "host", "main.hl"]), Path.join([directory, "tools", "exosuit-exohost.hl"])])
					if (FileSystem.exists(candidate))
						return FileSystem.fullPath(candidate);
				var parent = Path.directory(directory);
				if (parent == directory || parent.length == 0)
					break;
				directory = parent;
			}
		}
		return null;
	}

	/**
		The library path exohost runs with. This rule is shared with `library_path` in scripts/exohost.py, which
		starts exohost from a source tree; keep the two in the same order:

		1. every directory under `<launcher dir>/native` (exohost's own native packages)
		2. `lib` beside the launcher's directory (a bundle keeps tools/ and lib/ side by side)
		3. the directory of the HashLink runtime that runs exohost (Haxeon's VM directory, which holds no libraries now)
		4. `out` under the Haxeon checkout (`HAXEON_HOME`; scripts/exohost.py uses `HAXEON_ROOT`)
		5. the inherited value
	**/
	public static function nativePath(launcher:String):String {
		var directories:Array<String> = [];
		var nativeRoot = Path.join([Path.directory(launcher), "native"]);
		if (FileSystem.exists(nativeRoot) && FileSystem.isDirectory(nativeRoot)) {
			var entries = FileSystem.readDirectory(nativeRoot);
			entries.sort(Reflect.compare);
			for (entry in entries) {
				var path = Path.join([nativeRoot, entry]);
				if (FileSystem.isDirectory(path))
					directories.push(path);
			}
		}
		var install = Path.directory(Path.directory(launcher));
		for (path in [Path.join([install, "lib"]), Path.directory(Sys.executablePath())])
			if (FileSystem.exists(path) && directories.indexOf(path) < 0)
				directories.push(path);
		var haxeonHome = nonempty(Sys.getEnv("HAXEON_HOME"));
		if (haxeonHome != null) {
			var haxeonOut = Path.join([haxeonHome, "out"]);
			if (FileSystem.exists(haxeonOut))
				directories.push(haxeonOut);
		}
		var inherited = Sys.getEnv(libraryVariable());
		if (inherited != null && inherited.length > 0)
			directories.push(inherited);
		return directories.join(Sys.systemName() == "Windows" ? ";" : ":");
	}

	public static function libraryVariable():String
		return switch Sys.systemName() {
			case "Windows": "PATH";
			case "Mac": "DYLD_LIBRARY_PATH";
			default: "LD_LIBRARY_PATH";
		};

	static function nonempty(value:Null<String>):Null<String>
		return value == null || value.length == 0 ? null : value;
}
