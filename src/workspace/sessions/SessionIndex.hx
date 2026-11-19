package workspace.sessions;

enum abstract SessionKind(String) to String {
	var Claude = "claude";
	var Codex = "codex";
	var Terminal = "terminal";
	var Chat = "chat";
	var Other = "other";
}

enum abstract SessionState(String) to String {
	var Attention = "attention";
	var Working = "working";
	var Idle = "idle";
	var Exited = "exited";
}

/** One session or terminal of a machine, with every facet a view filters, sorts or sections by (ADR 0007). */
typedef SessionEntry = {
	id:String,
	name:String,
	machineId:String,
	workspaceId:String,
	workspaceName:String,
	/** Group ids from the workspace root to the session's group; empty for a root session. */
	groupPath:Array<String>,
	/** Display names for groupPath, same length. */
	groupNames:Array<String>,
	kind:SessionKind,
	state:SessionState,
	/** Milliseconds since the epoch. */
	lastActive:Float,
	/** The last line of output or the last message, for the row's second line; may be empty. */
	last:String,
}

enum SessionSectioning {
	None;
	Workspace;
	Group;
	State;
	Day;
}

typedef SessionQuery = {
	?workspaces:Array<String>,
	/** A group selects its descendants too. */
	?groups:Array<String>,
	?kinds:Array<SessionKind>,
	?states:Array<SessionState>,
	?text:String,
	sectioning:SessionSectioning,
}

typedef SessionSection = {
	id:String,
	/** Group sections: the full path, e.g. ["11-17-26", "phone app"]; others: one element. */
	title:Array<String>,
	entries:Array<SessionEntry>,
}

/** All sessions of a machine (or several), queried by facets. Built from exohost's `sessions` reply. */
class SessionIndex {
	public var entries(default, null):Array<SessionEntry> = [];
	public var revision(default, null):Int = 0;

	public function new() {}

	public function replace(entries:Array<SessionEntry>):Void {
		this.entries = entries;
		revision++;
	}

	/**
		Filtered, sorted (attention, then working, then the rest; each by most recent first) and sectioned; see
		docs/phone-ui/CONTRACTS.md. A missing or empty filter list selects everything. Sections:
		None one section "all" titled ["All"]; Workspace one per workspace; Group flat, titled with the full path
		(root sessions under ["Ungrouped"]), per workspace, parent before child, a group's own sessions first, only
		groups holding entries; State "attention" ["Needs you"], "working" ["Working"], "recent" ["Recent"] (idle and
		exited), skipping empty ones; Day newest day first, titled "Today", "Yesterday" or the date.
	**/
	public function query(q:SessionQuery):Array<SessionSection> {
		var found = [for (entry in entries) if (matches(entry, q)) entry];
		found.sort(compare);
		switch q.sectioning {
			case None:
				return found.length == 0 ? [] : [{id: "all", title: ["All"], entries: found}];
			case Workspace:
				return byWorkspace(found);
			case Group:
				return byGroup(found);
			case State:
				return byState(found);
			case Day:
				return byDay(found);
		}
	}

	static function matches(entry:SessionEntry, q:SessionQuery):Bool {
		if (q.workspaces != null && q.workspaces.length > 0 && q.workspaces.indexOf(entry.workspaceId) < 0)
			return false;
		if (q.kinds != null && q.kinds.length > 0 && q.kinds.indexOf(entry.kind) < 0)
			return false;
		if (q.states != null && q.states.length > 0 && q.states.indexOf(entry.state) < 0)
			return false;
		if (q.groups != null && q.groups.length > 0) {
			var inside = false;
			for (id in entry.groupPath)
				if (q.groups.indexOf(id) >= 0)
					inside = true;
			if (!inside)
				return false;
		}
		if (q.text != null && q.text.length > 0 && entry.name.toLowerCase().indexOf(q.text.toLowerCase()) < 0)
			return false;
		return true;
	}

	static function rank(state:SessionState):Int
		return state == SessionState.Attention ? 0 : state == SessionState.Working ? 1 : 2;

	static function compare(a:SessionEntry, b:SessionEntry):Int {
		var byRank = rank(a.state) - rank(b.state);
		if (byRank != 0)
			return byRank;
		if (a.lastActive != b.lastActive)
			return a.lastActive > b.lastActive ? -1 : 1;
		var byName = Reflect.compare(a.name.toLowerCase(), b.name.toLowerCase());
		return byName != 0 ? byName : Reflect.compare(a.id, b.id);
	}

	static function byWorkspace(found:Array<SessionEntry>):Array<SessionSection> {
		var sections:Array<SessionSection> = [];
		var index:Map<String, SessionSection> = [];
		for (entry in found) {
			var section = index.get(entry.workspaceId);
			if (section == null) {
				section = {id: entry.workspaceId, title: [entry.workspaceName], entries: []};
				index.set(entry.workspaceId, section);
				sections.push(section);
			}
			section.entries.push(entry);
		}
		return sections;
	}

	static function byGroup(found:Array<SessionEntry>):Array<SessionSection> {
		var order:Map<String, Int> = [];
		var count = 0;
		for (entry in found)
			if (!order.exists(entry.workspaceId))
				order.set(entry.workspaceId, count++);
		var index:Map<String, GroupItem> = [];
		var all:Array<GroupItem> = [];
		for (entry in found) {
			var id = entry.workspaceId + "/" + entry.groupPath.join("/");
			var item = index.get(id);
			if (item == null) {
				var names = entry.groupNames.copy();
				item = {
					section: {id: id, title: names.length == 0 ? ["Ungrouped"] : names, entries: []},
					workspace: order.get(entry.workspaceId),
					names: [for (name in names) name.toLowerCase()]
				};
				index.set(id, item);
				all.push(item);
			}
			item.section.entries.push(entry);
		}
		all.sort(function(a, b) {
			if (a.workspace != b.workspace)
				return a.workspace - b.workspace;
			// A path that is a prefix of another sorts first, so a parent precedes its children.
			var length = a.names.length < b.names.length ? a.names.length : b.names.length;
			for (position in 0...length) {
				var by = Reflect.compare(a.names[position], b.names[position]);
				if (by != 0)
					return by;
			}
			return a.names.length - b.names.length;
		});
		return [for (item in all) item.section];
	}

