package ui;

import workspace.service.WorkspaceTerminalProtocol.TerminalCatalog;
import workspace.service.WorkspaceAgentProtocol.AgentCatalog;
import workspace.service.WorkspaceProtocol;

/** Pure policy evaluated against the current workspace snapshot, including at release. */
class WorkbenchDropRules {
	/**
		Where a drop onto `target` puts things: a group's id, the workspace root for `rootRow` (the open workspace's row;
		null when the groups are not under one), or null for a row that takes no drops.
	**/
	public static function destination(target:String, rootRow:Null<String>):Null<String>
		return rootRow != null && target == rootRow ? WorkspaceProtocol.ROOT_GROUP : WorkbenchRowKey.idOf(target, WorkbenchRowKind.Group);

	/**
		The zone of a row `offset` pixels below its centre. A row that takes drops (a group) gives its upper and lower
		quarters to the edges and the middle to a move into it; any other row is split in halves.
	**/
	public static function zone(offset:Float, height:Float, takesDrops:Bool):WorkbenchDropZone {
		if (Math.isNaN(offset) || height <= 0) return takesDrops ? WorkbenchDropZone.Into : WorkbenchDropZone.After;
		var edge = takesDrops ? height / 4 : 0.0;
		return offset < -edge ? WorkbenchDropZone.Before : offset > edge ? WorkbenchDropZone.After : takesDrops ? WorkbenchDropZone.Into : WorkbenchDropZone.After;
	}

	public static function canDrop(source:String, target:String, catalog:TerminalCatalog, agents:Null<AgentCatalog>, rootRow:Null<String>):Bool {
		var into = destination(target, rootRow), row = WorkbenchRowKey.parse(source);
		if (into == null || row == null || !WorkspaceProtocol.knownGroup(into, catalog.groups)) return false;
		var id = row.id, parent = WorkspaceProtocol.parentFor(into);
		switch row.kind {
			case WorkbenchRowKind.Group:
				for (group in catalog.groups) if (group.id == id)
					return group.parent != parent && (parent == null || GroupContextActions.canParent(id, parent, catalog.groups));
			case WorkbenchRowKind.Terminal:
				for (terminal in catalog.terminals) if (terminal.id == id) return terminal.group != into;
			case WorkbenchRowKind.Agent:
				if (agents != null && agents.instance == catalog.instance && agents.root == catalog.workspaceRoot)
					for (agent in agents.records) if (agent.id == id) return agent.group != into;
		}
		return false;
	}
}
