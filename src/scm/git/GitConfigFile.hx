package scm.git;

/** Reads single values from a Git configuration file's text without running Git. */
class GitConfigFile {
	/**
		The last `key` in a plain `[section]` as a Git boolean (true/yes/on/1, false/no/off/0, or a bare key for true),
		or null when it is absent or not a boolean. Section and key names ignore case, as in Git.
	**/
	public static function boolean(text:String, section:String, key:String):Null<Bool> {
		var current = "", wantedSection = section.toLowerCase(), wantedKey = key.toLowerCase();
		var result:Null<Bool> = null;
		for (raw in text.split("\n")) {
			var line = StringTools.trim(raw);
			if (line == "" || line.charAt(0) == "#" || line.charAt(0) == ";") continue;
			if (line.charAt(0) == "[") {
				var end = line.indexOf("]");
				current = end < 0 ? "" : StringTools.trim(line.substring(1, end)).toLowerCase();
				continue;
			}
			var equals = line.indexOf("=");
			var name = StringTools.trim(equals < 0 ? line : line.substring(0, equals)).toLowerCase();
			if (current != wantedSection || name != wantedKey) continue;
			var value = equals < 0 ? "true" : line.substring(equals + 1);
			for (comment in ["#", ";"]) { var at = value.indexOf(comment); if (at >= 0) value = value.substring(0, at); }
			value = StringTools.trim(value).toLowerCase();
			if (value == "true" || value == "yes" || value == "on" || value == "1") result = true;
			else if (value == "false" || value == "no" || value == "off" || value == "0" || value == "") result = false;
		}
		return result;
	}
}
