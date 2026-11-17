package controller;

import core.Application;
import commandview.CommandViewEntry;
import commandview.CommandViewProvider;
import workspace.SavedWorkspace;
import sys.FileSystem;

/** The workspace the window is on: one the Workbench lists (see `restore`), or loose folders. */
class SavedWorkspaceController {
	public var current(default, null):Null<SavedWorkspace>;
	public var onChanged:Void->Void = function() {};
	var restoring:Bool = false;
	public var chooseFolder:Null<Void->Void>;
	final app:Application;
	public function new(app:Application) {
		this.app = app;
		app.activeContext.workspaceFolders = roots;
		if (!app.capabilities.supports(platform.HostCapability.Filesystem)) return;
		app.commands.add("workspace:add-folder", _ -> addPicker(), null, "Add Folder to Workspace…");
		app.commands.add("workspace:remove-folder", _ -> removePicker(), _ -> roots().length > 0, "Remove Folder from Workspace…");
		app.commands.add("workspace:close", _ -> close(), _ -> isOpen(), "Close Workspace");
	}
	function changed():Void {
		if (restoring) return;
		app.activeContext.updateWorkspace(current != null ? current.id : "workspace", current != null ? current.name : "Workspace", roots());
		onChanged();
	}
	/** The workspace's name for the title bar; null for loose folders. */
	public function displayName():Null<String>
		return current != null ? current.name : null;
	/** The workspace the window is on; null for loose folders. */
	public function workspaceId():Null<String>
		return current != null ? current.id : null;
	public function roots():Array<String>
		return current != null ? current.roots.copy() : [for (project in app.workspace.projects) project.root];
	/** True while the window shows any workspace folder or a named workspace. */
	public function isOpen():Bool return current != null || roots().length > 0;
	public function hasRoot(folder:String):Bool {
		for (root in roots()) if (workspace.PathKey.same(root, folder)) return true;
		return false;
	}
	public function folderOpened(root:String):Void {
		var record = current;
		if (record != null && !SavedWorkspace.hasRoot(record.roots, root)) record.roots.push(root);
		changed();
	}
	/** Opens the workspace `record` names in this window: how a Workbench row, or the session, opens one. */
	public function restore(record:SavedWorkspace):Void {
		app.activeContext.beginWorkspaceUpdate(); restoring = true;
		try {
			for (project in app.workspace.projects.copy()) app.workspace.removeProject(project);
			// The window moves to the record's identity; the workspace it leaves keeps its contexts under its own id.
			current = null;
			for (root in record.roots) if (available(root)) app.attachFolder(root);
			current = record.copy();
			app.activeContext.updateWorkspace(record.id, record.name, record.roots);
		} catch (error:Dynamic) {
			restoring = false; app.activeContext.endWorkspaceUpdate(); throw error;
		}
		restoring = false; app.activeContext.endWorkspaceUpdate(); onChanged();
	}

	public function addFolder(folder:String):Bool {
		if (!available(folder)) { app.reportError("workspace", 'Folder is unavailable: "' + folder + '"'); return false; }
		app.attachFolder(folder); return true;
	}
	public function removeFolder(folder:String):Void {
		for (project in app.workspace.projects.copy()) if (workspace.PathKey.same(project.root, folder)) app.workspace.removeProject(project);
		var record = current;
		if (record != null) { for (root in record.roots.copy()) if (workspace.PathKey.same(root, folder)) record.roots.remove(root); }
		changed();
	}
	public function close():Void {
		for (project in app.workspace.projects.copy()) app.workspace.removeProject(project);
		current = null;
		changed();
	}
	public static function available(root:String):Bool return FileSystem.exists(root) && FileSystem.isDirectory(root);
	function prompt(label:String, action:String->Bool):Void {
		app.root.openCommandView(new CommandViewProvider(label, [], _ -> {}, function(_, value, _) {
			if (action(value)) app.root.closeCommandView();
		}));
	}
	public function addPicker():Void { if (chooseFolder != null) chooseFolder(); else prompt("Add Folder to Workspace: ", addFolder); }
	public function removePicker():Void {
		app.root.openCommandView(new CommandViewProvider("Remove Folder: ", [for (root in roots()) new CommandViewEntry(root, available(root) ? "" : "Unavailable", root)], _ -> {}, function(entry, _, _) {
			if (entry != null) removeFolder(entry.value);
			app.root.closeCommandView();
		}));
	}
}
