package ui;

import workspace.service.WorkspaceProtocol.WorkspaceGroup;

/**
	A Workbench tree row: what it shows and that thing's id. The tree stores rows as strings (`g:`, `t:` or `a:` plus the
	id); this is the one place that writes and reads that spelling. Above the groups, the machine's rows use `w:` plus a
	workspace id, `s:` (a status line) and `n:` (New Workspace…); `parse` returns null for them, so group, session and
	terminal code ignores them.
**/
class WorkbenchRowKey {
	public final kind:WorkbenchRowKind;
	public final id:String;

	public function new(kind:WorkbenchRowKind, id:String) {
		this.kind = kind; this.id = id;
	}

	public static function group(id:String):String return "g:" + id;
	public static function terminal(id:String):String return "t:" + id;
	public static function agent(id:String):String return "a:" + id;

	/** The last of the machine's rows. */
	public static inline final NEW_WORKSPACE = "n:new-workspace";
	public static function machineWorkspace(id:String):String return "w:" + id;
	public static function status(kind:String):String return "s:" + kind;

	/** The workspace id of a `w:` row, else null. */
	public static function workspaceId(key:Null<String>):Null<String>
		return key != null && StringTools.startsWith(key, "w:") && key.length > 2 ? key.substring(2) : null;

	/** The kind of an `s:` status row, else null. */
	public static function statusKind(key:Null<String>):Null<String>
		return key != null && StringTools.startsWith(key, "s:") && key.length > 2 ? key.substring(2) : null;

	/** True for the machine's rows: its workspaces, status lines and New Workspace…. */
	public static function isMachineRow(key:Null<String>):Bool
		return key != null && key.length > 2 && key.charAt(1) == ":" && "wsn".indexOf(key.charAt(0)) >= 0;

	/** The row a tree key names, or null for a key that is not a Workbench row. */
	public static function parse(key:Null<String>):Null<WorkbenchRowKey> {
		if (key == null || key.length < 3 || key.charAt(1) != ":") return null;
		var id = key.substring(2);
		return switch key.charAt(0) {
			case "g": new WorkbenchRowKey(WorkbenchRowKind.Group, id);
			case "t": new WorkbenchRowKey(WorkbenchRowKind.Terminal, id);
			case "a": new WorkbenchRowKey(WorkbenchRowKind.Agent, id);
			default: null;
		};
	}

	/** The id when `key` is a row of `kind`, else null. */
	public static function idOf(key:Null<String>, kind:WorkbenchRowKind):Null<String> {
		var row = parse(key);
		return row == null || row.kind != kind ? null : row.id;
	}

	public static function isKind(key:Null<String>, kind:WorkbenchRowKind):Bool return idOf(key, kind) != null;

	/** The group a row belongs to: a group row is its own group, a session or terminal row its parent's. */
	public static function groupOf(model:WorkbenchTreeModel, key:Null<String>):Null<WorkspaceGroup> {
		var row = parse(key);
		return row == null ? null : row.owningGroup(model);
	}

	/** The id of the group this row sits in: a group's parent, a session's or terminal's group. */
	public static function parentGroupId(model:WorkbenchTreeModel, key:Null<String>):Null<String> {
		var row = parse(key);
		if (row == null) return null;
		return switch row.kind {
			case WorkbenchRowKind.Group: var group = model.groups.get(row.id); group == null ? null : group.parent;
			case WorkbenchRowKind.Terminal: var terminal = model.terminals.get(row.id); terminal == null ? null : terminal.group;
			case WorkbenchRowKind.Agent: var agent = model.agents.get(row.id); agent == null ? null : agent.group;
		};
	}

	function owningGroup(model:WorkbenchTreeModel):Null<WorkspaceGroup> {
		var groupId:Null<String> = switch kind {
			case WorkbenchRowKind.Group: id;
			case WorkbenchRowKind.Terminal: var terminal = model.terminals.get(id); terminal == null ? null : terminal.group;
			case WorkbenchRowKind.Agent: var agent = model.agents.get(id); agent == null ? null : agent.group;
		};
		return groupId == null ? null : model.groups.get(groupId);
	}

	public function toString():String return switch kind {
		case WorkbenchRowKind.Group: group(id);
		case WorkbenchRowKind.Terminal: terminal(id);
		case WorkbenchRowKind.Agent: agent(id);
	};
}
