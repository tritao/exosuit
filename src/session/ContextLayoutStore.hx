package session;

import haxe.crypto.Base64;
import haxe.io.Bytes;

/** Bounded optional records; a damaged context never invalidates the window session. */
class ContextLayoutStore {
	public var activeKey:Null<String>;
	public final layouts:Map<String, Array<String>> = [];
	public static inline final MAX_LAYOUTS = 100;
	public static inline final MAX_RECORD = 4194304;
	public function new() {}
	public static function key(kind:workspace.ContextKind, id:String):String return (kind == workspace.ContextKind.Group ? "group:" : "workspace:") + id;
	static function encoded(value:String):String return Base64.encode(Bytes.ofString(value));
	public static function activeLine(key:String):String return "Z\tactive\t1\t" + encoded(key);
	public static function layoutLine(key:String, lines:Array<String>):String return "Z\tcontext\t1\t" + encoded(key) + "\t" + encoded("context-layout=1\n" + lines.join("\n"));
	public static function read(lines:Array<String>):ContextLayoutStore {
		var result = new ContextLayoutStore(), count = 0;
		for (line in lines) {
			if (!StringTools.startsWith(line, "Z\t") || line.length > MAX_RECORD) continue;
			var fields = line.split("\t");
			if (fields.length < 4 || fields[2] != "1") continue;
			try {
				var key = Base64.decode(fields[3]).toString();
				if (key.length == 0 || key.length > 4096 || key.indexOf("\n") >= 0 || key.indexOf("\t") >= 0) continue;
				if (fields[1] == "active" && fields.length == 4) result.activeKey = key;
				else if (fields[1] == "context" && fields.length == 5 && count < MAX_LAYOUTS) {
					var payload = Base64.decode(fields[4]).toString().split("\n");
					if (payload.shift() != "context-layout=1" || payload.length > 20000) continue;
					var valid = true, dock = false, pane = false;
					for (entry in payload) {
						if (StringTools.startsWith(entry, "Z\t") || !WorkspaceSession.validLayout(entry)) { valid = false; break; }
						if (StringTools.startsWith(entry, "D\tdock\t1\t")) dock = true;
						if (StringTools.startsWith(entry, "P\t")) pane = true;
					}
					if (valid && dock && pane) { result.layouts.set(key, payload); count++; }
				}
			} catch (_:Dynamic) { /* Optional records fall back independently. */ }
		}
		return result;
	}
}
