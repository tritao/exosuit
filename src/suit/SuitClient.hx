package suit;

import haxe.io.Path;
import suit.SuitRecord.SuitRecords;
import suit.SuitRecord.SuitWorkspace;
import sys.FileSystem;

/** What `EXOSUIT_SUIT` allows this process to do with suit. */
enum SuitMode {
	/** Register in the user's suit (or `EXOSUIT_SUIT_HOME`), and start the daemon. The default. */
	On;

	/** Register only in the suit at `EXOSUIT_SUIT_HOME`; without one, behave as Off. */
	Isolated;

	/** Neither register nor start a daemon. Tests and other unattended runs use this. */
	Off;
}

/**
	Registers this process with the per-user suit daemon and starts the daemon when it is not running.

	Registration is a small JSON record in suit's registry directory, written atomically. It never blocks
	on suit and never throws: if suit is down the record waits for it, and if the directory cannot be
	written the process simply goes unregistered. The daemon checks each record's pid against the process
	start time, so a stale record for a reused pid is discarded rather than trusted.

	`EXOSUIT_SUIT` decides whether any of this happens (see SuitMode): "on", "isolated", or "off". Any
	other value counts as "off", so a typo never reaches the user's registry.

	When it is unset, a process whose state is disposable, kept under the system temp folder, is off: that
	is how every test isolates an editor (`PRAGTICAL_PORTABLE`, `XDG_STATE_HOME`) or a workspace (its state
	directory). A real editor can land there too (a portable build unzipped under %TEMP% or /tmp), so the
	rule is visible: `resolve`, called once at startup, logs it, and the editor shows a notice.
**/
class SuitClient {
	/** Variables that hold an editor's or a workspace service's state; a temp-folder value marks a test. */
	public static final STATE_VARIABLES:Array<String> = ["PRAGTICAL_PORTABLE", "XDG_STATE_HOME", "EXOSUIT_AGENT_STATE_HOME"];

	public static inline var TEMPORARY_STATE_MESSAGE:String = "suit disabled: state folder is temporary (set EXOSUIT_SUIT=on to enable)";

	static var editorRoots:Array<String> = [];
	static var registeredKind:Null<SuitKind> = null;
	static var daemonRequested:Bool = false;
	static var resolved:Null<SuitMode> = null;
	static var offForTemporaryState:Bool = false;
	static var noticeTaken:Bool = false;

	/**
		This process's mode from its environment; `stateDir` is a workspace service's state directory, when
		it has one. A query only: it changes nothing.
	**/
	public static function mode(?stateDir:String):SuitMode {
		var states = [for (name in STATE_VARIABLES) Sys.getEnv(name)];
		states.push(stateDir);
		return modeOf(Sys.getEnv("EXOSUIT_SUIT"), Sys.getEnv("EXOSUIT_SUIT_HOME"), states);
	}

	/**
		The mode rule, for this process or one suit reads: a set `EXOSUIT_SUIT` decides (modeFor); unset, it
		is Off when any of `states` lies under the temp folder, and On otherwise.
	**/
	public static function modeOf(value:Null<String>, home:Null<String>, states:Array<Null<String>>):SuitMode {
		if (nonempty(value) != null)
			return modeFor(value, home);
		for (state in states)
			if (state != null && state.length > 0 && underTemp(state))
				return Off;
		return On;
	}

	/**
		Settles this process's mode once, at startup, before it starts any child; later calls return the
		same mode. When it is Off only because the state folder is temporary, it logs one line and sets
		`EXOSUIT_SUIT=off` in this process's environment, the one place that happens, so every child spawned
		afterwards starts with it and does not guess again. Registration, the daemon start and the relay all
		use this mode (`current`).
	**/
	public static function resolve(?stateDir:String):SuitMode {
		if (resolved != null)
			return resolved;
		var result = mode(stateDir);
		if (result == Off && nonempty(Sys.getEnv("EXOSUIT_SUIT")) == null) {
			offForTemporaryState = true;
			try {
				Sys.stderr().writeString(TEMPORARY_STATE_MESSAGE + "\n");
				Sys.stderr().flush();
			} catch (_:Dynamic) {}
			Sys.putEnv("EXOSUIT_SUIT", "off");
		}
		resolved = result;
		return result;
	}

	/** The mode `resolve` settled on, or, before it ran, the mode the environment gives. */
	public static function current():SuitMode
		return resolved != null ? resolved : mode();

	/** True when `resolve` turned suit off because the state folder is temporary. */
	public static function disabledForTemporaryState():Bool
		return offForTemporaryState;

	/** True once per process when suit is off for temporary state: the editor's cue to show its notice. */
	public static function takeTemporaryStateNotice():Bool {
		if (!offForTemporaryState || noticeTaken)
			return false;
		noticeTaken = true;
		return true;
	}

