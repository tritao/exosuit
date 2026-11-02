package app;

import core.Application;
import sys.FileSystem;
import sys.io.File;
import testing.model.ModelTextMetrics;
import testing.model.ModelWorkbenchHost;
import workspace.ContextKind;

class ActiveContextTestMain {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }
	static function main():Int {
		var base = Sys.args()[0]; FileSystem.createDirectory(base); base = StringTools.replace(FileSystem.fullPath(base), "\\", "/");
		var first = base + "/workspace", group = base + "/group";
		for (root in [first, group]) { FileSystem.createDirectory(root); File.saveContent(root + "/file.txt", "needle\n"); }
		FileSystem.createDirectory(group + "/.pragtical");
		File.saveContent(group + "/.pragtical/tasks.conf", "task=Group task\nexecutable=echo\n");
		var app = new Application((theme, focus, workspace, settings) -> new ModelWorkbenchHost(new ModelTextMetrics("unused.ttf", 15), theme, focus, workspace, 640, 320, settings), new config.Preferences(), new session.RecentProjects(""));
		app.openArgument(first);
		require(app.activeContext.kind == ContextKind.Workspace && app.activeContext.cwd == first, "default context changed workspace behavior");
		var changes = 0, unsubscribe = app.activeContext.subscribe(function() changes++);
		app.activeContext.focusGroup("group-1", "Group", group);
		require(changes == 1 && app.activeContext.roots[0] == group && app.activeContext.cwd == group && !app.activeContext.contains(first), "group context did not publish one coherent scope");
		var projects = app.workspace.scopedProjects();
		require(projects.length == 1 && projects[0].root == group && app.workspace.projects.length == 1 && app.workspace.projects[0].root == first,
			"group indexing mutated saved workspace roots");
		app.workspace.jobs.update(128);
		app.workspaceSearch.request("needle", app.searchOptions, 100); app.workspaceSearch.flush();
		for (_ in 0...100) if (!app.workspaceSearch.complete) app.workspace.jobs.update(128);
		require(app.workspaceSearch.complete && app.workspaceSearch.results.length == 1 && app.workspaceSearch.results[0].path == group + "/file.txt", "search escaped group context");
		require(app.build.openTaskPicker(), "build task picker did not use context project");
		var host:ModelWorkbenchHost = cast app.root;
		require(host.commandView.results.length == 1 && host.commandView.results[0].label == "Group task", "build listed tasks from workspace instead of group");
		host.closeCommandView();
		app.activeContext.useWorkspace();
		require(changes == 2 && app.activeContext.roots[0] == first && app.workspaceSearch.results.length == 0, "context switch retained stale search results");
		unsubscribe(); app.activeContext.focusGroup("group-1", "Group", group);
		require(changes == 2, "context listener survived unsubscribe");
		app.activeContext.useWorkspace();
		var replacements = 0, release = app.activeContext.subscribe(function() replacements++);
		app.savedWorkspaces.restore(workspace.SavedWorkspace.create("Two roots", [first, group]), "");
		require(replacements == 1 && app.activeContext.roots.length == 2, "workspace replacement published intermediate layout identities");
		release();
		var groups:Array<workspace.service.WorkspaceProtocol.WorkspaceGroup> = [
			{id:"parent", name:"Parent", cwd:group, parent:null, revision:1, order:0},
			{id:"child", name:"Child", cwd:null, parent:"parent", revision:1, order:0},
			{id:"default", name:"Default", cwd:null, parent:null, revision:1, order:1}
		];
		require(app.activeContext.openSessionGroup("child", groups, first) && app.activeContext.id == "child"
			&& app.activeContext.cwd == group, "opening session did not inherit group directory");
		var revision = app.activeContext.revision;
		app.activeContext.openSessionGroup("child", groups, first);
		require(app.activeContext.revision == revision, "reopening same group republished context");
		require(!app.activeContext.openSessionGroup("missing", groups, first) && app.activeContext.id == "child", "missing group changed context");
		require(app.activeContext.openSessionGroup("default", groups, first) && app.activeContext.cwd == first, "default group did not use catalog root");
		// A group with the workspace's own folder is still a context of its own: keyed by id, never by folder.
		var defaultKey = app.activeContext.key();
		app.activeContext.useWorkspace();
		require(app.activeContext.kind == ContextKind.Workspace && app.activeContext.roots.length == 2, "back lost saved workspace roots");
		require(defaultKey != app.activeContext.key() && StringTools.endsWith(defaultKey, "/default") && !StringTools.endsWith(app.activeContext.key(), "/default"),
			"a group with the workspace folder shares the root's context key: " + defaultKey + " vs " + app.activeContext.key());
		require(app.activeContext.openSessionGroup("default", groups, first) && app.activeContext.key() == defaultKey, "the group's key changed between visits");
		app.activeContext.useWorkspace();
		// A workspace's folders come from its definition: Add Folder joins, opening another folder replaces the workspace.
		var other = base + "/other"; FileSystem.createDirectory(other);
		app.savedWorkspaces.restore(workspace.SavedWorkspace.create("One root", [first]), "");
		require(app.activeContext.roots.length == 1 && app.activeContext.roots[0] == first, "workspace did not start with its own folder");
		app.attachFolder(other);
		require(app.activeContext.roots.length == 2 && app.savedWorkspaces.current != null, "Add Folder did not join the workspace");
		app.savedWorkspaces.removeFolder(other);
		app.openArgument(other);
		require(app.savedWorkspaces.current == null && app.activeContext.roots.length == 1 && app.activeContext.roots[0] == other,
			"opening another folder joined the open workspace instead of replacing it: " + app.activeContext.roots.join(","));
		app.savedWorkspaces.close(); app.openArgument(first);
		app.savedWorkspaces.adoptMachineWorkspace("machine-ws", "Machine");
		require(app.savedWorkspaces.workspaceId() == "machine-ws" && app.activeContext.roots.length == 1, "machine workspace was not adopted");
		app.openArgument(other);
		require(app.savedWorkspaces.workspaceId() == null && app.activeContext.roots.length == 1 && app.activeContext.roots[0] == other,
			"opening another folder joined the adopted machine workspace: " + app.activeContext.roots.join(","));
		app.shutdown();
		trace("PASS: workspace default, coherent context event, independent group indexes, scoped search/build tasks and stale-result cancellation");
		return 0;
	}
}
