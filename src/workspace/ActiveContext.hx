package workspace;

/**
	Window-local scope. Selecting a tree row never changes this object; entering one does: a click or Enter on a group row
	(`focusGroup`) or on the open workspace's row (`useWorkspace`).
**/
class ActiveContext {
	public var kind(default, null):ContextKind = ContextKind.Workspace;
	public var id(default, null):String = "workspace";
	public var label(default, null):String = "Workspace";
	public var roots(default, null):Array<String> = [];
	public var cwd(default, null):String = Sys.getCwd();
	public var revision(default, null):Int = 0;
	/** The machine this window works on; the catalog's id once suit has answered, a placeholder before. */
	public var machineId(default, null):String = ContextKey.DEFAULT_MACHINE;
	/** The workspace the active context belongs to: the saved workspace's id, also for a group of it. */
	public var contextWorkspaceId(default, null):String = "workspace";
	/** Recently active contexts, newest first. Ctrl+Tab and the quick switch read it. */
	public final recent:Array<ContextInfo> = [];
	public static inline final RECENT_LIMIT = 32;
	/** Called after `assignMachine` changed the id, so holders of saved contexts can re-key them. */
	public var onMachineAssigned:String->Void = function(_) {};
	/**
		The open workspace's own folders. Set once a workspace definition owns them (SavedWorkspaceController); without
		it the roots are the open projects. A project opened for another reason never becomes one of the workspace's roots.
	**/
	public var workspaceFolders:Null<Void->Array<String>>;
	final workspace:Workspace;
	final listeners:Array<Void->Void> = [];
	final groupProjects:Map<String, Project> = [];
	var workspaceUpdateDepth:Int = 0;
	var workspaceId:String = "workspace";
	var workspaceLabel:String = "Workspace";
	var workspaceRoots:Array<String> = [];
	public function new(workspace:Workspace) {
		this.workspace = workspace;
		workspace.activeContext = this;
		workspace.subscribe(function() {
			var owned = workspaceFolders;
			workspaceRoots = owned != null ? owned() : [for (project in workspace.projects) project.root];
			if (kind == ContextKind.Workspace && workspaceUpdateDepth == 0) publish(ContextKind.Workspace, workspaceId, workspaceLabel, workspaceRoots);
		});
		remember(new ContextInfo(machineId, workspaceId, "", workspaceLabel, workspaceLabel, cwd));
	}
	public function subscribe(listener:Void->Void):Void->Void {
		listeners.push(listener);
		return function() { listeners.remove(listener); };
	}
	public function updateWorkspace(id:String, label:String, roots:Array<String>):Void {
		// An identity assignment calls renameWorkspace first, so only another workspace opening counts as moved.
		var moved = workspaceId != id;
		workspaceId = id; workspaceLabel = label; workspaceRoots = roots.copy();
		// A group belongs to its workspace: another workspace shows its own root context.
		if (workspaceUpdateDepth == 0 && (kind == ContextKind.Workspace || moved)) useWorkspace();
	}
	/** `machine/workspace/group` of the active context. */
	public function key():String
		return ContextKey.make(machineId, contextWorkspaceId, kind == ContextKind.Group ? id : "");
	/** Contexts remembered by an earlier run: the cold ones the quick switch should still know. */
	public function restoreRecent(infos:Array<ContextInfo>):Void {
		var known:Map<String, Bool> = [];
		for (info in recent) known.set(info.key(), true);
		for (info in infos) {
			info.machine = machineId == ContextKey.DEFAULT_MACHINE ? info.machine : machineId;
			if (recent.length >= RECENT_LIMIT) break;
			if (!known.exists(info.key())) { known.set(info.key(), true); recent.push(info); }
		}
	}
	/**
		The catalog named this machine. Saved keys move to it by `ContextKey.withMachine`; the context itself does
		not change, so nothing is published.
	**/
	public function assignMachine(id:String):Void {
		if (id == machineId || id.length == 0) return;
		machineId = id;
		for (info in recent) info.machine = id;
		onMachineAssigned(id);
	}
	/**
		A workspace got its real id (it was saved): the active context, a focused group included, keeps its place under
		the new id instead of being treated as another workspace opening.
	**/
	public function renameWorkspace(previous:String, next:String):Void {
		if (previous == next) return;
		if (workspaceId == previous) workspaceId = next;
		if (contextWorkspaceId == previous) contextWorkspaceId = next;
		for (info in recent) if (info.workspace == previous) info.workspace = next;
		var seen:Map<String, Bool> = [];
		for (info in recent.copy()) if (seen.exists(info.key())) recent.remove(info); else seen.set(info.key(), true);
	}
	/** Workspace ids the machine catalog has listed in this run, and the ids it lists now. */
	final seenWorkspaces:Map<String, Bool> = [];
	var catalogIds:Array<String> = [];
	/**
		A remembered context is gone when its workspace was listed by the catalog and no longer is (deleted), or when a
		group's folder is gone. A workspace the catalog never listed (opened from a file) is never gone for that reason.
	**/
	public function stillExists(info:ContextInfo, folderExists:String->Bool):Bool {
		if (info.key() == key()) return true;
		if (info.workspace != contextWorkspaceId && seenWorkspaces.exists(info.workspace) && catalogIds.indexOf(info.workspace) < 0) return false;
		return info.isRoot() || info.directory.length > 0 && folderExists(info.directory);
	}
	/** The catalog changed: note its workspaces and drop recents that are gone. */
	public function catalogChanged(ids:Array<String>, folderExists:String->Bool):Void {
		catalogIds = ids.copy();
		for (id in ids) seenWorkspaces.set(id, true);
		for (info in recent.copy()) if (!stillExists(info, folderExists)) recent.remove(info);
	}
	/** The workspace was deleted: its contexts leave the recent list. */
	public function forgetWorkspace(id:String):Void {
		for (entry in recent.copy()) if (entry.workspace == id && entry.workspace != contextWorkspaceId) recent.remove(entry);
	}
	/** Replacing a saved definition publishes one final context, never temporary roots/identity. */
	public function beginWorkspaceUpdate():Void workspaceUpdateDepth++;
	public function endWorkspaceUpdate():Void {
		if (workspaceUpdateDepth == 0) throw "Unbalanced workspace context update";
		workspaceUpdateDepth--;
		// A group of the old workspace must not outlive the move: another workspace shows its own root context.
		if (workspaceUpdateDepth == 0 && (kind == ContextKind.Workspace || contextWorkspaceId != workspaceId)) useWorkspace();
	}
	public function useWorkspace():Void publish(ContextKind.Workspace, workspaceId, workspaceLabel, workspaceRoots);
	public function focusGroup(id:String, label:String, directory:String):Void {
		if (id.length == 0 || directory.length == 0) throw "Group context requires identity and directory";
		publish(ContextKind.Group, id, label, [directory]);
	}
	/** Opening a session resolves inherited cwd from the current catalog, not the rendered tree. */
	public function openSessionGroup(id:String, groups:Array<workspace.service.WorkspaceProtocol.WorkspaceGroup>, root:String):Bool {
		var selected:Null<workspace.service.WorkspaceProtocol.WorkspaceGroup> = null;
		for (group in groups) if (group.id == id) selected = group;
		// A session at the workspace root works in the workspace itself.
		if (selected == null && workspace.service.WorkspaceProtocol.isRoot(id)) { useWorkspace(); return true; }
		if (selected == null) return false;
		var current = selected;
		var visited:Map<String, Bool> = [];
		var directory = root;
		while (current != null && !visited.exists(current.id)) {
			visited.set(current.id, true);
			if (current.cwd != null && current.cwd.length > 0) { directory = current.cwd; break; }
			var parent = current.parent;
			current = null;
			if (parent != null) for (group in groups) if (group.id == parent) current = group;
		}
		if (directory.length == 0) return false;
		focusGroup(selected.id, selected.name, directory);
		return true;
	}

