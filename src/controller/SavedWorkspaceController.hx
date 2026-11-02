package controller;

import core.Application;
import commandview.CommandViewEntry;
import commandview.CommandViewProvider;
import workspace.SavedWorkspace;
import sys.FileSystem;
import sys.io.File;

/** Explicit workspace publication is separate from window/session autosave. */
class SavedWorkspaceController {
	public var current(default, null):Null<SavedWorkspace>;
	public var path(default, null):String = "";
	public var dirty(default, null):Bool = false;
	public final recents:session.RecentWorkspaces;
	public var onChanged:Void->Void = function() {};
	public var onIdentityAssigned:(String, String)->Void = function(_, _) {};
	var restoring:Bool = false;
	public var chooseOpen:Null<Void->Void>;
	public var chooseSaveAs:Null<Void->Void>;
	public var chooseFolder:Null<Void->Void>;
	final app:Application;
	var savedContent:String = "";
	public function new(app:Application) {
		this.app = app;
		app.activeContext.workspaceFolders = roots;
		recents = new session.RecentWorkspaces(config.ConfigurationPaths.configurationRoot() + "/recent-workspaces.conf");
		if (recents.error != null) app.reportError("workspace", recents.error);
		if (!app.capabilities.supports(platform.HostCapability.Filesystem)) return;
		app.commands.add("workspace:open", _ -> openPicker(), null, "Open Workspace…");
		app.commands.add("workspace:save", _ -> { if (path.length == 0) savePicker(); else saveAs(path); }, null, "Save Workspace");
		app.commands.add("workspace:save-as", _ -> savePicker(), null, "Save Workspace As…");
		app.commands.add("workspace:add-folder", _ -> addPicker(), null, "Add Folder to Workspace…");
		app.commands.add("workspace:remove-folder", _ -> removePicker(), _ -> roots().length > 0, "Remove Folder from Workspace…");
		app.commands.add("workspace:recent", _ -> recentPicker(), null, "Open Recent Workspace…");
		app.commands.add("workspace:close", _ -> close(), _ -> isOpen(), "Close Workspace");
	}
	/** The machine workspace this window's folder opened from the command line belongs to, once suit's catalog names it. */
	var machineId:Null<String>;
	var machineName:String = "Workspace";

	/**
		A window opened on a workspace's folder (not on a saved workspace file) works in that machine workspace: its
		context takes the workspace's id, and the contexts saved under the placeholder id follow, as when a workspace is saved.
	**/
	public function adoptMachineWorkspace(id:String, name:String):Void {
		if (current != null) return;
		if (machineId == id) {
			// The catalog renamed the workspace: the context's label follows.
			if (machineName != name) { machineName = name; changed(); }
			return;
		}
		var previous = machineId != null ? machineId : "workspace";
		machineId = id; machineName = name;
		onIdentityAssigned(previous, id);
		changed();
	}

	/**
		The window no longer shows exactly one machine workspace's folder (another folder was added, the folder was
		removed or the workspace closed): the adopted id goes and the context goes back under the placeholder.
	**/
	public function releaseMachineWorkspace():Void {
		if (machineId == null) return;
		var previous:String = machineId;
		machineId = null; machineName = "Workspace";
		if (current == null) onIdentityAssigned(previous, "workspace");
		changed();
	}

	/** The id contexts are saved under now: the saved workspace's, else the adopted machine workspace's, else the placeholder. */
	function contextWorkspaceId():String
		return current != null ? current.id : machineId != null ? machineId : "workspace";
	function changed():Void {
		if (restoring) return;
		app.activeContext.updateWorkspace(current != null ? current.id : machineId != null ? machineId : "workspace",
			current != null ? current.name : machineId != null ? machineName : "Workspace", roots());
		onChanged();
	}
	/** The workspace's name for the title bar: the saved or machine workspace the window is on; null for a plain folder. */
	public function displayName():Null<String>
		return current != null ? current.name + (dirty ? " *" : "") : machineId != null ? machineName : null;
	/** The workspace the window is on: the saved workspace's id, else the adopted machine workspace's, else null (a plain folder). */
	public function workspaceId():Null<String>
		return current != null ? current.id : machineId;
	public function roots():Array<String>
		return current == null ? [for (project in app.workspace.projects) project.root] : current.roots.copy();
	/** True while the window shows any workspace folder or a named workspace. */
	public function isOpen():Bool return current != null || roots().length > 0;
	public function hasRoot(folder:String):Bool {
		for (root in roots()) if (workspace.PathKey.same(root, folder)) return true;
		return false;
	}
	public function folderOpened(root:String):Void {
		if (current != null && current.roots.indexOf(root) < 0) { current.roots.push(root); dirty = true; }
		changed();
	}
	public function restore(record:SavedWorkspace, file:String):Void {
		var content = file.length > 0 && FileSystem.exists(file) ? File.getContent(file) : "";
		app.activeContext.beginWorkspaceUpdate(); restoring = true;
		try {
			for (project in app.workspace.projects.copy()) app.workspace.removeProject(project);
			current = null;
			for (root in record.roots) if (available(root)) app.openArgument(root);
			machineId = null; machineName = "Workspace";
			current = record.copy(); path = file; dirty = false; savedContent = content;
			app.activeContext.updateWorkspace(record.id, record.name, record.roots);
		} catch (error:Dynamic) {
			restoring = false; app.activeContext.endWorkspaceUpdate(); throw error;
		}
		restoring = false; app.activeContext.endWorkspaceUpdate(); onChanged();
	}

