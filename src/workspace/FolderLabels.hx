package workspace;

/** Short names for a set of folders: the folder's own name, with parent names added only where two would read alike. */
class FolderLabels {
	/** One label per path, in order. Folders sharing a name get enough trailing path segments to tell them apart. */
	public static function labels(paths:Array<String>):Array<String> {
		var parts = [for (path in paths) segments(path)];
		var depth = [for (_ in paths) 1];
		for (_ in 0...32) {
			var names = [for (index in 0...paths.length) name(parts[index], depth[index])];
			var again = false;
			for (index in 0...paths.length) {
				var shared = false;
				for (other in 0...paths.length) if (other != index && names[other] == names[index]) shared = true;
				if (shared && depth[index] < parts[index].length) { depth[index]++; again = true; }
			}
			if (!again) break;
		}
		return [for (index in 0...paths.length) name(parts[index], depth[index], paths[index])];
	}

	static function segments(path:String):Array<String>
		return [for (part in StringTools.replace(path, "\\", "/").split("/")) if (part.length > 0) part];

	static function name(parts:Array<String>, depth:Int, ?fallback:String):String {
		if (parts.length == 0) return fallback == null ? "" : fallback;
		return parts.slice(Std.int(Math.max(0, parts.length - depth))).join("/");
	}
}
