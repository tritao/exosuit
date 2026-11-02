package session;

import haxe.crypto.Sha256;
import sys.FileSystem;
import sys.io.File;

/** One saved context: its key and the layout lines the workbench host restores it from. */
class ContextSnapshot {
	public final key:String;
	public final lines:Array<String>;
	public final written:Float;
	public function new(key:String, lines:Array<String>, written:Float) {
		this.key = key; this.lines = lines; this.written = written;
	}
}

/**
	One file per context (`machine/workspace/group`) in a folder beside session.conf, each written atomically.
	A window writes only the contexts whose content changed since it last read or wrote them, so two windows never
	overwrite each other's other groups, and the most recent writer of a group wins for that group. The window-level
	chrome stays in session.conf.

	File name: `<readable prefix>-<sha256 of the key>.json`. The key itself is inside the file, so the name only has to be
	stable, filesystem-safe on every platform and case-insensitive-safe.
**/
class ContextSnapshotStore {
	public static inline final VERSION = 1;
	public static inline final MAX_LINES = 20000;
	public final folder:String;
	/** Per key, the encoded lines this window last read or wrote; `sync` writes only what differs. */
	final known:Map<String, String> = [];

	public function new(folder:String) this.folder = folder;

	public static function fileName(key:String):String {
		var prefix = new StringBuf();
		for (index in 0...key.length) {
			if (prefix.length >= 40) break;
			var code = key.charCodeAt(index);
			var plain = code >= 97 && code <= 122 || code >= 65 && code <= 90 || code >= 48 && code <= 57 || code == 45;
			prefix.addChar(plain ? code : 95);
		}
		return prefix.toString() + "-" + Sha256.encode(key).substr(0, 16) + ".json";
	}

	public function pathFor(key:String):String return folder + "/" + fileName(key);

	static function encodeLines(lines:Array<String>):String return lines.join("\n");

	/** Writes `lines` for `key` now, whether or not they changed. */
	public function write(key:String, lines:Array<String>, ?written:Float):Bool {
		if (key.length == 0 || !ensureFolder()) return false;
		try {
			var text = haxe.Json.stringify({version: VERSION, key: key, written: written == null ? Date.now().getTime() : written, layout: lines});
			sys.io.AtomicFile.write(pathFor(key), text);
			known.set(key, encodeLines(lines));
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}

	public function delete(key:String):Void {
		known.remove(key);
		var path = pathFor(key);
		try if (FileSystem.exists(path)) FileSystem.deleteFile(path) catch (_:Dynamic) {}
	}

	/**
		Brings the folder in line with this window's contexts: writes the ones that changed here, deletes the ones
		this window knew and no longer has, unless another window rewrote the file since. Contexts other windows wrote and this one never saw are left alone.
		Returns how many files were written or deleted.
	**/
	public function sync(contexts:Map<String, Array<String>>):Int {
		var changes = 0;
		for (key in contexts.keys()) {
			var lines = contexts.get(key);
			if (lines == null || known.get(key) == encodeLines(lines)) continue;
			if (write(key, lines)) changes++;
		}
		for (key in [for (k in known.keys()) k]) if (!contexts.exists(key)) {
			// Compare and delete: another window may have rewritten the file since this one read or wrote it.
			var current = readFile(pathFor(key));
			if (current != null && encodeLines(current.lines) != known.get(key)) known.remove(key);
			else { delete(key); changes++; }
		}
		return changes;
	}

	public function hasFiles():Bool {
		if (!FileSystem.exists(folder) || !FileSystem.isDirectory(folder)) return false;
		for (name in FileSystem.readDirectory(folder)) if (StringTools.endsWith(name, ".json")) return true;
		return false;
	}

	/** Every valid snapshot in the folder. A damaged file is skipped and left where it is. */
	public function readAll():Array<ContextSnapshot> {
		var result:Array<ContextSnapshot> = [];
		if (!FileSystem.exists(folder) || !FileSystem.isDirectory(folder)) return result;
		var names = FileSystem.readDirectory(folder);
		names.sort(Reflect.compare);
		for (name in names) {
			if (!StringTools.endsWith(name, ".json")) continue;
			var snapshot = readFile(folder + "/" + name);
			if (snapshot == null) continue;
			known.set(snapshot.key, encodeLines(snapshot.lines));
			result.push(snapshot);
		}
		return result;
	}

	static function readFile(path:String):Null<ContextSnapshot> {
		try {
			if (FileSystem.isDirectory(path)) return null;
			var data:Dynamic = haxe.Json.parse(File.getContent(path));
			if (data == null || data.version != VERSION || !Std.isOfType(data.key, String) || !Std.isOfType(data.layout, Array)) return null;
			var key:String = data.key, raw:Array<Dynamic> = data.layout;
			if (key.length == 0 || key.length > 4096 || raw.length > MAX_LINES) return null;
			var lines:Array<String> = [], dock = false, pane = false;
			for (entry in raw) {
				if (!Std.isOfType(entry, String)) return null;
				var line:String = entry;
				if (StringTools.startsWith(line, "Z\t") || !WorkspaceSession.validLayout(line)) return null;
				if (StringTools.startsWith(line, "D\tdock\t1\t")) dock = true;
				if (StringTools.startsWith(line, "P\t")) pane = true;
				lines.push(line);
			}
			if (!dock || !pane) return null;
			var written:Float = Std.isOfType(data.written, Float) ? data.written : 0;
			return new ContextSnapshot(key, lines, written);
		} catch (_:Dynamic) {
			return null;
		}
	}

	function ensureFolder():Bool {
		try {
			if (!FileSystem.exists(folder)) createDirectories(folder);
			return FileSystem.exists(folder) && FileSystem.isDirectory(folder);
		} catch (_:Dynamic) {
			return false;
		}
	}

	static function createDirectories(path:String):Void {
		var separator = path.lastIndexOf("/");
		if (separator > 0 && !FileSystem.exists(path.substring(0, separator))) createDirectories(path.substring(0, separator));
		FileSystem.createDirectory(path);
	}
}