	public function open(file:String):Bool {
		try {
			var record = SavedWorkspace.decode(File.getContent(file));
			restore(record, FileSystem.fullPath(file));
			recents.add(path);
			return true;
		} catch (error:Dynamic) { app.reportError("workspace", "Could not open workspace: " + Std.string(error)); return false; }
	}
	public function saveAs(file:String):Bool {
		try {
			var target = app.workspace.fileSystem.normalize(file);
			if (FileSystem.exists(target) && (target != path || File.getContent(target) != savedContent))
				throw "The workspace file already exists or changed in another window. Choose a new name with Save Workspace As.";
			var name = SavedWorkspace.nameFromPath(target);
			var record = current == null ? SavedWorkspace.create(name, roots()) : current.copy();
			if (target != path) record.name = name;
			var content = record.encode();
			if (FileSystem.exists(target)) sys.io.AtomicFile.write(target, content); else sys.io.AtomicFile.create(target, content);
			var previousId = contextWorkspaceId();
			machineId = null; machineName = "Workspace";
			current = record; path = target; savedContent = content; dirty = false;
			if (previousId != record.id) onIdentityAssigned(previousId, record.id);
			recents.add(target); changed(); return true;
		} catch (error:Dynamic) { app.reportError("workspace", "Could not save workspace: " + Std.string(error)); return false; }
	}
	public function addFolder(folder:String):Bool {
		if (!available(folder)) { app.reportError("workspace", 'Folder is unavailable: "' + folder + '"'); return false; }
		app.attachFolder(folder); return true;
	}
	public function removeFolder(folder:String):Void {
		for (project in app.workspace.projects.copy()) if (project.root == folder) app.workspace.removeProject(project);
		if (current != null) { current.roots.remove(folder); dirty = true; }
		changed();
	}
	public function close():Void {
		for (project in app.workspace.projects.copy()) app.workspace.removeProject(project);
		var adopted = machineId;
		current = null; path = ""; savedContent = ""; dirty = false;
		if (adopted != null) { releaseMachineWorkspace(); return; }
		changed();
	}
	public static function available(root:String):Bool return FileSystem.exists(root) && FileSystem.isDirectory(root);
	function prompt(label:String, action:String->Bool):Void {
		app.root.openCommandView(new CommandViewProvider(label, [], _ -> {}, function(_, value, _) {
			if (action(value)) app.root.closeCommandView();
		}));
	}
	public function openPicker():Void { if (chooseOpen != null) chooseOpen(); else prompt("Open Workspace: ", open); }
	public function savePicker():Void { if (chooseSaveAs != null) chooseSaveAs(); else prompt("Save Workspace As: ", saveAs); }
	public function addPicker():Void { if (chooseFolder != null) chooseFolder(); else prompt("Add Folder to Workspace: ", addFolder); }
	public function removePicker():Void {
		app.root.openCommandView(new CommandViewProvider("Remove Folder: ", [for (root in roots()) new CommandViewEntry(root, available(root) ? "" : "Unavailable", root)], _ -> {}, function(entry, _, _) {
			if (entry != null) removeFolder(entry.value);
			app.root.closeCommandView();
		}));
	}
	public function recentPicker():Void {
		recents.reload();
		app.root.openCommandView(new CommandViewProvider("Open Recent Workspace: ", [for (file in recents.paths) new CommandViewEntry(haxe.io.Path.withoutDirectory(file), file, file)], _ -> {}, function(entry, _, _) {
			if (entry != null && open(entry.value)) app.root.closeCommandView();
		}));
	}
}
