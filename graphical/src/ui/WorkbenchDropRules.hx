package ui;

import workspace.service.WorkspaceTerminalProtocol.TerminalCatalog;
import workspace.service.WorkspaceAgentProtocol.AgentCatalog;

/** Pure policy evaluated against the current workspace snapshot, including at release. */
class WorkbenchDropRules {
	public static function canDrop(source:String, target:String, catalog:TerminalCatalog, agents:Null<AgentCatalog>):Bool {
		if (!StringTools.startsWith(target, "g:")) return false;
		var parent = target.substring(2);
		if (!Lambda.exists(catalog.groups, function(group) return group.id == parent)) return false;
		var id = source.substring(2);
		if (StringTools.startsWith(source, "g:")) {
			for (group in catalog.groups) if (group.id == id)
				return group.parent != parent && GroupContextActions.canParent(id, parent, catalog.groups);
		} else if (StringTools.startsWith(source, "t:")) {
			for (terminal in catalog.terminals) if (terminal.id == id) return terminal.group != parent;
		} else if (StringTools.startsWith(source, "a:") && agents != null
				&& agents.instance == catalog.instance && agents.root == catalog.workspaceRoot) {
			for (agent in agents.records) if (agent.id == id) return agent.group != parent;
		}
		return false;
	}
}
