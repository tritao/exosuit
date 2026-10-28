package scm;

import workspace.PathKey;

/**
	Repository-relative folders (each ending in `/`) that a source limits its changes to, e.g. the Agents layout's
	group folder inside a larger repository. Shared by the source's checks and the provider's last check before a commit.
**/
class ScmFolderScope {
	/** The error code of a refusal; the UI words what to do about it. */
	public static inline final OUTSIDE_FOLDER:String = "outside_folder";

	/**
		Whether `path` is a plain repository-relative path: no `.` or `..` segment, no leading separator, no drive letter
		and no leading `:` (Git pathspec magic). Anything else could name a file outside the folder it starts with.
	**/
	public static function plain(path:Null<String>):Bool {
		if (path == null || path.length == 0) return false;
		var first = StringTools.fastCodeAt(path, 0);
		if (first == "/".code || first == "\\".code || first == ":".code) return false;
		if (path.length >= 2 && StringTools.fastCodeAt(path, 1) == ":".code) return false;
		var start = 0;
		for (index in 0...path.length + 1) {
			var code = index < path.length ? StringTools.fastCodeAt(path, index) : "/".code;
			if (code != "/".code && code != "\\".code) continue;
			var length = index - start;
			if (length == 1 && StringTools.fastCodeAt(path, start) == ".".code
				|| length == 2 && StringTools.fastCodeAt(path, start) == ".".code && StringTools.fastCodeAt(path, start + 1) == ".".code) return false;
			start = index + 1;
		}
		return true;
	}

	/**
		Whether a plain `path` is under one of the folders; `ignoreCase` is the repository's (Git's `core.ignorecase`).
		Git reports clean `/`-separated paths, so this compares in place without allocating, except for a folder or path
		with non-ASCII letters under a case-insensitive rule, which goes through PathKey's segment comparison.
	**/
	public static function inside(path:Null<String>, folders:Array<String>, ?ignoreCase:Bool):Bool {
		if (path == null || !plain(path)) return false;
		var fold = ignoreCase == null ? PathKey.IGNORE_CASE : ignoreCase == true;
		for (folder in folders) if (under(folder, path, fold)) return true;
		return false;
	}

	static function under(folder:String, path:String, fold:Bool):Bool {
		// `folder` ends in `/`; the path is inside when it starts with it, or is the folder itself.
		var length = folder.length - 1;
		if (length < 0 || path.length < length || path.length > length && StringTools.fastCodeAt(path, length) != "/".code) return false;
		return PathKey.sameRange(folder, 0, length, path, 0, length, fold);
	}

	/** The paths that are not inside the folders. */
	public static function outside(paths:Array<String>, folders:Array<String>, ?ignoreCase:Bool):Array<String>
		return [for (path in paths) if (!inside(path, folders, ignoreCase)) path];

	/**
		The folders a request for `requested` may act on inside `allowed`: each requested folder inside an allowed one, and
		each allowed folder inside a requested one, so a request can narrow a scope but never widen it.
	**/
	public static function intersect(requested:Array<String>, allowed:Array<String>, ?ignoreCase:Bool):Array<String> {
		var result:Array<String> = [];
		function add(folder:String):Void { if (result.indexOf(folder) < 0) result.push(folder); }
		for (folder in requested) {
			if (!plain(folder) || !StringTools.endsWith(folder, "/")) continue;
			for (scope in allowed) {
				if (inside(folder, [scope], ignoreCase)) add(folder);
				else if (inside(scope, [folder], ignoreCase)) add(scope);
			}
		}
		return result;
	}

	/** Why a commit was refused: `what` would bring in `paths` from outside the folders. */
	public static function refusal(what:String, paths:Array<String>, folders:Array<String>):String
		return what + " outside " + folders.join(", ") + " would be committed: " + paths.slice(0, 3).join(", ")
			+ (paths.length > 3 ? " and " + (paths.length - 3) + " more" : "") + ".";
}
