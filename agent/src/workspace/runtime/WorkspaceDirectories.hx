package workspace.runtime;

import sys.FileSystem;
import haxe.io.Path;

/** Resolve authorized directories on the owning machine, including symlink targets. */
class WorkspaceDirectories {
	public final root:String;

	public function new(root:String) {
		this.root = FileSystem.fullPath(root);
		if (!FileSystem.isDirectory(this.root)) throw "Workspace root is not a directory";
	}

	public function resolve(value:String):Null<String> {
		try {
			if (value == null || value.length == 0 || value.length > 1024)
				return null;
			var result = FileSystem.fullPath(Path.isAbsolute(value) ? value : Path.join([root, value]));
			if (!contains(root, result, Sys.systemName() == "Windows") || !FileSystem.isDirectory(result))
				return null;
			return result;
		} catch (_:Dynamic)
			return null;
	}

	/** Whether `path` is `root` or below it. Full paths on Windows use `\` and ignore case. */
	public function inside(path:Null<String>):Bool
		return contains(root, path, Sys.systemName() == "Windows");

	public static function contains(root:String, path:Null<String>, windows:Bool):Bool {
		if (path == null || root.length == 0) return false;
		var base = windows ? root.toLowerCase() : root, candidate = windows ? path.toLowerCase() : path;
		if (candidate == base) return true;
		if (!StringTools.startsWith(candidate, base)) return false;
		if (separator(base.charAt(base.length - 1), windows)) return true;
		return separator(candidate.charAt(base.length), windows);
	}

	static function separator(value:String, windows:Bool):Bool
		return value == "/" || windows && value == "\\";
}
