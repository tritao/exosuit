package suit;

import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;

/**
	Registers this process with the per-user suit daemon and starts the daemon when it is not running.

	Registration is a small JSON record in suit's registry directory, written atomically. It never blocks
	on suit and never throws: if suit is down the record waits for it, and if the directory cannot be
	written the process simply goes unregistered (suit's scan still finds exosuit processes it knows).
	The daemon checks each record's pid against the process start time, so a stale record for a reused
	pid is discarded rather than trusted.

	Spawned services inherit `EXOSUIT_SUIT_OWNER`, the pid of the editor that started them, so suit can
	tell which editor a background process belongs to and when it has been orphaned.
**/
class SuitClient {
	public static inline var OWNER_VARIABLE:String = "EXOSUIT_SUIT_OWNER";

	static var editorRoots:Array<String> = [];
	static var registeredKind:Null<String> = null;
	static var daemonRequested:Bool = false;

	/** Records this process as `kind`. `details` fields (root, stateDir, generation, label, roots) are copied. */
	public static function register(kind:String, ?details:Dynamic):Void {
		try {
			var record:Dynamic = {
				version: 1,
				pid: Sys.getPid(),
				kind: kind,
				registeredAt: Date.now().getTime()
			};
			var owner = Std.parseInt(nonempty(Sys.getEnv(OWNER_VARIABLE)));
			if (owner != null && owner > 0 && owner != Sys.getPid())
				Reflect.setField(record, "owner", owner);
			if (details != null)
				for (field in Reflect.fields(details)) {
					var value:Dynamic = Reflect.field(details, field);
					if (value != null)
						Reflect.setField(record, field, value);
				}
			var directory = SuitPaths.registry();
			if (!FileSystem.exists(directory))
				FileSystem.createDirectory(directory);
			sys.io.AtomicFile.write(Path.join([directory, Sys.getPid() + ".json"]), Json.stringify(record) + "\n");
			registeredKind = kind;
		} catch (_:Dynamic) {}
	}

	/** Removes this process's record on a clean exit. Suit also prunes records of processes that are gone. */
	public static function unregister():Void {
		try {
			var path = Path.join([SuitPaths.registry(), Sys.getPid() + ".json"]);
			if (FileSystem.exists(path))
				FileSystem.deleteFile(path);
			registeredKind = null;
		} catch (_:Dynamic) {}
	}

	/** Registers the editor and starts suit. Call once at editor startup. */
	public static function announceEditor():Void {
		register("editor", {roots: editorRoots.copy()});
		ensureDaemon();
	}

	/** Records that this editor uses a workspace root, so its services are not shown as orphaned. */
	public static function editorUsesRoot(root:Null<String>):Void {
		if (root == null || root.length == 0 || editorRoots.indexOf(root) >= 0)
			return;
		editorRoots.push(root);
		if (registeredKind == "editor")
			register("editor", {roots: editorRoots.copy()});
	}

	/** Environment for a service this editor spawns: it names the editor as the service's owner. */
	public static function ownerValue():String
		return Std.string(Sys.getPid());

	/**
		Starts the suit daemon, detached, unless it is disabled with `EXOSUIT_SUIT_AUTOSTART=0` or not
		installed. A second daemon exits at once when one already holds the lock, so this need not check.
	**/
	public static function ensureDaemon():Void {
		if (daemonRequested || Sys.getEnv("EXOSUIT_SUIT_AUTOSTART") == "0")
			return;
		daemonRequested = true;
		try {
			var launcher = findLauncher();
			if (launcher == null)
				return;
			var keys = [libraryVariable()];
			var values = [nativePath(launcher)];
			var child = sys.io.Process.spawn(Sys.executablePath(), [launcher, "daemon"], Path.directory(launcher), keys, values, true);
			child.close();
		} catch (_:Dynamic) {}
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

	/** PATH for the daemon: its native libraries, then the HashLink runtime, then the inherited PATH. */
	public static function nativePath(launcher:String):String {
		var directories:Array<String> = [];
		var nativeRoot = Path.join([Path.directory(launcher), "native"]);
		if (FileSystem.exists(nativeRoot) && FileSystem.isDirectory(nativeRoot))
			for (entry in FileSystem.readDirectory(nativeRoot)) {
				var path = Path.join([nativeRoot, entry]);
				if (FileSystem.isDirectory(path))
					directories.push(path);
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