	function publish(kind:ContextKind, id:String, label:String, roots:Array<String>):Void {
		var cwd = roots.length == 0 ? Sys.getCwd() : roots[0];
		if (this.kind == kind && this.id == id && this.label == label && this.roots.join("\n") == roots.join("\n") && this.cwd == cwd
			&& contextWorkspaceId == workspaceId) return;
		this.kind = kind; this.id = id; this.label = label; this.roots = roots.copy(); this.cwd = cwd;
		contextWorkspaceId = workspaceId;
		remember(new ContextInfo(machineId, workspaceId, kind == ContextKind.Group ? id : "", label, workspaceLabel, cwd));
		revision++;
		for (listener in listeners.copy()) listener();
	}
	function remember(info:ContextInfo):Void {
		var key = info.key();
		for (entry in recent.copy()) if (entry.key() == key) recent.remove(entry);
		recent.unshift(info);
		while (recent.length > RECENT_LIMIT) recent.pop();
	}
	public function contains(path:String):Bool {
		for (root in roots) if (path == root || StringTools.startsWith(path, root + "/")) return true;
		return false;
	}
	/** Group indexes are window-owned and never added to the saved workspace's roots. */
	public function projects():Array<Project> {
		var result:Array<Project> = [];
		for (root in roots) {
			var match:Null<Project> = null;
			for (project in workspace.projects) if (project.root == root) match = project;
			if (match == null && isAvailable(root)) {
				match = groupProjects.get(root);
				if (match == null) { match = new Project(root, workspace.fileSystem, workspace.jobs); groupProjects.set(root, match); }
			}
			if (match != null) result.push(match);
		}
		return result;
	}
	static function isAvailable(root:String):Bool
		return sys.FileSystem.exists(root) && sys.FileSystem.isDirectory(root);
	public function buildProject():Null<Project> {
		var active = workspace.activeProject;
		if (kind == ContextKind.Workspace && active != null && roots.indexOf(active.root) >= 0) return active;
		var projects = projects(); return projects.length == 0 ? null : projects[0];
	}
}
