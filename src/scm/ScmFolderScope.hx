package scm;

import workspace.PathKey;

/**
	Repository-relative folders (each ending in `/`) that a source limits its changes to, e.g. the Agents layout's
	group folder inside a larger repository. Shared by the source's checks and the provider's last check before a commit.
**/
class ScmFolderScope {
	/**
		Whether `path` is a plain repository-relative path: no `.` or `..` segment, no leading separator, no drive letter
		and no leading `:` (Git pathspec magic). Anything else could name a file outside the folder it starts with.
	**/
	public static function plain(path:Null<String>):Bool {
		if (path == null || path.length == 0) return false;
		var value = StringTools.replace(path, "\\", "/");
		if (StringTools.startsWith(value, "/") || StringTools.startsWith(value, ":")) return false;
		if (value.length >= 2 && value.charAt(1) == ":") return false;
		for (part in value.split("/")) if (part == "." || part == "..") return false;
		return true;
	}

	/** Whether a plain `path` is under one of the folders; `ignoreCase` is the repository's (Git's `core.ignorecase`). */
	public static function inside(path:Null<String>, folders:Array<String>, ?ignoreCase:Bool):Bool {
		if (path == null || !plain(path)) return false;
		for (folder in folders) if (PathKey.within(folder, path, ignoreCase)) return true;
		return false;
	}

	/** The paths that are not inside the folders. */
	public static function outside(paths:Array<String>, folders:Array<String>, ?ignoreCase:Bool):Array<String>
		return [for (path in paths) if (!inside(path, folders, ignoreCase)) path];

	/** Why a commit was refused: `what` would bring in `paths` from outside the folders. */
	public static function refusal(what:String, paths:Array<String>, folders:Array<String>):String
		return what + " outside " + folders.join(", ") + " would be committed: " + paths.slice(0, 3).join(", ")
			+ (paths.length > 3 ? " and " + (paths.length - 3) + " more" : "")
			+ ". Unstage them, or commit from the Editor layout's Source Control.";
}
