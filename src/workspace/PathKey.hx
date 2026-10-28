package workspace;

/**
	Comparable spellings of file-system paths, as written: no file-system calls, so a deleted folder still compares.
	Separators compare alike, doubled and trailing separators are ignored except on a root (`/`, `C:/`, `//server`), the
	Windows long-path prefixes `\\?\` and `\\?\UNC\` (any case) are dropped, and case is ignored on Windows. Paths compare
	segment by segment, so case mapping that changes a string's length cannot shift a match. Callers that need symlinks
	or `..` resolved normalize through the file system first.
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
		// The root is its own segment, so `C:` (the current folder on drive C) never matches `C:/`. Segments are compared
		// by index, without splitting, since this can run for every change in a narrowed Source Control view.
		var baseRoot = rootLength(base), fullRoot = rootLength(full);
		if (baseRoot != fullRoot || !sameRange(base, 0, baseRoot, full, 0, fullRoot, fold)) return null;
		var i = baseRoot, j = fullRoot;
		while (i < base.length) {
			if (j >= full.length) return null;
			var baseEnd = base.indexOf("/", i), fullEnd = full.indexOf("/", j);
			if (baseEnd < 0) baseEnd = base.length;
			if (fullEnd < 0) fullEnd = full.length;
			if (!sameRange(base, i, baseEnd, full, j, fullEnd, fold)) return null;
			i = baseEnd + 1;
			j = fullEnd + 1;
		}
		return j >= full.length ? "" : full.substring(j);
	}

	/** Whether a path is written the Windows way (a drive letter or backslashes), e.g. one a remote service reported. */
	public static function windowsStyle(path:String):Bool
		return path.indexOf("\\") >= 0 || path.length >= 2 && path.charAt(1) == ":" && isLetter(path.charCodeAt(0));

	static function ignores(ignoreCase:Null<Bool>):Bool return ignoreCase == null ? IGNORE_CASE : ignoreCase == true;

	/** Whether two ranges spell the same path text; ASCII folds in place, anything else through full case mapping. */
	public static function sameRange(left:String, leftStart:Int, leftEnd:Int, right:String, rightStart:Int, rightEnd:Int, fold:Bool):Bool {
		var length = leftEnd - leftStart;
		if (length == rightEnd - rightStart) {
			var ascii = true;
			for (offset in 0...length) {
				var a = StringTools.fastCodeAt(left, leftStart + offset), b = StringTools.fastCodeAt(right, rightStart + offset);
				if (a == b) continue;
				if (!fold) return false;
				if (a > 127 || b > 127) { ascii = false; break; }
				if (a >= "A".code && a <= "Z".code) a += 32;
				if (b >= "A".code && b <= "Z".code) b += 32;
				if (a != b) return false;
			}
			if (ascii) return true;
		} else if (!fold) return false;
		// Case mapping may change a segment's length (U+0130 lowercases to two code units on some targets).
		return left.substring(leftStart, leftEnd).toLowerCase() == right.substring(rightStart, rightEnd).toLowerCase();
	}

	/** The root's length: `//`, `/`, `C:/`, `C:`, or 0 for a relative path. */
	static function rootLength(value:String):Int {
		if (StringTools.startsWith(value, "//")) return 2;
		if (StringTools.startsWith(value, "/")) return 1;
		if (value.length >= 2 && value.charAt(1) == ":" && isLetter(value.charCodeAt(0)))
			return value.length >= 3 && value.charAt(2) == "/" ? 3 : 2;
		return 0;
	}

	/** Whether `clean` would return the path unchanged, so the common case allocates nothing. */
	static function alreadyClean(path:String):Bool {
		if (path.indexOf("\\") >= 0) return false;
		var unc = StringTools.startsWith(path, "//");
		if (unc && (path.length < 3 || path.charAt(2) == "/" || path.charAt(2) == "?")) return false;
		if (path.indexOf("//", unc ? 2 : 0) >= 0) return false;
		return !(path.length > rootLength(path) && StringTools.endsWith(path, "/"));
	}

	static function clean(path:String):String {
		if (alreadyClean(path)) return path;
		var value = StringTools.replace(path, "\\", "/");
		// Windows long paths: `\\?\C:\x` is `C:\x`, and `\\?\UNC\server\share`, in any case, is `\\server\share`.
		if (value.length >= 8 && value.substring(0, 8).toUpperCase() == "//?/UNC/") value = "//" + value.substring(8);
		else if (StringTools.startsWith(value, "//?/")) value = value.substring(4);
		var unc = StringTools.startsWith(value, "//") && !StringTools.startsWith(value, "///");
		while (value.indexOf("//") >= 0) value = StringTools.replace(value, "//", "/");
		if (unc) value = "/" + value;
		var root = rootLength(value);
		while (value.length > root && StringTools.endsWith(value, "/")) value = value.substring(0, value.length - 1);
		return value;
	}

	static function isLetter(code:Null<Int>):Bool return code != null && (code >= 65 && code <= 90 || code >= 97 && code <= 122);
}
