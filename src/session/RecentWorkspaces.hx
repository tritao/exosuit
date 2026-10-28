package session;

import sys.FileSystem;
import sys.io.File;

/** Shared MRU index. Reload on every write so another window's entries survive. */
class RecentWorkspaces {
	public final paths:Array<String> = [];
	public var error(default, null):Null<String>;
	final path:String;
	public function new(path:String) { this.path = path; reload(); }
	public function reload():Void {
		paths.resize(0);
		error = null;
		if (path.length == 0 || !FileSystem.exists(path)) return;
		try {
			for (line in File.getContent(path).split("\n")) if (StringTools.startsWith(line, "workspace=")) {
				var entry = haxe.crypto.Base64.decode(line.substring(10)).toString();
				if (paths.indexOf(entry) < 0 && paths.length < 10) paths.push(entry);
			}
		} catch (failure:Dynamic) { error = "Could not load recent workspaces: " + Std.string(failure); }
	}
	public function add(value:String):Void {
		reload(); paths.remove(value); paths.unshift(value);
		if (paths.length > 10) paths.resize(10);
		write();
	}
	public function remove(value:String):Void {
		reload();
		if (paths.remove(value)) write();
	}
	function write():Void {
		if (path.length == 0) return;
		var parent = haxe.io.Path.directory(path);
		if (parent.length > 0 && !FileSystem.exists(parent)) FileSystem.createDirectory(parent);
		sys.io.AtomicFile.write(path, "version=1\n" + [for (entry in paths) "workspace=" + haxe.crypto.Base64.encode(haxe.io.Bytes.ofString(entry))].join("\n") + "\n");
	}
}
