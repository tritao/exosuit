package workspace;

/** Window-local scope. Selecting a tree row never changes this object. */
class ActiveContext {
	public var kind(default, null):ContextKind = ContextKind.Workspace;
	public var id(default, null):String = "workspace";
	public var label(default, null):String = "Workspace";
	public var roots(default, null):Array<String> = [];
	public var cwd(default, null):String = Sys.getCwd();
	public var revision(default, null):Int = 0;
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
			workspaceRoots = [for (project in workspace.projects) project.root];
			if (kind == ContextKind.Workspace && workspaceUpdateDepth == 0) publish(ContextKind.Workspace, workspaceId, workspaceLabel, workspaceRoots);
		});
	}
	public function subscribe(listener:Void->Void):Void->Void {
		listeners.push(listener);
		return function() { listeners.remove(listener); };
	}
	public function updateWorkspace(id:String, label:String, roots:Array<String>):Void {
		workspaceId = id; workspaceLabel = label; workspaceRoots = roots.copy();
		if (kind == ContextKind.Workspace && workspaceUpdateDepth == 0) useWorkspace();
	}
	/** Replacing a saved definition publishes one final context, never temporary roots/identity. */
	public function beginWorkspaceUpdate():Void workspaceUpdateDepth++;
	public function endWorkspaceUpdate():Void {
		if (workspaceUpdateDepth == 0) throw "Unbalanced workspace context update";
		workspaceUpdateDepth--;
		if (workspaceUpdateDepth == 0 && kind == ContextKind.Workspace) useWorkspace();
	}
	public function useWorkspace():Void publish(ContextKind.Workspace, workspaceId, workspaceLabel, workspaceRoots);
	public function focusGroup(id:String, label:String, directory:String):Void {
		if (id.length == 0 || directory.length == 0) throw "Group context requires identity and directory";
		publish(ContextKind.Group, id, label, [directory]);
	}
	function publish(kind:ContextKind, id:String, label:String, roots:Array<String>):Void {
		var cwd = roots.length == 0 ? Sys.getCwd() : roots[0];
		if (this.kind == kind && this.id == id && this.label == label && this.roots.join("\n") == roots.join("\n") && this.cwd == cwd) return;
		this.kind = kind; this.id = id; this.label = label; this.roots = roots.copy(); this.cwd = cwd;
		revision++;
		for (listener in listeners.copy()) listener();
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
