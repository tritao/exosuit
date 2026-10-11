package plugin;

/** O(1) resource-decoration lookup with deterministic parent roll-up. */
class PluginResourceDecorationRegistry {
	final values:Map<String, PluginResourceDecoration> = [];
	var resolved:Map<String, PluginResourceDecoration> = [];
	public var revision(default, null):Int = 0;

	public function new() {}

	public function add(owner:String, id:String, path:String, badge:String,
			color:PluginResourceDecorationColor, tooltip:String, propagateToParents:Bool,
			priority:Int = 0):PluginResourceDecoration {
		if (owner == null || owner.length == 0 || id == null || id.length == 0 || path == null || path.length == 0)
			throw "Resource decorations require an owner, id and path";
		if (badge == null || badge.length == 0 || badge.length > 2)
			throw "Resource decoration badges must contain one or two characters";
		if (color == null) throw "Resource decorations require a theme color token";
		var key = itemKey(owner, id);
		if (values.exists(key)) throw 'resource decoration "$owner:$id" is already registered';
		var normalized = normalize(path);
		var value = new PluginResourceDecoration(owner, id, normalized, badge, color, tooltip,
			propagateToParents, priority);
		values.set(key, value);
		rebuild();
		return value;
	}

	public function find(owner:String, id:String):Null<PluginResourceDecoration>
		return values.get(itemKey(owner, id));

	public function forPath(path:String):Null<PluginResourceDecoration>
		return resolved.get(normalize(path));

	public function remove(value:PluginResourceDecoration):Bool {
		if (value == null || values.get(itemKey(value.owner, value.id)) != value) return false;
		values.remove(itemKey(value.owner, value.id));
		rebuild();
		return true;
	}

	public function removeOwner(owner:String):Void {
		var removed = false;
		for (key in [for (key in values.keys()) if (values.get(key).owner == owner) key]) {
			values.remove(key);
			removed = true;
		}
		if (removed) rebuild();
	}

	function rebuild():Void {
		resolved = [];
		for (value in values) {
			consider(value);
			if (!value.propagateToParents) continue;
			var parent = parentOf(value.path);
			while (parent != null) {
				consider(value.atParent(parent));
				parent = parentOf(parent);
			}
		}
		revision++;
	}

	function consider(candidate:PluginResourceDecoration):Void {
		var previous = resolved.get(candidate.path);
		if (previous == null || outranks(candidate, previous)) resolved.set(candidate.path, candidate);
	}

	static function outranks(a:PluginResourceDecoration, b:PluginResourceDecoration):Bool {
		if (a.priority != b.priority) return a.priority > b.priority;
		if (a.inherited != b.inherited) return !a.inherited;
		var order = Reflect.compare(a.owner + ":" + a.id, b.owner + ":" + b.id);
		if (order != 0) return order < 0;
		return Reflect.compare(a.sourcePath, b.sourcePath) < 0;
	}

	static function itemKey(owner:String, id:String):String return owner.length + ":" + owner + id;

	static function normalize(path:String):String {
		var result = StringTools.replace(path, "\\", "/");
		while (result.length > 1 && StringTools.endsWith(result, "/")) result = result.substr(0, result.length - 1);
		return result;
	}

	static function parentOf(path:String):Null<String> {
		var slash = path.lastIndexOf("/");
		if (slash < 0) return path == "." ? null : ".";
		if (slash == 0) return null;
		if (slash == 2 && path.charAt(1) == ":") return path.length == 3 ? null : path.substr(0, 3);
		return path.substr(0, slash);
	}
}
