package config;

import workspace.EditorFileSystem;

/** Indentation-only EditorConfig adapter. Other properties are left to their owners. */
class EditorConfig {
	final cache:Map<String, {until:Float, values:Map<String, String>}> = [];
	public function new() {}
	public function invalidate():Void cache.clear();
	public function resolve(path:String, fs:EditorFileSystem):Map<String, String> {
		var cached = cache.get(path), now = Sys.time();
		if (cached != null && cached.until > now) return cached.values;
		var files:Array<{directory:String, content:String}> = [], directory = haxe.io.Path.directory(path);
		while (directory.length > 0) {
			var file = fs.join(directory, ".editorconfig"), content:Null<String> = null;
			try { if (fs.exists(file) && !fs.isDirectory(file)) content = fs.read(file); } catch (_:Dynamic) {}
			if (content != null) {
				files.push({directory: directory, content: content});
				if (root(content)) break;
			}
			var parent = haxe.io.Path.directory(directory);
			if (parent == directory) break;
			directory = parent;
		}
		var values:Map<String, String> = [];
		files.reverse();
		for (file in files) apply(file.content, path.substring(file.directory.length + (StringTools.endsWith(file.directory, "/") ? 0 : 1)), values);
		cache.set(path, {until: now + 0.5, values: values});
		return values;
	}
	static function root(content:String):Bool {
		for (raw in content.split("\n")) {
			var line = StringTools.trim(raw);
			if (StringTools.startsWith(line, "[")) break;
			var at = line.indexOf("=");
			if (at > 0 && StringTools.trim(line.substring(0, at)).toLowerCase() == "root" &&
				StringTools.trim(line.substring(at + 1)).toLowerCase() == "true") return true;
		}
		return false;
	}
	public static function apply(content:String, relativePath:String, values:Map<String, String>):Void {
		var matched = false;
		for (raw in content.split("\n")) {
			var line = StringTools.trim(raw);
			if (line.length == 0 || line.charAt(0) == "#" || line.charAt(0) == ";") continue;
			if (line.charAt(0) == "[" && StringTools.endsWith(line, "]")) {
				matched = matches(line.substring(1, line.length - 1), relativePath); continue;
			}
			var at = line.indexOf("=");
			if (!matched || at < 1) continue;
			var key = StringTools.trim(line.substring(0, at)).toLowerCase(), value = StringTools.trim(line.substring(at + 1)).toLowerCase();
			if (["indent_style", "indent_size", "tab_width"].indexOf(key) < 0) continue;
			if (value == "unset") values.remove(key);
			else values.set(key, value);
		}
	}
	public static function positive(value:Null<String>):Null<Int> {
		if (value == null || !~/^[0-9]+$/.match(value)) return null;
		var number = Std.parseInt(value);
		return number != null && number > 0 && number <= 16 ? number : null;
	}
	public static function matches(pattern:String, path:String):Bool {
		if (pattern.length > 1024 || path.length > 4096) return false;
		if (StringTools.startsWith(pattern, "/")) pattern = pattern.substring(1);
		else if (pattern.indexOf("/") < 0) path = haxe.io.Path.withoutDirectory(path);
		return glob(pattern, path, new Map());
	}
	static function glob(pattern:String, path:String, memo:Map<String, Bool>):Bool {
		var key = pattern + "\n" + path, prior = memo.get(key);
		if (prior != null) return prior;
		var result = false;
		if (pattern.length == 0) result = path.length == 0;
		else {
			var c = pattern.charAt(0);
			if (c == "*") {
				var doubleStar = pattern.charAt(1) == "*", rest = pattern.substring(doubleStar ? 2 : 1);
				if (doubleStar && rest.charAt(0) == "/") result = glob(rest.substring(1), path, memo);
				var i = 0;
				while (!result) {
					if (glob(rest, path.substring(i), memo)) { result = true; break; }
					if (i == path.length || (!doubleStar && path.charAt(i) == "/")) break;
					i++;
				}
			} else if (c == "?") result = path.length > 0 && path.charAt(0) != "/" && glob(pattern.substring(1), path.substring(1), memo);
			else if (c == "\\" && pattern.length > 1) result = path.charAt(0) == pattern.charAt(1) && glob(pattern.substring(2), path.substring(1), memo);
			else if (c == "[" && pattern.indexOf("]", 1) > 0) {
				var end = pattern.indexOf("]", 1), seq = pattern.substring(1, end), negate = seq.charAt(0) == "!";
				if (negate) seq = seq.substring(1);
				result = path.length > 0 && path.charAt(0) != "/" && (seq.indexOf(path.charAt(0)) >= 0) != negate && glob(pattern.substring(end + 1), path.substring(1), memo);
			} else if (c == "{") {
				var depth = 1, end = 1;
				while (end < pattern.length && depth > 0) { if (pattern.charAt(end) == "{") depth++; if (pattern.charAt(end) == "}") depth--; if (depth > 0) end++; }
				if (depth == 0) {
					var body = pattern.substring(1, end), rest = pattern.substring(end + 1), numeric = ~/^(-?[0-9]+)\.\.(-?[0-9]+)$/;
					if (numeric.match(body)) {
						var low = Std.parseInt(numeric.matched(1)), high = Std.parseInt(numeric.matched(2));
						if (low != null && high != null && low < high) for (length in 1...path.length + 1) {
							var part = path.substring(0, length);
							if (!~/^-?[0-9]+$/.match(part)) continue;
							var n = Std.parseInt(part);
							if (n != null && n >= low && n <= high && glob(rest, path.substring(length), memo)) { result = true; break; }
						}
					} else {
						var alternatives:Array<String> = [], start = 0, nesting = 0;
						for (i in 0...body.length) { if (body.charAt(i) == "{") nesting++; if (body.charAt(i) == "}") nesting--; if (body.charAt(i) == "," && nesting == 0) { alternatives.push(body.substring(start, i)); start = i + 1; } }
						if (alternatives.length > 0) { alternatives.push(body.substring(start)); for (alt in alternatives) if (glob(alt + rest, path, memo)) { result = true; break; } }
						else result = path.charAt(0) == c && glob(pattern.substring(1), path.substring(1), memo);
					}
				} else result = path.charAt(0) == c && glob(pattern.substring(1), path.substring(1), memo);
			} else result = path.length > 0 && path.charAt(0) == c && glob(pattern.substring(1), path.substring(1), memo);
		}
		memo.set(key, result);
		return result;
	}
}
