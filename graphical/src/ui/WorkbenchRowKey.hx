package ui;

import workspace.service.WorkspaceProtocol.WorkspaceGroup;

enum WorkbenchRowKind {
	Group;
	Terminal;
	Agent;
}

/**
	A Workbench tree row: what it shows and that thing's id. The tree stores rows as strings (`g:`, `t:` or `a:` plus the
	id); this is the one place that writes and reads that spelling.
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

	/** The row a tree key names, or null for a key that is not a Workbench row. */
	public static function parse(key:Null<String>):Null<WorkbenchRowKey> {
		if (key == null || key.length < 3 || key.charAt(1) != ":") return null;
		var id = key.substring(2);
		return switch key.charAt(0) {
			case "g": new WorkbenchRowKey(Group, id);
			case "t": new WorkbenchRowKey(Terminal, id);
			case "a": new WorkbenchRowKey(Agent, id);
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
			case Group: var group = model.groups.get(row.id); group == null ? null : group.parent;
			case Terminal: var terminal = model.terminals.get(row.id); terminal == null ? null : terminal.group;
			case Agent: var agent = model.agents.get(row.id); agent == null ? null : agent.group;
		};
	}

	function owningGroup(model:WorkbenchTreeModel):Null<WorkspaceGroup> {
		var groupId = kind == Group ? id : parentGroupId(model, toString());
		return groupId == null ? null : model.groups.get(groupId);
	}

	public function toString():String return switch kind {
		case Group: group(id);
		case Terminal: terminal(id);
		case Agent: agent(id);
	};
}
