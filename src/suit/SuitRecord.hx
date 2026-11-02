package suit;

import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
	The workspace a service serves. Root, state directory and generation always travel together. `workspace` is the
	workspace's id for a service keyed by it (M19 Phase 4), else null; `root` is then its first folder or scratch folder.
**/
typedef SuitWorkspace = {
	var root:String;
	var stateDir:String;
	var generation:Null<String>;
	var workspace:Null<String>;
}

/**
	One registry record, `<pid>.json` in suit's registry. A process writes its own when it starts; suit
	writes one for a process it adopts, one found descending from a registered process, so the tie
	survives that ancestor's exit.
**/
typedef SuitRecord = {
	var pid:Int;
	var kind:SuitKind;

	/** When the record was written (SuitClock.now). A pid that started later was reused; the record is stale. */
	var registeredAt:Float;

	/** The format the record was written in: before 2, registeredAt was whole seconds (see SuitClock). */
	var version:Int;

	/** An editor's workspace roots. */
	var roots:Array<String>;

	/** The ids of the workspaces an editor uses, whose services are keyed by id. */
	var workspaces:Array<String>;

	/** A workspace service's root, state directory, generation and workspace id (from its SuitWorkspace). */
	var root:Null<String>;
	var workspace:Null<String>;
	var stateDir:Null<String>;
	var generation:Null<String>;

	/**
		An editor window's id and focused context (`machine/workspace/group`, ContextKey), so other windows can show
		"open in another window" (M19 Phase 8). Null for other kinds, and for an editor that has not focused one.
		Additive: a reader that does not know the fields ignores them.
	**/
	var window:Null<String>;
	var context:Null<String>;

	/** The registered process this one belongs to; set for adopted processes. */
	var owner:Null<Int>;

	/** True when suit wrote the record for a process it adopted, rather than the process itself. */
	var adopted:Bool;
}

/** Reads and writes registry records. The only code that knows the record's JSON form. */
class SuitRecords {
	/** 2: registeredAt has millisecond resolution. */
	public static inline var VERSION:Int = 2;

	/** Records larger than this are junk. */
	public static inline var MAX_BYTES:Int = 65536;

	/** A new record for `pid`, stamped now in the current format. */
	public static function create(pid:Int, kind:SuitKind):SuitRecord {
		return {
			pid: pid,
			kind: kind,
			registeredAt: SuitClock.now(),
			version: VERSION,
			roots: [],
			workspaces: [],
			root: null,
			workspace: null,
			stateDir: null,
			generation: null,
			window: null,
			context: null,
			owner: null,
			adopted: false
		};
	}

	public static function path(directory:String, pid:Int):String
		return Path.join([directory, pid + ".json"]);

	/** Writes `record` atomically, so readers see the old record or the new one, never a partial file. */
	public static function write(directory:String, record:SuitRecord):Void {
		var document:Dynamic = {
			version: VERSION,
			pid: record.pid,
			kind: (record.kind : String),
			registeredAt: record.registeredAt,
			roots: record.roots,
			workspaces: record.workspaces,
			root: record.root,
			workspace: record.workspace,
			stateDir: record.stateDir,
			generation: record.generation,
			window: record.window,
			context: record.context,
			owner: record.owner,
			adopted: record.adopted
		};
		sys.io.AtomicFile.write(path(directory, record.pid), Json.stringify(document) + "\n");
	}

	/** The record at `path`, or null when it is unreadable or malformed. */
	public static function read(path:String):Null<SuitRecord> {
		var document:Dynamic = null;
		try {
			var info = FileSystem.metadata(path);
			if (info == null || info.size > MAX_BYTES)
				return null;
			document = Json.parse(File.getContent(path));
		} catch (_:Dynamic) {
			return null;
		}
		var pid = intField(document, "pid"), registeredAt = floatField(document, "registeredAt"), version = intField(document, "version");
		if (pid == null || pid <= 0 || registeredAt == null)
			return null;
		return {
			pid: pid,
			kind: SuitKind.SuitKinds.parse(stringField(document, "kind")),
			registeredAt: registeredAt,
			version: version == null ? 1 : version,
			roots: strings(document, "roots"),
			workspaces: strings(document, "workspaces"),
			root: stringField(document, "root"),
			workspace: stringField(document, "workspace"),
			stateDir: stringField(document, "stateDir"),
			generation: stringField(document, "generation"),
			window: stringField(document, "window"),
			context: stringField(document, "context"),
			owner: intField(document, "owner"),
			adopted: Reflect.field(document, "adopted") == true
		};
	}

	static function strings(document:Dynamic, field:String):Array<String> {
		var result:Array<String> = [];
		var listed:Dynamic = Reflect.field(document, field);
		if (Std.isOfType(listed, Array))
			for (value in (listed : Array<Dynamic>))
				if (Std.isOfType(value, String))
					result.push(value);
		return result;
	}

	public static function stringField(value:Dynamic, field:String):Null<String> {
		if (value == null || !Reflect.isObject(value))
			return null;
		var result:Dynamic = Reflect.field(value, field);
		return Std.isOfType(result, String) && (result : String).length > 0 ? result : null;
	}

	public static function intField(value:Dynamic, field:String):Null<Int> {
		if (value == null || !Reflect.isObject(value))
			return null;
		var result:Dynamic = Reflect.field(value, field);
		if (Std.isOfType(result, Int))
			return result;
		if (Std.isOfType(result, Float) && Math.ffloor(result) == result)
			return Std.int(result);
		return null;
	}

	public static function floatField(value:Dynamic, field:String):Null<Float> {
		if (value == null || !Reflect.isObject(value))
			return null;
		var result:Dynamic = Reflect.field(value, field);
		return Std.isOfType(result, Float) || Std.isOfType(result, Int) ? (result : Float) : null;
	}
}
