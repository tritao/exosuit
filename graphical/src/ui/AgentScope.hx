package ui;

import workspace.service.WorkspaceProtocol.WorkspaceGroup;

/** The folder the Agents layout's Files, Search and Changes tabs work in: one Workbench group's directory. */
class AgentScope {
	public final groupId:String;
	public final label:String;
	public final directory:String;

	public function new(groupId:String, label:String, directory:String) {
		this.groupId = groupId; this.label = label; this.directory = directory;
	}

	public function equals(other:Null<AgentScope>):Bool
		return other != null && other.groupId == groupId && other.label == label && other.directory == directory;

	/** The group a Workbench row belongs to: a group row is its own group, a session or terminal row its parent's. */
	public static function groupOf(model:WorkbenchTreeModel, key:Null<String>):Null<WorkspaceGroup> {
		if (key == null || key.length < 3) return null;
		var id = key.substring(2);
		var groupId:Null<String> = null;
		if (StringTools.startsWith(key, "g:")) groupId = id;
		else if (StringTools.startsWith(key, "t:")) { var terminal = model.terminals.get(id); if (terminal != null) groupId = terminal.group; }
		else if (StringTools.startsWith(key, "a:")) { var agent = model.agents.get(id); if (agent != null) groupId = agent.group; }
		return groupId == null ? null : model.groups.get(groupId);
	}

	/**
		The selected row decides the scope. With no selection, or a row without a directory, the last group's scope stays,
		refreshed when that group was renamed or moved to another folder. Before any group was chosen, the first top-level
		group stands in, so the panel never shows the editor's own workspace folders.
	**/
	public static function resolve(model:WorkbenchTreeModel, selectedKey:Null<String>, previous:Null<AgentScope>):Null<AgentScope> {
		var selected = scopeFor(model, groupOf(model, selectedKey));
		if (selected != null) return selected;
		if (previous != null) {
			var refreshed = scopeFor(model, model.groups.get(previous.groupId));
			return refreshed != null ? refreshed : previous;
		}
		for (index in 0...model.rootCount()) {
			var key = model.rootKeyAt(index);
			var first = scopeFor(model, groupOf(model, key));
			if (first != null) return first;
		}
		return null;
	}

	static function scopeFor(model:WorkbenchTreeModel, group:Null<WorkspaceGroup>):Null<AgentScope> {
		if (group == null) return null;
		var directory = model.directory(group);
		return directory == null || directory.length == 0 ? null : new AgentScope(group.id, group.name, directory);
	}

	/** The panel's one-line caption: `name — path`. */
	public function caption():String return label + " — " + directory;
}
