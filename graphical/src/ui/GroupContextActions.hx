package ui;

import workspace.service.WorkspaceProtocol.WorkspaceGroup;
import workspace.service.WorkspaceTerminalProtocol.TerminalCatalog;
import workspace.service.WorkspaceAgentProtocol.AgentCatalog;

/** Group actions share the service's hierarchy and empty-group rules. */
class GroupContextActions {
	public static function canParent(group:String, parent:Null<String>, groups:Array<WorkspaceGroup>):Bool {
		var seen:Map<String, Bool> = [group => true];
		while (parent != null) {
			if (seen.exists(parent)) return false;
			seen.set(parent, true);
			var next:Null<WorkspaceGroup> = null;
			for (candidate in groups) if (candidate.id == parent) { next = candidate; break; }
			if (next == null) return false;
			parent = next.parent;
		}
		return true;
	}
	/** The right-click menu and the action handlers both decide availability here. */
	public static function canInherit(group:WorkspaceGroup):Bool return group.cwd != null;

	public static function canMove(group:WorkspaceGroup, groups:Array<WorkspaceGroup>):Bool {
		if (group.parent != null) return true;
		for (candidate in groups) if (candidate.id != group.parent && canParent(group.id, candidate.id, groups)) return true;
		return false;
	}

	/** `allowed` is the caller's permission and idle check (remove grant, no agent operation running). */
	public static function canRemove(group:WorkspaceGroup, allowed:Bool, catalog:Null<TerminalCatalog>, agents:Null<AgentCatalog>):Bool
		return allowed && empty(group.id, catalog, agents);

	public static function empty(group:String, catalog:Null<TerminalCatalog>, agents:Null<AgentCatalog>):Bool {
		if (catalog == null || catalog.next != null || agents == null || agents.root != catalog.workspaceRoot || agents.next != null) return false;
		for (child in catalog.groups) if (child.parent == group) return false;
		for (terminal in catalog.terminals) if (terminal.group == group) return false;
		for (agent in agents.records) if (agent.group == group) return false;
		return true;
	}
}
