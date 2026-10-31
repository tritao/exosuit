package workspace;

import sys.FileSystem;

typedef FolderSelection = {folders:Array<String>, skipped:Array<String>}

/** The rules for the folders a workspace service is asked to serve. */
class WorkspaceFolders {
	public static inline final LIMIT = 16;

	/** Whether `path` names a place on its own: `/x`, `\x`, or `C:\x`. */
	public static function absolute(path:Null<String>):Bool {
		if (path == null || path.length == 0) return false;
		var first = path.charAt(0);
		if (first == "/" || first == "\\") return true;
		if (path.length < 3 || path.charAt(1) != ":") return false;
		var letter = path.charCodeAt(0);
		var separator = path.charAt(2);
		var isLetter = letter >= "a".code && letter <= "z".code || letter >= "A".code && letter <= "Z".code;
		return isLetter && (separator == "/" || separator == "\\");
	}

	/**
		The folders a service serves out of `requested`, in order, as the file system spells them, and a line for each
		that was left out and why: a relative path, one that is not a directory, one inside (or holding) a folder
		listed before it, or one past LIMIT. The same folder twice is kept once. Never throws for a bad entry, so one
		bad folder cannot stop the others from being served. Pure of side effects.
	**/
	public static function select(requested:Array<String>):FolderSelection {
		if (requested == null) throw "Invalid folder list";
		var folders:Array<String> = [], skipped:Array<String> = [];
		for (folder in requested) {
			if (!absolute(folder)) { skipped.push(folder + ": must be an absolute path"); continue; }
			if (folders.length >= LIMIT) { skipped.push(folder + ": a workspace can have at most " + LIMIT + " folders"); continue; }
			if (!FileSystem.exists(folder) || !FileSystem.isDirectory(folder)) { skipped.push(folder + ": is not available"); continue; }
			var full = FileSystem.fullPath(folder);
			var reason:Null<String> = null, duplicate = false;
			for (known in folders)
				if (PathKey.same(known, full)) duplicate = true;
				else if (PathKey.within(known, full)) reason = "is inside " + known;
				else if (PathKey.within(full, known)) reason = "holds " + known;
			if (duplicate) continue;
			if (reason != null) { skipped.push(folder + ": " + reason + "; attach one of them"); continue; }
			folders.push(full);
		}
		return {folders: folders, skipped: skipped};
	}
}
