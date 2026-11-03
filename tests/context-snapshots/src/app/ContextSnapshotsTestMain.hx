package app;

import session.ContextLayoutStore;
import session.ContextSnapshotStore;
import session.WorkspaceSession;
import sys.FileSystem;
import sys.io.File;
import ui.UiWorkbenchHost;
import workspace.ContextKey;

private typedef Window = {host:UiWorkbenchHost, store:ContextSnapshotStore};

/**
	Phase 8 of docs/roadmap/19-machine-workspaces.md, the restore part: one snapshot file per context, last write
	wins per group. A "window" here is a real workbench host plus its own store handle on the shared folder, doing
	what SessionPersistence does (split the host's lines, `sync`) and what a restart does (`mergedLayout`, restore).
**/
class ContextSnapshotsTestMain {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }

	static function newHost(workspace:workspace.Workspace, dock:haxeon.ui.docking.DockWorkspaceModel):UiWorkbenchHost
		return new UiWorkbenchHost(new style.Theme(), new core.FocusManager(), workspace, new config.Settings(), function() {}, {
			model: dock, focusEditor: function(_) {}, editorPreedit: function(_, _) {},
			toggleSidebar: function() return false, activateExplorer: function() {},
			activateProblems: function() {}, activateBuild: function() {}
		});

	static function freshDock():haxeon.ui.docking.DockWorkspaceModel {
		var dock = new haxeon.ui.docking.DockWorkspaceModel();
		dock.register(new haxeon.ui.docking.DockPanelDescriptor("editor", "Editor"));
		dock.setDefaultLayout(haxeon.ui.docking.DockNode.Panel("editor"));
		return dock;
	}

	static function window(workspace:workspace.Workspace, folder:String, focus:String):Window {
		var host = newHost(workspace, freshDock());
		host.initializeContext(focus);
		return {host: host, store: new ContextSnapshotStore(folder)};
	}

	/** What the window's periodic save does: split its lines and sync the context files. Returns the session.conf part. */
	static function save(w:Window):WorkspaceSession {
		var session = new WorkspaceSession();
		session.takeLayout(w.host.sessionLines());
		w.store.sync(session.contexts);
		return session;
	}

	/** A restart: a new window restores `session` (as decoded from its encoding) with the files in `folder`. */
	static function restart(workspace:workspace.Workspace, folder:String, session:WorkspaceSession, focus:String):UiWorkbenchHost {
		var host = newHost(workspace, freshDock());
		host.initializeContext(focus);
		host.restoreSessionLines(WorkspaceSession.decode(session.encode()).mergedLayout(new ContextSnapshotStore(folder)));
		return host;
	}

	static function go(host:UiWorkbenchHost, key:String):UiWorkbenchHost {
		if (host.layoutContextKey != key) host.switchContext(key);
		return host;
	}

	static function tabs(host:UiWorkbenchHost, key:String):Array<String> {
		go(host, key);
		return [for (view in host.tabs) view.document.path];
	}

	static function removeFolder(path:String):Void {
		if (!FileSystem.exists(path)) return;
		for (name in FileSystem.readDirectory(path)) {
			var child = path + "/" + name;
			if (FileSystem.isDirectory(child)) removeFolder(child); else FileSystem.deleteFile(child);
		}
		FileSystem.deleteDirectory(path);
	}

	static function countFiles(folder:String):Int {
		var count = 0;
		for (name in FileSystem.readDirectory(folder)) if (StringTools.endsWith(name, ".json")) count++;
		return count;
	}

	static function main():Int {
		var base = "build/context-snapshots";
		removeFolder(base);
		FileSystem.createDirectory(base);
		var files:Array<String> = [];
		for (name in ["a.txt", "b.txt", "c.txt", "d.txt"]) {
			File.saveContent(base + "/" + name, "x\n");
		}
		var workspace = new workspace.Workspace(new syntax.SyntaxRegistry());
		var root = StringTools.replace(FileSystem.fullPath(base), "\\", "/");
		var file = function(name:String) return workspace.fileSystem.normalize(root + "/" + name + ".txt");
		var folder = root + "/contexts";
		var machine = "m1";
		var g1 = ContextKey.make(machine, "ws", "g1"), g2 = ContextKey.make(machine, "ws", "g2"), g3 = ContextKey.make(machine, "ws", "g3");

		// Open in New Window: the command line of the new window, plain and under `run.py --live`.
		var plain = workspace.NewWindow.arguments("main.hl", g1);
		require(plain.join("|") == "main.hl|--context=" + g1, "plain command line: " + plain.join("|"));
		var live = workspace.NewWindow.arguments("LiveHost.hl", g1, "C:/x/live.hl", "app.GraphicalMain");
		require(live.length == 4 && live[0] == "LiveHost.hl" && live[1] == "C:/x/live.hl" && live[2] == "app.GraphicalMain", "live command line: " + live.join("|"));
		var liveArguments:Array<String> = haxe.Json.parse(live[3]);
		require(workspace.NewWindow.contextOf(liveArguments) == g1, "the live host's arguments do not carry the context: " + live[3]);
		require(workspace.NewWindow.arguments("main.hl", g1, "", null).join("|") == plain.join("|"), "an unset live module changed the plain command line");
		require(workspace.NewWindow.automationDirectory(null, 1) == "" && workspace.NewWindow.automationDirectory("d", 1) == "d"
			&& workspace.NewWindow.automationDirectory("d", 2) == "d-2", "automation folders of new windows");

		// File names: stable, safe, distinct, and not confused by case.
		require(ContextSnapshotStore.fileName(g1) == ContextSnapshotStore.fileName(g1), "file name is not stable");
		require(ContextSnapshotStore.fileName(g1) != ContextSnapshotStore.fileName(g2), "two groups share a file");
		require(ContextSnapshotStore.fileName(ContextKey.make("m", "W", "g")).toLowerCase() != ContextSnapshotStore.fileName(ContextKey.make("m", "w", "g")).toLowerCase(),
			"case-insensitive file systems would merge two groups");
		var odd = ContextSnapshotStore.fileName(ContextKey.make("m:1", "a b/c\\d*?\"<>|", "ü\t\n"));
		for (i in 0...odd.length) require("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.".indexOf(odd.charAt(i)) >= 0, "unsafe character in file name: " + odd);

		// Per-group round trip: tabs of three groups, then a restart reads each from its own file.
		var a = window(workspace, folder, g1);
		a.host.openFile(file("a"), false);
		go(a.host, g2).openFile(file("b"), false); a.host.openFile(file("c"), false);
		go(a.host, g3).openFile(file("d"), false);
		go(a.host, g1);
		var sessionA = save(a);
		require(countFiles(folder) == 3, "expected one file per group, found " + countFiles(folder));
		require(sessionA.encode().indexOf("Z\tcontext") < 0 && sessionA.encode().indexOf("Z\\tcontext") < 0, "session.conf still carries other contexts' tabs");
		var restarted = restart(workspace, folder, sessionA, g1);
		require(restarted.layoutContextKey == g1 && tabs(restarted, g1).join(",") == file("a"), "focused group lost its tabs: " + tabs(restarted, g1).join(","));
		require(tabs(restarted, g2).join(",") == [file("b"), file("c")].join(","), "group 2 tabs did not come back: " + tabs(restarted, g2).join(","));
		require(tabs(restarted, g3).join(",") == file("d"), "group 3 tabs did not come back");

		// Unchanged contexts are not rewritten, so a window that only restored never becomes the "latest writer".
		require(a.store.sync(sessionA.contexts) == 0, "an unchanged sync wrote files");

		// Two windows start from the same files. Window 1 changes g1 and g3; then window 2 changes g1 and g2.
		var w1 = window(workspace, folder, g1), w2 = window(workspace, folder, g1);
		for (w in [w1, w2]) w.host.restoreSessionLines(WorkspaceSession.decode(sessionA.encode()).mergedLayout(w.store));
		go(w1.host, g1).openFile(file("b"), false);
		go(w1.host, g3).openFile(file("a"), false);
		go(w1.host, g1);
		save(w1);
		go(w2.host, g1).openFile(file("c"), false);
		go(w2.host, g2).openFile(file("d"), false);
		go(w2.host, g1);
		var sessionW2 = save(w2);
		// Window 1 saved first, so window 2 wins g1; g2 is window 2's; g3 only window 1 touched and is kept.
		var after = restart(workspace, folder, sessionW2, g1);
		var g1Tabs = tabs(after, g1);
		require(g1Tabs.indexOf(file("c")) >= 0 && g1Tabs.indexOf(file("b")) < 0, "later writer did not win g1: " + g1Tabs.join(","));
		require(tabs(after, g2).indexOf(file("d")) >= 0, "g2 lost window 2's tab");
		var g3Tabs = tabs(after, g3);
		require(g3Tabs.indexOf(file("a")) >= 0 && g3Tabs.indexOf(file("d")) >= 0, "g3, touched only by window 1, was overwritten: " + g3Tabs.join(","));

		// Window 1 saves g1 again, now after window 2: its g1 wins, and its save leaves window 2's g2 alone.
		go(w1.host, g1).openFile(file("d"), false);
		var sessionW1 = save(w1);
		var again = restart(workspace, folder, sessionW1, g1);
		require(tabs(again, g1).indexOf(file("d")) >= 0, "the newest write of g1 did not win");
		require(tabs(again, g2).indexOf(file("d")) >= 0, "window 1's save overwrote g2, which only window 2 changed");

		// A window never deletes what it never saw, and deletes what it knew and closed.
		var unseenKey = ContextKey.make(machine, "ws", "unseen");
		var scratch = new WorkspaceSession();
		scratch.takeLayout(w1.host.sessionLines());
		new ContextSnapshotStore(folder).write(unseenKey, scratch.contexts.get(scratch.activeKey));
		save(w1);
		require(FileSystem.exists(w1.store.pathFor(unseenKey)), "a window deleted a context file it never knew");
		go(w1.host, g1).forgetContext(g3);
		save(w1);
		require(!FileSystem.exists(w1.store.pathFor(g3)), "a closed group's file stayed");

		// Compare and delete: A read B's file at start and its host dropped the context. If B rewrote the file since,
		// it survives; if B did not, it goes.
		var cdFolder = root + "/contexts-compare";
		var keep2 = ContextKey.make(machine, "ws", "kept"), gone2 = ContextKey.make(machine, "ws", "gone");
		var base2 = scratch.contexts.get(scratch.activeKey);
		var storeB = new ContextSnapshotStore(cdFolder), storeA = new ContextSnapshotStore(cdFolder);
		storeB.write(keep2, base2); storeB.write(gone2, base2);
		storeA.readAll();
		storeB.write(keep2, base2.concat(["Q\teditor"]));
		storeA.sync(new Map<String, Array<String>>());
		require(FileSystem.exists(storeA.pathFor(keep2)), "a window deleted a file another window rewrote");
		require(!FileSystem.exists(storeA.pathFor(gone2)), "an unchanged dropped context's file stayed");
		// Crash between saves: what the last save wrote comes back; edits after it are lost, other groups are not.
		var crashFolder = root + "/contexts-crash";
		var crash = window(workspace, crashFolder, g1);
		crash.host.openFile(file("a"), false);
		go(crash.host, g2).openFile(file("b"), false);
		go(crash.host, g1);
		var lastSession = save(crash);
		crash.host.openFile(file("c"), false); // never saved: the window dies here
		var crashed = restart(workspace, crashFolder, lastSession, g1);
		require(tabs(crashed, g1).join(",") == file("a"), "an edit made after the last save came back: " + tabs(crashed, g1).join(","));
		require(tabs(crashed, g2).join(",") == file("b"), "a crash lost a group saved earlier");

		// A damaged file is skipped, not fatal, and left in place.
		var damaged = folder + "/broken-0000000000000000.json";
		File.saveContent(damaged, "{not json");
		require(new ContextSnapshotStore(folder).readAll().length > 0 && FileSystem.exists(damaged), "a damaged file broke the folder or was removed");

		// Migration: an old session.conf carries the other contexts' tabs as Z lines, and no files exist yet.
		var oldFolder = root + "/contexts-migrated";
		var old = window(workspace, oldFolder, g1);
		old.host.openFile(file("a"), false);
		go(old.host, g2).openFile(file("b"), false);
		go(old.host, g1);
		var oldConf = new WorkspaceSession();
		for (line in old.host.sessionLines()) oldConf.layout.push(line); // the pre-Phase-8 shape: everything in session.conf
		var decodedOld = WorkspaceSession.decode(oldConf.encode());
		var migrating = new ContextSnapshotStore(oldFolder);
		var merged = decodedOld.mergedLayout(migrating);
		require(ContextLayoutStore.read(merged).layouts.exists(g2), "old session.conf contexts were not kept when no files exist");
		var migrated = newHost(workspace, freshDock());
		migrated.initializeContext(g1);
		migrated.restoreSessionLines(merged);
		require(tabs(migrated, g2).join(",") == file("b"), "migrated group lost its tabs");
		go(migrated, g1);
		var migratedSession = new WorkspaceSession();
		migratedSession.takeLayout(migrated.sessionLines());
		migrating.sync(migratedSession.contexts);
		require(FileSystem.exists(migrating.pathFor(g2)) && FileSystem.exists(migrating.pathFor(g1)), "migration did not write the files");
		// The next start: the old conf still has its lines (an older version may have rewritten it), the files win.
		var twice = decodedOld.mergedLayout(new ContextSnapshotStore(oldFolder));
		var zCount = 0;
		for (line in twice) if (StringTools.startsWith(line, "Z\tcontext\t")) zCount++;
		require(zCount == 2, "files plus old conf lines doubled the contexts: " + zCount);

		// Off the asking turn: request/pump write on a background thread; nothing is written by request itself.
		var asyncFolder = root + "/contexts-async";
		var asyncStore = new ContextSnapshotStore(asyncFolder);
		var asyncLines = scratch.contexts.get(scratch.activeKey);
		var asyncKey = ContextKey.make(machine, "ws", "async");
		var requested:Map<String, Array<String>> = [asyncKey => asyncLines];
		asyncStore.request(requested);
		require(!FileSystem.exists(asyncFolder), "request wrote on the asking turn");
		asyncStore.pump();
		var waited = 0.0;
		while (asyncStore.busy() && waited < 10) { Sys.sleep(0.01); waited += 0.01; asyncStore.pump(); }
		require(FileSystem.exists(asyncStore.pathFor(asyncKey)), "the background writer did not write");
		asyncStore.request(new Map<String, Array<String>>());
		asyncStore.pump();
		while (asyncStore.busy() && waited < 10) { Sys.sleep(0.01); waited += 0.01; asyncStore.pump(); }
		require(!FileSystem.exists(asyncStore.pathFor(asyncKey)), "the background writer did not delete");

		// Failures are reported once per context and retried: the folder cannot be created under a file.
		var blocker = root + "/blocker.txt";
		File.saveContent(blocker, "x");
		var failing = new ContextSnapshotStore(blocker + "/contexts");
		var reports = 0;
		failing.onError = function(_, _) reports++;
		failing.sync(requested);
		failing.sync(requested);
		require(reports == 1, "a failed write was reported " + reports + " times");
		var tooBig = new ContextSnapshotStore(root + "/contexts-big");
		var huge = asyncLines.copy();
		for (i in 0...Std.int(ContextSnapshotStore.MAX_FILE_CHARS / 8) + 10) huge.push("Q\teditor");
		var bigReports = 0;
		tooBig.onError = function(_, _) bigReports++;
		tooBig.sync([asyncKey => huge]);
		require(bigReports == 1 && !FileSystem.exists(tooBig.pathFor(asyncKey)), "an oversize layout was written or not reported");

		// No session.conf, only files: the newest file's context is the focus and every group comes back.
		var onlyFiles = root + "/contexts-only";
		var seed = window(workspace, onlyFiles, g1);
		seed.host.openFile(file("a"), false);
		var s1 = new WorkspaceSession(); s1.takeLayout(seed.host.sessionLines());
		go(seed.host, g2).openFile(file("b"), false);
		var s2 = new WorkspaceSession(); s2.takeLayout(seed.host.sessionLines());
		var seeding = new ContextSnapshotStore(onlyFiles);
		seeding.write(g1, s1.contexts.get(s1.activeKey));
		Sys.sleep(0.05);
		seeding.write(g2, s2.contexts.get(s2.activeKey));
		var fromFiles = restart(workspace, onlyFiles, new WorkspaceSession(), g2);
		require(fromFiles.layoutContextKey == g2 && tabs(fromFiles, g2).join(",") == file("b"), "the newest file's context was not the focus");
		require(tabs(fromFiles, g1).join(",") == file("a"), "the other file's context did not come back");
		trace("PASS: one file per group, last write wins per group, other groups kept, crash loses only unsaved edits, migration from session.conf");
		return 0;
	}
}