	static function byState(found:Array<SessionEntry>):Array<SessionSection> {
		var attention:Array<SessionEntry> = [], working:Array<SessionEntry> = [], recent:Array<SessionEntry> = [];
		for (entry in found)
			(entry.state == SessionState.Attention ? attention : entry.state == SessionState.Working ? working : recent).push(entry);
		var sections:Array<SessionSection> = [];
		if (attention.length > 0)
			sections.push({id: "attention", title: ["Needs you"], entries: attention});
		if (working.length > 0)
			sections.push({id: "working", title: ["Working"], entries: working});
		if (recent.length > 0)
			sections.push({id: "recent", title: ["Recent"], entries: recent});
		return sections;
	}

	static function dayKey(time:Float):Int {
		if (time <= 0)
			return 0;
		var date = Date.fromTime(time);
		return date.getFullYear() * 10000 + (date.getMonth() + 1) * 100 + date.getDate();
	}

	static function pad(value:Int):String
		return value < 10 ? "0" + value : Std.string(value);

	static function byDay(found:Array<SessionEntry>):Array<SessionSection> {
		var now = Date.now().getTime();
		var today = dayKey(now);
		var yesterday = dayKey(now - 86400000.0);
		var keys:Array<Int> = [];
		var index:Map<Int, SessionSection> = [];
		for (entry in found) {
			var key = dayKey(entry.lastActive);
			var section = index.get(key);
			if (section == null) {
				var title = key == 0 ? "Earlier" : key == today ? "Today" : key == yesterday ? "Yesterday" : Std.int(key / 10000) + "-"
					+ pad(Std.int(key / 100) % 100) + "-" + pad(key % 100);
				section = {id: "day-" + key, title: [title], entries: []};
				index.set(key, section);
				keys.push(key);
			}
			section.entries.push(entry);
		}
		keys.sort(function(a, b) return b - a);
		return [for (key in keys) index.get(key)];
	}

	/** The entries of exohost's `sessions` reply (`{"sessions":[...]}`); a malformed element is skipped. */
	public static function fromJson(reply:Dynamic):Array<SessionEntry> {
		var result:Array<SessionEntry> = [];
		var listed:Dynamic = reply == null ? null : Reflect.field(reply, "sessions");
		if (!Std.isOfType(listed, Array))
			return result;
		for (item in (listed : Array<Dynamic>)) {
			if (item == null)
				continue;
			var id:Dynamic = Reflect.field(item, "id"), workspace:Dynamic = Reflect.field(item, "workspaceId");
			if (!Std.isOfType(id, String) || !Std.isOfType(workspace, String))
				continue;
			var path = strings(Reflect.field(item, "groupPath"));
			var names = strings(Reflect.field(item, "groupNames"));
			while (names.length < path.length)
				names.push(path[names.length]);
			if (names.length > path.length)
				names = names.slice(0, path.length);
			var active:Dynamic = Reflect.field(item, "lastActive");
			result.push({
				id: id,
				name: text(Reflect.field(item, "name")),
				machineId: text(Reflect.field(item, "machineId")),
				workspaceId: workspace,
				workspaceName: text(Reflect.field(item, "workspaceName")),
				groupPath: path,
				groupNames: names,
				kind: kindOf(Reflect.field(item, "kind")),
				state: stateOf(Reflect.field(item, "state")),
				lastActive: Std.isOfType(active, Float) ? (active : Float) : 0.0,
				last: text(Reflect.field(item, "last"))
			});
		}
		return result;
	}

	/** The `sessions` array of a reply: entries as plain JSON objects. */
	public static function toJson(entries:Array<SessionEntry>):Array<Dynamic> {
		var result:Array<Dynamic> = [];
		for (entry in entries)
			result.push({
				id: entry.id,
				name: entry.name,
				machineId: entry.machineId,
				workspaceId: entry.workspaceId,
				workspaceName: entry.workspaceName,
				groupPath: entry.groupPath.copy(),
				groupNames: entry.groupNames.copy(),
				kind: (entry.kind : String),
				state: (entry.state : String),
				lastActive: entry.lastActive,
				last: entry.last
			});
		return result;
	}

	static function text(value:Dynamic):String
		return Std.isOfType(value, String) ? (value : String) : "";

	static function strings(value:Dynamic):Array<String> {
		var result:Array<String> = [];
		if (Std.isOfType(value, Array))
			for (item in (value : Array<Dynamic>))
				result.push(Std.isOfType(item, String) ? (item : String) : "");
		return result;
	}

	public static function kindOf(value:Dynamic):SessionKind
		return switch text(value) {
			case "claude": SessionKind.Claude;
			case "codex": SessionKind.Codex;
			case "terminal": SessionKind.Terminal;
			case "chat": SessionKind.Chat;
			default: SessionKind.Other;
		}

	public static function stateOf(value:Dynamic):SessionState
		return switch text(value) {
			case "attention": SessionState.Attention;
			case "working": SessionState.Working;
			case "exited": SessionState.Exited;
			default: SessionState.Idle;
		}
}

private typedef GroupItem = {
	var section:SessionSection;
	var workspace:Int;
	var names:Array<String>;
}
