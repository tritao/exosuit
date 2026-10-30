package ui;

import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;

/** The folder the Agents layout's Files, Search and Changes tabs work in: one Workbench group's directory. */
class AgentScope {
	public final groupId:String;
	public final label:String;
	public final directory:String;
	/** The groups above this one, nearest first, when the scope was taken; a deleted group's scope falls back along them. */
	public final ancestors:Array<String>;

	public function new(groupId:String, label:String, directory:String, ?ancestors:Array<String>) {
		this.groupId = groupId; this.label = label; this.directory = directory;
		this.ancestors = ancestors == null ? [] : ancestors.copy();
	}

	public function equals(other:Null<AgentScope>):Bool
		return other != null && other.groupId == groupId && other.label == label && other.directory == directory
			&& other.ancestors.join("\n") == ancestors.join("\n");

	/** The same scope with its directory spelled another way, e.g. normalized by the file system. */
	public function withDirectory(value:String):AgentScope return new AgentScope(groupId, label, value, ancestors);

	/**
		The selected row decides the scope. With no selection, or a row without a directory, the last group's scope stays,
		refreshed when that group was renamed or moved to another folder. When that group was deleted, its nearest
		surviving parent group takes over. Before any group was chosen, or when none of those groups is left, the first
		top-level group stands in, so the panel never shows the editor's own workspace folders. A session or terminal at the
		workspace root, or the workspace's row, scopes to the workspace's first folder; that scope stays like a group's.
	**/
	public static function resolve(model:WorkbenchTreeModel, selectedKey:Null<String>, previous:Null<AgentScope>):Null<AgentScope> {
		// A session or terminal at the workspace root, or the workspace's row, works in the workspace itself.
		var atRoot = selectedKey != null && selectedKey == model.groupParent;
		var row = WorkbenchRowKey.parse(selectedKey);
		if (row != null && row.kind != WorkbenchRowKind.Group && WorkspaceProtocol.isRoot(WorkbenchRowKey.parentGroupId(model, selectedKey)))
			atRoot = true;
		if (previous != null && WorkspaceProtocol.isRoot(previous.groupId) && WorkbenchRowKey.groupOf(model, selectedKey) == null)
			atRoot = true;
		var workspace = atRoot ? rootScope(model) : null;
		if (workspace != null) return workspace;
		var selected = scopeFor(model, WorkbenchRowKey.groupOf(model, selectedKey));
		if (selected != null) return selected;
		if (previous != null) {
			if (model.groups.exists(previous.groupId)) {
				var refreshed = scopeFor(model, model.groups.get(previous.groupId));
				return refreshed != null ? refreshed : previous;
			}
			for (id in previous.ancestors) {
				var parent = scopeFor(model, model.groups.get(id));
				if (parent != null) return parent;
			}
		}
		for (key in model.groupRoots) {
			var first = scopeFor(model, WorkbenchRowKey.groupOf(model, key));
			if (first != null) return first;
		}
		return null;
	}

	/** The workspace root's scope: the workspace's first folder, named after the workspace. */
	static function rootScope(model:WorkbenchTreeModel):Null<AgentScope> {
		var directory = model.workspaceRoot;
		if (directory == null || directory.length == 0) return null;
		var owner = model.groupWorkspace();
		return new AgentScope(WorkspaceProtocol.ROOT_GROUP, owner == null ? "Workspace" : owner.name, directory);
	}

	static function scopeFor(model:WorkbenchTreeModel, group:Null<WorkspaceGroup>):Null<AgentScope> {
		if (group == null) return null;
		var directory = model.directory(group);
		if (directory == null || directory.length == 0) return null;
		var ancestors:Array<String> = [], visited:Map<String, Bool> = [group.id => true], parent = group.parent;
		while (parent != null && !visited.exists(parent)) {
			visited.set(parent, true);
			ancestors.push(parent);
			var next = model.groups.get(parent);
			parent = next == null ? null : next.parent;
		}
		return new AgentScope(group.id, group.name, directory, ancestors);
	}

	/** The panel's one-line caption: `name — path`. */
	public function caption():String return label + " — " + directory;
}
