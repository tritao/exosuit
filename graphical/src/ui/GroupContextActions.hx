package ui;

import workspace.service.WorkspaceProtocol.WorkspaceGroup;
import workspace.service.WorkspaceTerminalProtocol.TerminalCatalog;
import workspace.service.WorkspaceAgentProtocol.AgentCatalog;
import workspace.client.WorkspaceWorkbenchClient;

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

	/** The menu and the remove action both decide here, against the client's current catalogs and permissions. */
	public static function removal(group:WorkspaceGroup, client:WorkspaceWorkbenchClient):GroupRemoval {
		var agents = client.agentService();
		return removalOf(group.id, client.canEditGroups() && client.canRemoveGroups(),
			client.terminalCatalogBusy() || agents.agentBusy(), client.terminalCatalog(), agents.agents());
	}

	/** `permitted`: the service grants editing and removing groups; `busy`: a workspace operation is running. */
	public static function removalOf(group:String, permitted:Bool, busy:Bool, catalog:Null<TerminalCatalog>, agents:Null<AgentCatalog>):GroupRemoval {
		if (!permitted) return GroupRemoval.NotPermitted;
		if (busy || !complete(catalog, agents)) return GroupRemoval.Busy;
		return empty(group, catalog, agents) ? GroupRemoval.Allowed : GroupRemoval.NotEmpty;
	}

	/** The menu entry, which says why it is disabled when the group still has contents. */
	public static function removeLabel(removal:GroupRemoval):String
		return removal == GroupRemoval.NotEmpty ? "Remove Group (not empty)" : "Remove Group";

	/** Both catalogs are fully loaded and describe the same workspace, so emptiness can be decided. */
	static function complete(catalog:Null<TerminalCatalog>, agents:Null<AgentCatalog>):Bool
		return catalog != null && catalog.next == null && agents != null && agents.root == catalog.workspaceRoot && agents.next == null;

	public static function empty(group:String, catalog:Null<TerminalCatalog>, agents:Null<AgentCatalog>):Bool {
		if (catalog == null || agents == null || !complete(catalog, agents)) return false;
		for (child in catalog.groups) if (child.parent == group) return false;
		for (terminal in catalog.terminals) if (terminal.group == group) return false;
		for (agent in agents.records) if (agent.group == group) return false;
		return true;
	}
}