	/** The mode a process with these EXOSUIT_SUIT and EXOSUIT_SUIT_HOME values has, when the value is set. */
	public static function modeFor(value:Null<String>, home:Null<String>):SuitMode {
		return switch value {
			case null | "" | "on": On;
			case "isolated": nonempty(home) != null ? Isolated : Off;
			default: Off;
		};
	}

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

	/** Registers the editor and starts suit. Call once at editor startup. */
	public static function announceEditor():Void {
		resolve();
		writeRecord(SuitKind.Editor, null);
		ensureDaemon();
	}

	/** Records that this editor uses a workspace root, so that workspace's services are not shown as orphaned. */
	public static function editorUsesRoot(root:Null<String>):Void {
		if (root == null || root.length == 0 || editorRoots.indexOf(root) >= 0)
			return;
		editorRoots.push(root);
		if (registeredKind == SuitKind.Editor)
			writeRecord(SuitKind.Editor, null);
	}

	/**
		Registers a workspace manager or daemon. It belongs to every editor that uses its root, not to the
		editor that happened to start it, so it is not passed any editor's pid.
	**/
	public static function registerWorkspaceService(kind:SuitKind, workspace:SuitWorkspace):Void
		writeRecord(kind, workspace);

	/** Removes this process's record on a clean exit. Suit also prunes records of processes that are gone. */
	public static function unregister():Void {
		if (registeredKind == null)
			return;
		try {
			var path = SuitRecords.path(SuitPaths.registry(), Sys.getPid());
			if (FileSystem.exists(path))
				FileSystem.deleteFile(path);
			registeredKind = null;
		} catch (_:Dynamic) {}
	}

	static function writeRecord(kind:SuitKind, workspace:Null<SuitWorkspace>):Void {
		if (resolve(workspace == null ? null : workspace.stateDir) == Off)
			return;
		try {
			if (!SuitPaths.prepare())
				return;
			var record = SuitRecords.create(Sys.getPid(), kind);
			if (kind == SuitKind.Editor)
				record.roots = editorRoots.copy();
			if (workspace != null) {
				record.root = workspace.root;
				record.stateDir = workspace.stateDir;
				record.generation = workspace.generation;
			}
			SuitRecords.write(SuitPaths.registry(), record);
			registeredKind = kind;
		} catch (_:Dynamic) {}
	}

	/**
		Starts the suit daemon, detached, unless EXOSUIT_SUIT is off, `EXOSUIT_SUIT_AUTOSTART=0` is set, or
		suit is not installed. A second daemon exits at once when one already holds the lock, so this need
		not check.
	**/
	public static function ensureDaemon():Void {
		if (daemonRequested || current() == Off || Sys.getEnv("EXOSUIT_SUIT_AUTOSTART") == "0")
			return;
		daemonRequested = true;
		try {
			var launcher = findLauncher();
			if (launcher != null)
				startDaemon(launcher);
		} catch (_:Dynamic) {}
	}

	/** Spawns `hl <launcher> daemon`, detached, with suit's native libraries on the library path. */
	public static function startDaemon(launcher:String):Void {
		var child = sys.io.Process.spawn(Sys.executablePath(), [launcher, "daemon"], Path.directory(launcher), [libraryVariable()],
			[nativePath(launcher)], true);
		child.close();
	}

	/** The suit bytecode: `EXOSUIT_SUIT_LAUNCHER`, a source build's suit/build/host/main.hl, or a bundle's tools/exosuit-suit.hl. */
	public static function findLauncher():Null<String> {
		var configured = nonempty(Sys.getEnv("EXOSUIT_SUIT_LAUNCHER"));
		if (configured != null)
			return FileSystem.exists(configured) ? FileSystem.fullPath(configured) : null;
		var starts:Array<String> = [];
		try starts.push(Path.directory(FileSystem.fullPath(Sys.programPath()))) catch (_:Dynamic) {}
		try starts.push(FileSystem.fullPath(Sys.getCwd())) catch (_:Dynamic) {}
		for (start in starts) {
			var directory = start;
			for (_ in 0...10) {
				for (candidate in [Path.join([directory, "suit", "build", "host", "main.hl"]), Path.join([directory, "tools", "exosuit-suit.hl"])])
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
		The library path suit runs with. This rule is shared with `library_path` in scripts/suit.py, which
		starts suit from a source tree; keep the two in the same order:

		1. every directory under `<launcher dir>/native` (suit's own native packages)
		2. `lib` beside the launcher's directory (a bundle keeps tools/ and lib/ side by side)
		3. the directory of the HashLink runtime that runs suit
		4. `out` and `.tools/hashlink` under the Haxeon checkout (`HAXEON_HOME`; scripts/suit.py uses `HAXEON_ROOT`)
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
		if (haxeonHome != null)
			for (path in [Path.join([haxeonHome, "out"]), Path.join([haxeonHome, ".tools", "hashlink"])])
				if (FileSystem.exists(path))
					directories.push(path);
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
