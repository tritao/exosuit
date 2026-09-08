package session;

import sys.FileSystem;
import sys.io.File;

/** A small, versioned MRU list kept separate from restorable workspace state. */
class RecentProjects {
	public static inline final VERSION = 1;
	public static inline final LIMIT = 10;
	public final paths:Array<String> = [];
	final path:String;

	public function new(path:String) {
		this.path = path;
		load();
	}

	public function add(project:String):Void {
		var normalized = FileSystem.fullPath(project);
		paths.remove(normalized);
		paths.unshift(normalized);
		if (paths.length > LIMIT) paths.resize(LIMIT);
		save();
	}

	public function remove(project:String):Void {
		if (paths.remove(project)) save();
	}

	public function clear():Void {
		paths.resize(0);
		save();
	}

	function load():Void {
		if (path.length == 0 || !FileSystem.exists(path) || FileSystem.isDirectory(path)) return;
		try {
			var lines = File.getContent(path).split("\n");
			if (lines.length == 0 || lines[0] != "version=" + VERSION) return;
			for (index in 1...lines.length) {
				var candidate = StringTools.endsWith(lines[index], "\r") ? lines[index].substring(0, lines[index].length - 1) : lines[index];
				if (candidate.length > 0 && candidate.indexOf("\t") < 0 && FileSystem.exists(candidate) && FileSystem.isDirectory(candidate)) paths.push(candidate);
				if (paths.length >= LIMIT) break;
			}
		} catch (error:Dynamic) {}
	}

	function save():Void {
		if (path.length == 0) return;
		var separator = path.lastIndexOf("/"), parent = separator < 0 ? "" : path.substring(0, separator);
		try {
			if (parent.length > 0 && !FileSystem.exists(parent)) createParents(parent);
			sys.io.AtomicFile.write(path, "version=" + VERSION + "\n" + paths.join("\n") + (paths.length == 0 ? "" : "\n"));
		} catch (error:Dynamic) {}
	}

	static function createParents(path:String):Void {
		var separator = path.lastIndexOf("/");
		if (separator > 0) {
			var parent = path.substring(0, separator);
			if (!FileSystem.exists(parent)) createParents(parent);
		}
		if (!FileSystem.exists(path)) FileSystem.createDirectory(path);
	}
}
