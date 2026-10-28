package suit;

import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/** The workspace a service serves. Root, state directory and generation always travel together. */
typedef SuitWorkspace = {
	var root:String;
	var stateDir:String;
	var generation:Null<String>;
}

/**
	One registry record, `<pid>.json` in suit's registry. A process writes its own when it starts; suit
	writes one for a process it adopts, one found descending from a registered process, so the tie
	survives that ancestor's exit.
**/
typedef SuitRecord = {
	var pid:Int;
	var kind:SuitKind;

	/** When the record was written, in ms since the epoch. A pid that started later was reused; the record is stale. */
	var registeredAt:Float;

	/** An editor's workspace roots. */
	var roots:Array<String>;

	/** A workspace service's root, state directory and generation (from its SuitWorkspace). */
	var root:Null<String>;
	var stateDir:Null<String>;
	var generation:Null<String>;

	/** The registered process this one belongs to; set for adopted processes. */
	var owner:Null<Int>;

	/** True when suit wrote the record for a process it adopted, rather than the process itself. */
	var adopted:Bool;
}

/** Reads and writes registry records. The only code that knows the record's JSON form. */
class SuitRecords {
	public static inline var VERSION:Int = 1;

	/** Records larger than this are junk. */
	public static inline var MAX_BYTES:Int = 65536;

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
			root: record.root,
			stateDir: record.stateDir,
			generation: record.generation,
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
		var pid = intField(document, "pid"), registeredAt = floatField(document, "registeredAt");
		if (pid == null || pid <= 0 || registeredAt == null)
			return null;
		var roots:Array<String> = [];
		var listed:Dynamic = Reflect.field(document, "roots");
		if (Std.isOfType(listed, Array))
			for (value in (listed : Array<Dynamic>))
				if (Std.isOfType(value, String))
					roots.push(value);
		return {
			pid: pid,
			kind: SuitKind.SuitKinds.parse(stringField(document, "kind")),
			registeredAt: registeredAt,
			roots: roots,
			root: stringField(document, "root"),
			stateDir: stringField(document, "stateDir"),
			generation: stringField(document, "generation"),
			owner: intField(document, "owner"),
			adopted: Reflect.field(document, "adopted") == true
		};
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
