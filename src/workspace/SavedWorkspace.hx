package workspace;

import haxe.crypto.Base64;
import haxe.io.Bytes;

/** Portable workspace identity and ordered root references; never contains file data. */
class SavedWorkspace {
	public final id:String;
	public var name:String;
	public final roots:Array<String>;
	public function new(id:String, name:String, roots:Array<String>) {
		if (id.length == 0 || StringTools.trim(name).length == 0) throw "Workspace identity and name are required";
		this.id = id; this.name = name; this.roots = [];
		for (root in roots) {
			if (!haxe.io.Path.isAbsolute(root)) throw 'Workspace root must be absolute: "' + root + '"';
			if (this.roots.indexOf(root) < 0) this.roots.push(root);
		}
	}
	public static function create(name:String, roots:Array<String>):SavedWorkspace
		return new SavedWorkspace(haxe.crypto.Sha256.encode(Std.string(Sys.time()) + ":" + Math.random()).substring(0, 24), name, roots);
	public function copy():SavedWorkspace return new SavedWorkspace(id, name, roots);
	public static function nameFromPath(path:String):String {
		var name = haxe.io.Path.withoutDirectory(path), suffix = ".exosuit-workspace";
		return StringTools.endsWith(name, suffix) ? name.substring(0, name.length - suffix.length) : name;
	}
	public function encode():String {
		var lines = ["version=1", "id=" + pack(id), "name=" + pack(name)];
		for (root in roots) lines.push("root=" + pack(root));
		return lines.join("\n") + "\n";
	}
	public static function decode(content:String):SavedWorkspace {
		var id = "", name = "", version = "", roots:Array<String> = [];
		if (content.length > 1048576) throw "Workspace record is too large";
		for (raw in content.split("\n")) {
			var line = StringTools.trim(raw), at = line.indexOf("=");
			if (at < 0) continue;
			var key = line.substring(0, at), value = line.substring(at + 1);
			if (key == "version") version = value;
			else if (key == "id") id = unpack(value);
			else if (key == "name") name = unpack(value);
			else if (key == "root") roots.push(unpack(value));
		}
		if (version != "1") throw "Unsupported workspace record version";
		return new SavedWorkspace(id, name, roots);
	}
	static function pack(value:String):String return Base64.encode(Bytes.ofString(value));
	static function unpack(value:String):String return Base64.decode(value).toString();
}
