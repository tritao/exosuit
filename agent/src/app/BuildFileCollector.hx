package app;

import haxe.io.Path;
import sys.FileSystem;

/** Deterministic fingerprint inputs; canonical directory identities prevent symlink cycles. */
class BuildFileCollector {
	public final files:Array<String> = [];
	final knownFiles:Map<String, Bool> = [];
	final directories:Map<String, Bool> = [];

	public function new() {}

	public function add(path:String):Void {
		if (!FileSystem.exists(path) || FileSystem.isDirectory(path)) return;
		var canonical = FileSystem.fullPath(path);
		if (canonical == null || canonical == "") throw 'Could not resolve fingerprint input: $path';
		if (knownFiles.exists(canonical)) return;
		knownFiles.set(canonical, true);
		files.push(canonical);
	}

	/** A file found by listing a directory that `collect` already resolved: its path is canonical and a file, so no further lookups. */
	function addListed(path:String):Void {
		if (knownFiles.exists(path)) return;
		knownFiles.set(path, true);
		files.push(path);
	}

	/** Folders below a root that are walked; deeper ones are left out (only a link that loops gets there). */
	static inline final MAX_DEPTH = 48;

	/**
		Every launcher run walks about a thousand folders here, and a workspace's cold start waits for it, so the walk
		does one lookup per folder: the listing says which entries are folders, and the list is sorted once, by the
		caller. Only the root is resolved (`fullPath` looks up every part of a path, which for each folder was most of the
		walk's 0.7 s): a folder found in a resolved folder's listing is spelled as the listing names it. A folder reached
		through a link is therefore walked under the link's name, and a link that loops ends at MAX_DEPTH.
	**/
	public function collect(root:String, runtime:Bool = false):Void {
		if (!FileSystem.exists(root) || !FileSystem.isDirectory(root)) return;
		var canonical = FileSystem.fullPath(root);
		if (canonical == null || canonical == "") throw 'Could not resolve fingerprint directory: $root';
		// As Path.join spells it (forward slashes), like every path below.
		var top = Path.join([canonical, "x"]);
		var pending = [top.substr(0, top.length - 2)], depths = [0];
		while (pending.length > 0) {
			var directory = pending.pop(), popped = depths.pop();
			if (directory == null) break;
			var depth = popped == null ? 0 : popped;
			var key = (runtime ? "runtime:" : "source:") + directory;
			if (directories.exists(key)) continue;
			directories.set(key, true);
			var entries = FileSystem.readDirectoryEntries(directory);
			if (entries == null) throw 'Could not read fingerprint directory: $directory';
			var prefix = directory + "/";
			for (entry in entries) {
				var name = entry.name;
				if (name == ".git" || name == "__pycache__") continue;
				if (!runtime && (name == "build" || name == "out" || name == "test" || name == "tests"
					|| name == "bench" || name == "benchmarks" || name == "examples" || name == "docs" || name == "doc")) continue;
				if (entry.isDirectory) {
					if (depth < MAX_DEPTH) {
						pending.push(prefix + name);
						depths.push(depth + 1);
					}
					continue;
				}
				var dot = name.lastIndexOf(".");
				var extension = dot < 0 ? "" : name.substr(dot + 1).toLowerCase();
				var included = runtime
					? RUNTIME_EXTENSIONS.exists(extension) || name.toLowerCase().indexOf(".so.") >= 0 || name.toLowerCase().indexOf(".dylib.") >= 0
					: SOURCE_EXTENSIONS.exists(extension) || name == "CMakeLists.txt";
				if (included) addListed(prefix + name);
			}
		}
	}

	static final SOURCE_EXTENSIONS:Map<String, Bool> = [for (name in ["hx", "c", "h", "cpp", "json", "hxi", "hxmap", "inc", "in", "cmake", "hxml", "def", "rc"]) name => true];
	static final RUNTIME_EXTENSIONS:Map<String, Bool> = [for (name in ["hl", "hdll", "so", "dylib", "dll", "a", "lib"]) name => true];
}
