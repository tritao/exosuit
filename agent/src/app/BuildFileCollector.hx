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

	public function collect(root:String, runtime:Bool = false):Void {
		var pending = [root];
		while (pending.length > 0) {
			var directory = pending.pop();
			if (!FileSystem.exists(directory) || !FileSystem.isDirectory(directory)) continue;
			var canonical = FileSystem.fullPath(directory);
			if (canonical == null || canonical == "") throw 'Could not resolve fingerprint directory: $directory';
			var key = (runtime ? "runtime:" : "source:") + canonical;
			if (directories.exists(key)) continue;
			directories.set(key, true);
			var names = FileSystem.readDirectory(canonical);
			if (names == null) throw 'Could not read fingerprint directory: $canonical';
			names.sort(Reflect.compare);
			for (name in names) {
				if (name == ".git" || name == "__pycache__") continue;
				if (!runtime && (name == "build" || name == "out" || name == "test" || name == "tests"
					|| name == "bench" || name == "benchmarks" || name == "examples" || name == "docs" || name == "doc")) continue;
				var path = Path.join([canonical, name]);
				if (FileSystem.isDirectory(path)) pending.push(path);
				else {
					var dot = name.lastIndexOf(".");
					var extension = dot < 0 ? "" : name.substr(dot + 1).toLowerCase(), lower = name.toLowerCase();
					var included = runtime
						? ["hl", "hdll", "so", "dylib", "dll", "a", "lib"].contains(extension)
							|| lower.indexOf(".so.") >= 0 || lower.indexOf(".dylib.") >= 0
						: ["hx", "c", "h", "cpp", "json", "hxi", "hxmap", "inc", "in", "cmake", "hxml", "def", "rc"].contains(extension)
							|| name == "CMakeLists.txt";
					if (included) add(path);
				}
			}
		}
		files.sort(Reflect.compare);
	}
}
