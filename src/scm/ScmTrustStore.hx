package scm;

import haxe.Json;
import sys.FileSystem;
import sys.io.AtomicFile;
import sys.io.File;

/** Local-only persistent trust decisions for Git worktree roots. */
class ScmTrustStore {
	final path:String;
	final trusted:Map<String, Bool> = [];
	/** Resolving a path costs a file-system call, and the app asks about each repository on every poll. */
	final keys:Map<String, String> = [];

	public function new(path:String) {
		if (path == null || path.length == 0) throw "SCM trust store requires a path";
		this.path = path;
		load();
	}

	public function isTrusted(root:String):Bool return trusted.exists(key(root));

	public function trust(root:String):Void {
		var value = key(root);
		if (trusted.exists(value)) return;
		trusted.set(value, true);
		save();
	}

	public function revoke(root:String):Void {
		var value = key(root);
		if (!trusted.exists(value)) return;
		trusted.remove(value);
		save();
	}

	function load():Void {
		if (!FileSystem.exists(path)) return;
		try {
			var value:Dynamic = Json.parse(File.getContent(path));
			if (Reflect.field(value, "version") != 1) return;
			var roots:Dynamic = Reflect.field(value, "roots");
			if (!Std.isOfType(roots, Array)) return;
			for (root in (cast roots:Array<Dynamic>)) if (Std.isOfType(root, String)) trusted.set(key(root), true);
		} catch (_:Dynamic) {
			// A malformed local trust file must fail closed.
		}
	}

	function save():Void {
		var roots = [for (root in trusted.keys()) root];
		roots.sort(Reflect.compare);
		var separator = path.lastIndexOf("/");
		if (separator > 0) createParents(path.substring(0, separator));
		AtomicFile.write(path, Json.stringify({version: 1, roots: roots}));
	}

	static function createParents(path:String):Void {
		if (FileSystem.exists(path)) return;
		var separator = path.lastIndexOf("/");
		if (separator > 2) createParents(path.substring(0, separator));
		FileSystem.createDirectory(path);
	}

	/** Drops the remembered path resolutions, for when a path may lead somewhere else now. */
	public function forgetKeys():Void keys.clear();

	function key(root:String):String {
		var known = keys.get(root);
		if (known != null) return known;
		var value = resolveKey(root);
		keys.set(root, value);
		return value;
	}

	static function resolveKey(root:String):String {
		var value = StringTools.replace(FileSystem.fullPath(root), "\\", "/");
		while (value.length > 1 && StringTools.endsWith(value, "/")) value = value.substring(0, value.length - 1);
		return Sys.systemName() == "Windows" ? value.toLowerCase() : value;
	}
}
