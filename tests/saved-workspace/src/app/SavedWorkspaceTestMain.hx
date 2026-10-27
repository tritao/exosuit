package app;

import core.Application;
import workspace.SavedWorkspace;
import sys.FileSystem;
import sys.io.File;
import testing.model.ModelTextMetrics;
import testing.model.ModelWorkbenchHost;

class SavedWorkspaceTestMain {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }
	static function app():Application return new Application((theme, focus, workspace, settings) ->
		new ModelWorkbenchHost(new ModelTextMetrics("unused.ttf", 15), theme, focus, workspace, 640, 320, settings),
		new config.Preferences(), new session.RecentProjects(""));
	static function record(app:Application):SavedWorkspace {
		var value = app.savedWorkspaces.current;
		if (value == null) throw "missing saved workspace record";
		return value;
	}
	static function main():Int {
		var root = Sys.args()[0]; FileSystem.createDirectory(root); root = FileSystem.fullPath(root);
		var roots = [root + "/one", root + "/two", root + "/three"];
		for (path in roots) FileSystem.createDirectory(path);
		for (count in [1, 3]) {
			var record = SavedWorkspace.create("Named workspace", roots.slice(0, count));
			var decoded = SavedWorkspace.decode(record.encode());
			require(decoded.id == record.id && decoded.name == record.name && decoded.roots.join("|") == record.roots.join("|"), "workspace round trip changed identity or root order");
		}
		var a = app();
		for (path in roots) a.savedWorkspaces.addFolder(path);
		var file = root + "/Project.exosuit-workspace";
		require(a.savedWorkspaces.saveAs(file), "could not save workspace");
		var original = File.getContent(file), identity = record(a).id;
		var b = app(); require(b.savedWorkspaces.open(file), "second window failed to open workspace");
		a.savedWorkspaces.removeFolder(roots[1]);
		require(File.getContent(file) == original, "window root changes implicitly overwrote workspace record");
		require(a.savedWorkspaces.saveAs(file), "explicit save failed");
		b.savedWorkspaces.removeFolder(roots[2]);
		require(!b.savedWorkspaces.saveAs(file), "stale second window overwrote changed workspace record");
		require(SavedWorkspace.decode(File.getContent(file)).roots.join("|") == roots[0] + "|" + roots[2], "workspace record was corrupted");
		var missing = root + "/missing/deeper/root";
		var saved = new SavedWorkspace(identity, "With unavailable root", [roots[0], missing, roots[2]]);
		File.saveContent(file, saved.encode()); require(b.savedWorkspaces.open(file), "unavailable root aborted workspace open");
		require(b.workspace.projects.length == 2 && record(b).roots[1] == missing, "missing root was discarded or indexed");
		var snapshot = session.WorkspaceSession.decode(session.WorkspaceSession.capture(b).encode());
		var restored = app(); snapshot.restore(restored);
		require(record(restored).id == identity && record(restored).roots[1] == missing,
			"session did not preserve named workspace and unavailable roots");
		for (i in 0...12) a.savedWorkspaces.recents.add(root + "/recent-" + i + ".exosuit-workspace");
		require(a.savedWorkspaces.recents.paths.length == 10 && a.savedWorkspaces.recents.paths[0] == root + "/recent-11.exosuit-workspace", "workspace recents were not bounded MRU");
		a.savedWorkspaces.recents.remove(root + "/recent-5.exosuit-workspace");
		require(a.savedWorkspaces.recents.paths.length == 9 && a.savedWorkspaces.recents.paths.indexOf(root + "/recent-5.exosuit-workspace") < 0, "workspace recent was not removed");
		require(b.savedWorkspaces.isOpen() && b.savedWorkspaces.hasRoot(roots[0]) && !b.savedWorkspaces.hasRoot(root), "open workspace roots were not reported");
		require(b.commands.isValid("workspace:close", b.context), "Close Workspace was unavailable for an open workspace");
		b.commands.perform("workspace:close", b.context);
		require(b.workspace.projects.length == 0 && b.savedWorkspaces.current == null && b.savedWorkspaces.path == "" && b.activeContext.roots.length == 0,
			"Close Workspace left roots, record or context behind");
		require(!b.savedWorkspaces.isOpen() && !b.commands.isValid("workspace:close", b.context), "Close Workspace stayed available after closing");
		require(File.getContent(file) == SavedWorkspace.decode(File.getContent(file)).encode(), "Close Workspace changed the workspace file");
		var closed = session.WorkspaceSession.decode(session.WorkspaceSession.capture(b).encode());
		require(closed.savedWorkspace == null && closed.workspaceFile == "" && closed.projects.length == 0, "closed workspace was saved in the session");
		var reopened = app(); closed.restore(reopened);
		require(reopened.workspace.projects.length == 0 && !reopened.savedWorkspaces.isOpen(), "closed workspace came back after restart");
		a.shutdown(); b.shutdown(); restored.shutdown(); reopened.shutdown();
		trace("PASS: saved workspace identity, 1/3 ordered roots, explicit saves, two-window conflict, unavailable root, session, recents and close");
		return 0;
	}
}
