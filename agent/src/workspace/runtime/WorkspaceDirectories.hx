package workspace.runtime;

import sys.FileSystem;
import haxe.io.Path;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;

/**
 * Resolve directories on the owning machine, including symlink targets. Group and session directories may be any
 * existing folder, inside the workspace root or not; a relative value is taken from the workspace root.
 */
class WorkspaceDirectories {
	public final root:String;

	public function new(root:String) {
		this.root = FileSystem.fullPath(root);
		if (!FileSystem.isDirectory(this.root)) throw "Workspace root is not a directory";
	}

	/** The machine's full spelling of an existing directory, or null. */
	public function resolve(value:String):Null<String> {
		try {
			if (value == null || value.length == 0 || value.length > 1024)
				return null;
			var result = FileSystem.fullPath(Path.isAbsolute(value) ? value : Path.join([root, value]));
			if (result == null || !Path.isAbsolute(result) || !FileSystem.isDirectory(result))
				return null;
			return result;
		} catch (_:Dynamic)
			return null;
	}

	/** Whether a persisted session directory is well formed. It need not exist any more; launching checks that. */
	public static function persisted(path:Null<String>):Bool
		return path != null && path.length > 0 && path.length <= 1024 && Path.isAbsolute(path);

	/** The resolved directory for new work in `group`: its own, else the nearest ancestor's, else the root. */
	public function forGroup(groups:Array<WorkspaceGroup>, group:String):Null<String> {
		var map:Map<String, WorkspaceGroup> = [];
		for (g in groups) map.set(g.id, g);
		var current = map.get(group);
		if (current == null) return null;
		var seen:Map<String, Bool> = [];
		while (current != null) {
			if (seen.exists(current.id)) return null;
			seen.set(current.id, true);
			if (current.cwd != null) return resolve(current.cwd);
			current = current.parent == null ? null : map.get(current.parent);
		}
		return root;
	}

	/** Whether `path` is `root` or below it. Full paths on Windows use `\` and ignore case. */
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
