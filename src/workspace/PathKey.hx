package workspace;

/**
	Comparable spellings of file-system paths, as written: no file-system calls, so a deleted folder still compares.
	Separators compare alike, doubled and trailing separators are ignored except on a root (`/`, `C:/`, `//server`), the
	Windows long-path prefix `\\?\` is dropped, and case is ignored on Windows. Paths compare segment by segment, so
	case mapping that changes a string's length cannot shift a match. Callers that need symlinks or `..` resolved
	normalize through the file system first.
**/
class PathKey {
	public static final IGNORE_CASE:Bool = Sys.systemName() == "Windows";

	/** `/`-separated, without doubled or trailing separators except on a root, lowercased when case is ignored. */
	public static function of(path:String, ?ignoreCase:Bool):String {
		var value = clean(path);
		return ignores(ignoreCase) ? value.toLowerCase() : value;
	}

	public static function same(left:String, right:String, ?ignoreCase:Bool):Bool
		return of(left, ignoreCase) == of(right, ignoreCase);

	/** Whether `child` is `parent` or inside it. An empty parent contains nothing. */
	public static function within(parent:String, child:String, ?ignoreCase:Bool):Bool
		return relative(parent, child, ignoreCase) != null;

	/**
		`child` relative to `parent` in `child`'s own spelling with `/` separators: `""` for the folder itself, null when
		`child` is outside it. An empty parent contains nothing but itself, and a
		drive-relative `C:` is not the drive's root `C:/`.
	**/
	public static function relative(parent:String, child:String, ?ignoreCase:Bool):Null<String> {
		var base = clean(parent), full = clean(child), fold = ignores(ignoreCase);
		if (base == "") return full == "" ? "" : null;
		// Index 0 is the root, so `C:` (the current folder on drive C) never matches `C:/`.
		var baseParts = segments(base), fullParts = segments(full);
		if (fullParts.length < baseParts.length) return null;
		for (index in 0...baseParts.length) if (!sameSegment(baseParts[index], fullParts[index], fold)) return null;
		return fullParts.slice(baseParts.length).join("/");
	}

	/** Whether a path is written the Windows way (a drive letter or backslashes), e.g. one a remote service reported. */
	public static function windowsStyle(path:String):Bool
		return path.indexOf("\\") >= 0 || path.length >= 2 && path.charAt(1) == ":" && isLetter(path.charCodeAt(0));

	static function ignores(ignoreCase:Null<Bool>):Bool return ignoreCase == null ? IGNORE_CASE : ignoreCase == true;

	static function sameSegment(left:String, right:String, fold:Bool):Bool
		return fold ? left.toLowerCase() == right.toLowerCase() : left == right;

	/** The root (`/`, `//`, `C:/`, `C:` or `""` for a relative path) followed by the path's names. */
	static function segments(value:String):Array<String> {
		var root = rootOf(value);
		var rest = value.substring(root.length);
		var names = rest == "" ? [] : rest.split("/");
		names.unshift(root);
		return names;
	}

	static function rootOf(value:String):String {
		if (StringTools.startsWith(value, "//")) return "//";
		if (StringTools.startsWith(value, "/")) return "/";
		if (value.length >= 2 && value.charAt(1) == ":" && isLetter(value.charCodeAt(0)))
			return value.length >= 3 && value.charAt(2) == "/" ? value.substring(0, 3) : value.substring(0, 2);
		return "";
	}

	static function clean(path:String):String {
		var value = StringTools.replace(path, "\\", "/");
		// Windows long paths: `\\?\C:\x` is `C:\x`, `\\?\UNC\server\share` is `\\server\share`.
		if (StringTools.startsWith(value, "//?/UNC/")) value = "//" + value.substring(8);
		else if (StringTools.startsWith(value, "//?/")) value = value.substring(4);
		var unc = StringTools.startsWith(value, "//") && !StringTools.startsWith(value, "///");
		while (value.indexOf("//") >= 0) value = StringTools.replace(value, "//", "/");
		if (unc) value = "/" + value;
		var root = rootOf(value);
		while (value.length > root.length && StringTools.endsWith(value, "/")) value = value.substring(0, value.length - 1);
		return value;
	}

	static function isLetter(code:Null<Int>):Bool return code != null && (code >= 65 && code <= 90 || code >= 97 && code <= 122);
}
