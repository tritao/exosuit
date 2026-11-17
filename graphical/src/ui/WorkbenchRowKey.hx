package ui;

import workspace.service.WorkspaceProtocol.WorkspaceGroup;

/**
	A Workbench tree row: what it shows, the workspace it belongs to and that thing's id there. The tree stores rows as
	strings; this is the one place that writes and reads that spelling. Every workspace's groups, sessions and terminals
	are spelled alike: `g:`, `a:` or `t:`, the workspace id, `|` and the item's id (the workspace id is empty in a window
	without this machine's workspaces, the phone's or the browser's, which shows one workspace). Above them, the machine's
	rows use `w:` plus a workspace id, `s:` (a status line) and `n:` (New Workspace…); `parse` returns null for them, so
	group, session and terminal code ignores them.
**/
class WorkbenchRowKey {
	public final kind:WorkbenchRowKind;
	public final workspace:String;
	public final id:String;

	public function new(kind:WorkbenchRowKind, workspace:String, id:String) {
		this.kind = kind; this.workspace = workspace; this.id = id;
	}

	public static function group(workspace:String, id:String):String return "g:" + workspace + "|" + id;
	public static function terminal(workspace:String, id:String):String return "t:" + workspace + "|" + id;
	public static function agent(workspace:String, id:String):String return "a:" + workspace + "|" + id;

	/** The last of the machine's rows. */
	public static inline final NEW_WORKSPACE = "n:new-workspace";
	public static function machineWorkspace(id:String):String return "w:" + id;
	public static function status(kind:String):String return "s:" + kind;

	/** The workspace id of a `w:` row, else null. */
	public static function workspaceId(key:Null<String>):Null<String>
		return key != null && StringTools.startsWith(key, "w:") && key.length > 2 ? key.substring(2) : null;

	/** The kind of an `s:` status row (a workspace's note included), else null. */
	public static function statusKind(key:Null<String>):Null<String> {
		if (key == null || !StringTools.startsWith(key, "s:") || key.length <= 2) return null;
		var bar = key.indexOf("|");
		return bar < 0 ? key.substring(2) : key.substring(2, bar);
	}

	/**
		A workspace's note kinds: nothing in it yet, its rows still loading (its service runs or is starting), its
		service not running, or this window could not connect to it.
	**/
	public static inline final NOTE_EMPTY = "none";
	public static inline final NOTE_LOADING = "loading-rows";
	public static inline final NOTE_IDLE = "not-running";
	public static inline final NOTE_FAILED = "failed";

	/** The one row under an expanded workspace that has no other rows, saying why: `s:` plus its kind, `|` and the workspace id. */
	public static function note(kind:String, workspace:String):String return "s:" + kind + "|" + workspace;

	/** The workspace of a note row, else null. */
	public static function noteWorkspace(key:Null<String>):Null<String> {
		if (key == null || !StringTools.startsWith(key, "s:")) return null;
		var bar = key.indexOf("|");
		return bar < 0 ? null : key.substring(bar + 1);
	}

	/** True for the machine's rows: its workspaces, status lines and New Workspace…. */
	public static function isMachineRow(key:Null<String>):Bool
		return key != null && key.length > 2 && key.charAt(1) == ":" && "wsn".indexOf(key.charAt(0)) >= 0;

	/** The row a tree key names, or null for a key that is not a group, session or terminal row. */
	public static function parse(key:Null<String>):Null<WorkbenchRowKey> {
		if (key == null || key.length < 4 || key.charAt(1) != ":") return null;
		var bar = key.indexOf("|", 2);
		if (bar < 0 || bar == key.length - 1) return null;
		var workspace = key.substring(2, bar), id = key.substring(bar + 1);
		return switch key.charAt(0) {
			case "g": new WorkbenchRowKey(WorkbenchRowKind.Group, workspace, id);
			case "t": new WorkbenchRowKey(WorkbenchRowKind.Terminal, workspace, id);
			case "a": new WorkbenchRowKey(WorkbenchRowKind.Agent, workspace, id);
			default: null;
		};
	}

	/** The id when `key` is a row of `kind`, else null. */
	public static function idOf(key:Null<String>, kind:WorkbenchRowKind):Null<String> {
		var row = parse(key);
		return row == null || row.kind != kind ? null : row.id;
	}

	public static function isKind(key:Null<String>, kind:WorkbenchRowKind):Bool return idOf(key, kind) != null;

	/** The group a row belongs to in its workspace: a group row is its own group, a session or terminal row its parent's. */
	public static function groupOf(model:WorkbenchTreeModel, key:Null<String>):Null<WorkspaceGroup> {
		var row = parse(key), rows = row == null ? null : model.rows(row.workspace);
		if (row == null || rows == null) return null;
		var groupId:Null<String> = row.kind == WorkbenchRowKind.Group ? row.id : rows.itemGroup(row.kind, row.id);
		return groupId == null ? null : rows.groups.get(groupId);
	}

	/** The id of the group this row sits in: a group's parent, a session's or terminal's group. */
	public static function parentGroupId(model:WorkbenchTreeModel, key:Null<String>):Null<String> {
		var row = parse(key), rows = row == null ? null : model.rows(row.workspace);
		if (row == null || rows == null) return null;
		if (row.kind != WorkbenchRowKind.Group) return rows.itemGroup(row.kind, row.id);
		var group = rows.groups.get(row.id);
		return group == null ? null : group.parent;
	}

	public function toString():String return switch kind {
		case WorkbenchRowKind.Group: group(workspace, id);
		case WorkbenchRowKind.Terminal: terminal(workspace, id);
		case WorkbenchRowKind.Agent: agent(workspace, id);
	};
}
