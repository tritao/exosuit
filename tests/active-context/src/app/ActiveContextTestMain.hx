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
		var base = Sys.args()[0]; FileSystem.createDirectory(base); base = FileSystem.fullPath(base);
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
		app.shutdown();
		trace("PASS: workspace default, coherent context event, independent group indexes, scoped search/build tasks and stale-result cancellation");
		return 0;
	}
}
