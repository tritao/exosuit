package ui;

import workspace.service.WorkspaceTerminalProtocol.TerminalCatalog;
import workspace.service.WorkspaceAgentProtocol.AgentCatalog;

/** Pure policy evaluated against the current workspace snapshot, including at release. */
class WorkbenchDropRules {
	public static function canDrop(source:String, target:String, catalog:TerminalCatalog, agents:Null<AgentCatalog>):Bool {
		var parent = WorkbenchRowKey.idOf(target, WorkbenchRowKind.Group), row = WorkbenchRowKey.parse(source);
		if (parent == null || row == null) return false;
		if (!Lambda.exists(catalog.groups, function(group) return group.id == parent)) return false;
		var id = row.id;
		switch row.kind {
			case WorkbenchRowKind.Group:
				for (group in catalog.groups) if (group.id == id)
					return group.parent != parent && GroupContextActions.canParent(id, parent, catalog.groups);
			case WorkbenchRowKind.Terminal:
				for (terminal in catalog.terminals) if (terminal.id == id) return terminal.group != parent;
			case WorkbenchRowKind.Agent:
				if (agents != null && agents.instance == catalog.instance && agents.root == catalog.workspaceRoot)
					for (agent in agents.records) if (agent.id == id) return agent.group != parent;
		}
		return false;
	}
}
