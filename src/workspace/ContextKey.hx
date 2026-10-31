package workspace;

/**
	A context is one group of one workspace of one machine: `machine/workspace/group`. The workspace's root group
	has an empty group segment. Ids are escaped so a slash inside one never moves a boundary. Keys saved before
	Phase 7 are `workspace:<id>` and `group:<id>`; `migrate` maps them.
**/
class ContextKey {
	public static inline final DEFAULT_MACHINE = "local";
	static function escape(id:String):String return StringTools.replace(StringTools.replace(id, "%", "%25"), "/", "%2F");
	static function unescape(id:String):String return StringTools.replace(StringTools.replace(id, "%2F", "/"), "%25", "%");
	public static function make(machine:String, workspace:String, group:String):String
		return escape(machine) + "/" + escape(workspace) + "/" + escape(group);
	public static function isScoped(key:String):Bool return key.split("/").length == 3 && !legacy(key);
	public static function legacy(key:String):Bool return StringTools.startsWith(key, "workspace:") || StringTools.startsWith(key, "group:");
	/** Machine, workspace and group ids, or null when `key` is not a scoped key. */
	public static function parse(key:String):Null<{machine:String, workspace:String, group:String}> {
		if (legacy(key)) return null;
		var parts = key.split("/");
		if (parts.length != 3) return null;
		return {machine: unescape(parts[0]), workspace: unescape(parts[1]), group: unescape(parts[2])};
	}
	/** A saved key in the current scheme. Old group keys carry no workspace, so they join `workspace`, the one open at restore. */
	public static function migrate(key:String, machine:String, workspace:String):String {
		if (StringTools.startsWith(key, "workspace:")) return make(machine, key.substr(10), "");
		if (StringTools.startsWith(key, "group:")) return make(machine, workspace, key.substr(6));
		return key;
	}
	/** The same key under another workspace id: a workspace given its real id after groups were keyed. */
	public static function withWorkspace(key:String, workspace:String):String {
		var parsed = parse(key);
		return parsed == null ? key : make(parsed.machine, workspace, parsed.group);
	}
	/** The same key on another machine id; used once the catalog replaces the placeholder machine. */
	public static function withMachine(key:String, machine:String):String {
		var parsed = parse(key);
		return parsed == null ? key : make(machine, parsed.workspace, parsed.group);
	}
}
