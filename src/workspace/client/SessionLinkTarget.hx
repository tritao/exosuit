package workspace.client;

/** Parses explicit Markdown links; local targets never go through the OS shell. */
class SessionLinkTarget {
  public final path:String;
  /** Zero based, or -1 when the link has no location. */
  public final line:Int;
  public final column:Int;

  function new(path:String, line:Int, column:Int) {
    this.path = path; this.line = line; this.column = column;
  }

  public static function external(value:String):Bool
    return value != null && ~/^(https?:\/\/|mailto:)[^\s<>]+$/i.match(value);

  public static function parse(value:String):Null<SessionLinkTarget> {
    if (value == null || value.length == 0 || value != StringTools.trim(value)
      || ~/[\x00-\x1f<>]/.match(value) || external(value)) return null;
    var path = value, line = -1, column = 0;
    var fragment = ~/#L([1-9][0-9]*)(?:C([1-9][0-9]*))?(?:-L?[1-9][0-9]*)?$/;
    var location = ~/:([1-9][0-9]*)(?::([1-9][0-9]*))?$/;
    if (fragment.match(path)) {
      line = number(fragment.matched(1));
      if (fragment.matched(2) != null) column = number(fragment.matched(2));
      path = path.substr(0, fragment.matchedPos().pos);
    } else if (location.match(path)) {
      line = number(location.matched(1));
      if (location.matched(2) != null) column = number(location.matched(2));
      path = path.substr(0, location.matchedPos().pos);
    }
    // Accept drive paths, but reject URI schemes, network shares and fragments.
    var drive = ~/^[A-Za-z]:[\\\/]/.match(path);
    if ((!drive && path.indexOf(":") >= 0) || (drive && path.indexOf(":", 2) >= 0) || path.indexOf("#") >= 0
      || path.indexOf("?") >= 0 || StringTools.startsWith(path, "//")
      || StringTools.startsWith(path, "\\\\") || path.length == 0) return null;
    // Only explicit links reach this parser; extensionless workspace files are valid.
    return new SessionLinkTarget(path, line, column);
  }

  static function number(value:String):Int {
    var result = Std.parseInt(value);
    return result == null || result <= 0 ? 0 : result - 1;
  }

  /** Host-independent containment; drive paths are insensitive, POSIX paths are not. */
  public static function relativeWithin(root:String, path:String):Null<String> {
    var base = StringTools.replace(root, "\\", "/"), full = StringTools.replace(path, "\\", "/");
    while (base.length > 1 && StringTools.endsWith(base, "/")) base = base.substr(0, base.length - 1);
    var drive = ~/^[A-Za-z]:\//.match(base);
    var a = drive ? base.toLowerCase() : base, b = drive ? full.toLowerCase() : full;
    if (a == b) return "";
    var prefix = a == "/" ? a : a + "/";
    return StringTools.startsWith(b, prefix) ? full.substr(prefix.length) : null;
  }

  /** Lexical normalization works for host paths even when connected from another OS. */
  public function resolve(cwd:String):String {
    var normalized = StringTools.replace(path, "\\", "/");
    var absolute = StringTools.startsWith(normalized, "/") || ~/^[A-Za-z]:\//.match(normalized);
    if (!absolute) normalized = StringTools.replace(cwd, "\\", "/") + "/" + normalized;
    var parts:Array<String> = [];
    for (part in normalized.split("/")) {
      if (part == "." || part == "") continue;
      if (part == "..") {
        if (parts.length > 0 && !~/^[A-Za-z]:$/.match(parts[parts.length - 1])) parts.pop();
      } else parts.push(part);
    }
    return (StringTools.startsWith(normalized, "/") ? "/" : "") + parts.join("/");
  }
}
