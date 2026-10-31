package workspace.runtime;

import sys.FileSystem;
import workspace.PathKey;

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
		The folders as the file system spells them, in order, or a thrown message naming the first fault: more than
		LIMIT folders (checked before the file system is touched), a relative path, a path that is not a directory, or a
		folder inside another. The same folder twice is kept once. Nothing is changed.
	**/
	public static function validate(requested:Array<String>):Array<String> {
		if (requested == null) throw "Invalid folder list";
		if (requested.length > LIMIT) throw "A workspace can have at most " + LIMIT + " folders";
		for (folder in requested)
			if (!absolute(folder)) throw "Folder must be an absolute path: " + folder;
		var result:Array<String> = [];
		for (folder in requested) {
			if (!FileSystem.exists(folder) || !FileSystem.isDirectory(folder)) throw "Folder is not available: " + folder;
			var full = FileSystem.fullPath(folder);
			if (Lambda.exists(result, function(known) return PathKey.same(known, full))) continue;
			for (known in result)
				if (PathKey.within(known, full)) throw full + " is inside " + known + "; attach one of them";
				else if (PathKey.within(full, known)) throw known + " is inside " + full + "; attach one of them";
			result.push(full);
		}
		return result;
	}
}
