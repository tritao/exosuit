package workspace;

/**
	Comparable spellings of file-system paths, as written: no file-system calls, so a deleted folder still compares.
	Separators compare alike, a trailing separator is ignored except on a root (`/`, `C:/`), and case is ignored on
	Windows. Callers that need symlinks or `..` resolved normalize through the file system first.
**/
class PathKey {
	public static final IGNORE_CASE:Bool = Sys.systemName() == "Windows";

	/** `/`-separated, without a trailing separator unless it is a root, lowercased when case is ignored. */
	public static function of(path:String, ?ignoreCase:Bool):String {
		var value = trim(StringTools.replace(path, "\\", "/"));
		return (ignoreCase == null ? IGNORE_CASE : ignoreCase) ? value.toLowerCase() : value;
	}

	public static function same(left:String, right:String, ?ignoreCase:Bool):Bool
		return of(left, ignoreCase) == of(right, ignoreCase);

	/** Whether `child` is `parent` or inside it. */
	public static function within(parent:String, child:String, ?ignoreCase:Bool):Bool
		return relative(parent, child, ignoreCase) != null;

	/**
		`child` relative to `parent` in `child`'s own spelling with `/` separators: `""` for the folder itself, null when
		`child` is outside it.
	**/
	public static function relative(parent:String, child:String, ?ignoreCase:Bool):Null<String> {
		var base = of(parent, ignoreCase), full = of(child, ignoreCase);
		if (full == base) return "";
		var prefix = StringTools.endsWith(base, "/") ? base : base + "/";
		if (!StringTools.startsWith(full, prefix)) return null;
		// Lowercasing keeps every index, so the prefix length also holds in the original spelling.
		return trim(StringTools.replace(child, "\\", "/")).substring(prefix.length);
	}

	/** Whether a path is written the Windows way (a drive letter or backslashes), e.g. one a remote service reported. */
	public static function windowsStyle(path:String):Bool
		return path.indexOf("\\") >= 0 || path.length >= 2 && path.charAt(1) == ":" && isLetter(path.charCodeAt(0));

	static function trim(value:String):String {
		while (value.length > 1 && StringTools.endsWith(value, "/") && !isDriveRoot(value)) value = value.substring(0, value.length - 1);
		return value;
	}

	static function isDriveRoot(value:String):Bool return value.length == 3 && value.charAt(1) == ":" && isLetter(value.charCodeAt(0));

	static function isLetter(code:Null<Int>):Bool return code != null && (code >= 65 && code <= 90 || code >= 97 && code <= 122);
}
