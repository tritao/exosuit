package suit.remote;

import haxe.Json;
import sys.FileSystem;
import sys.io.AtomicFile;
import sys.io.File;
import suit.SuitRecord.SuitRecords;

/**
	The relay id this machine has on each relay it has used (`machine-relay-ids.json` in suit's home:
	`{"version": 1, "relays": {"<origin>": "<32 hex digits>"}}`). Turning remote access off deletes machine-relay.json
	but keeps this file, so turning it on again with the same relay keeps the id its devices are paired under.

	Each relay gets its own id, derived from a Noise key made for it (`MachineKeys.relayId`), not the catalog id: the
	catalog id is in every invitation, and a relay registers ids first come, first served. A relay this machine used
	before that keeps the catalog id (`choose`), so existing pairings go on working.
**/
class MachineRelayIds {
	public static inline final VERSION = 1;
	static inline final MAX_BYTES = 65536;
	static inline final MAX_RELAYS = 64;

	final file:String;

	public function new(file:String)
		this.file = file;

	/** The id remembered for this relay origin (canonical, as RelayMachineEndpoint gives it), or null. */
	public function remembered(origin:String):Null<String> {
		var id = read().get(origin);
		return id != null && valid(id) ? id : null;
	}

	/** Remembers the id for the origin; nothing is written when it is already remembered. */
	public function remember(origin:String, id:String):Void {
		if (!valid(id))
			throw "A relay id is 32 hex digits";
		var relays = read();
		if (relays.get(origin) == id)
			return;
		relays.set(origin, id);
		var keys = [for (key in relays.keys()) key];
		if (keys.length > MAX_RELAYS)
			throw "Too many relays remembered in machine-relay-ids.json";
		keys.sort(function(a, b) return a < b ? -1 : a > b ? 1 : 0);
		var object:Dynamic = {};
		for (key in keys)
			Reflect.setField(object, key, relays.get(key));
		AtomicFile.write(file, Json.stringify({version: VERSION, relays: object}) + "\n");
	}

	/**
		The relay id to use with a relay: the remembered one; else `legacy` (the catalog id's hex) when this machine already
		holds a bearer for the relay under it (`hasBearer`), since its devices are paired under that id; else `fresh()`, a
		new id (which also makes the Noise key it is derived from).
	**/
	public function choose(origin:String, legacy:Null<String>, hasBearer:String->Bool, fresh:Void->String):String {
		var known = remembered(origin);
		if (known != null)
			return known;
		if (legacy != null && valid(legacy) && hasBearer(legacy))
			return legacy;
		var made = fresh();
		if (!valid(made))
			throw "A relay id is 32 hex digits";
		return made;
	}

	public static function valid(id:Null<String>):Bool
		return id != null && ~/^[0-9a-f]{32}$/.match(id);

	/** The file's relays; a missing, oversized or unreadable file counts as empty (ids then come from `choose`). */
	function read():Map<String, String> {
		var result = new Map<String, String>();
		if (!FileSystem.exists(file))
			return result;
		try {
			var info = FileSystem.metadata(file);
			if (info == null || info.size > MAX_BYTES)
				return result;
			var value:Dynamic = Json.parse(File.getContent(file));
			if (SuitRecords.intField(value, "version") != VERSION)
				return result;
			var relays:Dynamic = Reflect.field(value, "relays");
			if (relays == null || Std.isOfType(relays, String) || Std.isOfType(relays, Array))
				return result;
			for (origin in Reflect.fields(relays)) {
				var id = SuitRecords.stringField(relays, origin);
				if (valid(id))
					result.set(origin, id);
			}
		} catch (_:Dynamic) {}
		return result;
	}
}
