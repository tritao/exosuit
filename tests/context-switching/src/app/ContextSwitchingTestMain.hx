package app;

import sys.FileSystem;
import sys.io.File;
import ui.UiDocumentView;
import ui.UiWorkbenchHost;
import workspace.ActiveContext;
import workspace.ContextKind;
import workspace.ContextKey;
import workspace.Workspace as FreshWorkspace;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;

private class StubPanel implements ui.TerminalPanel {
	public function new() {}
	public function poll():Void {}
	public function workspaceName():Null<String> return null;
	public function terminate(force:Bool):Void {}
	public function close():Void {}
	public function status():String return "running";
	public function columns():Int return 80;
	public function rows():Int return 24;
	public function build(context:BuildContext):RenderNode throw "Not rendered";
}

/**
	Phase 7 of docs/roadmap/19-machine-workspaces.md on the real workbench host, without a window: the tabs of two
	workspaces round trip through switches (warm, then rebuilt from a snapshot), saved legacy keys migrate, and the
	switch stays inside its frame budget.
**/
class ContextSwitchingTestMain {
	static inline final WARM_BUDGET_SECONDS = 2.0 / 60.0;
	static inline final COLD_BUDGET_SECONDS = 0.1;

	static function require(value:Bool, message:String):Void { if (!value) throw message; }

	static function text(prefix:String):String {
		var result = "";
		for (i in 0...150) result += prefix + " line " + i + "\n";
		return result;
	}

	/** Opens `path` in the active pane, makes it dirty and leaves the caret and scroll somewhere recognizable. */
	static function dirtyView(host:UiWorkbenchHost, path:String, line:Int, scroll:Int):UiDocumentView {
		host.openFile(path, false);
		var view = host.activeView();
		if (view == null) throw "no view for " + path;
		view.document.buffer.replaceAllText(text(haxe.io.Path.withoutDirectory(path)), view.selection);
		view.restoreCursor(line, 4); view.restoreScroll(0, scroll);
		return view;
	}

	static function newHost(workspace:workspace.Workspace, dock:haxeon.ui.docking.DockWorkspaceModel):UiWorkbenchHost
		return new UiWorkbenchHost(new style.Theme(), new core.FocusManager(), workspace, new config.Settings(), function() {}, {
			model: dock, focusEditor: function(_) {}, editorPreedit: function(_, _) {},
			toggleSidebar: function() return false, activateExplorer: function() {},
			activateProblems: function() {}, activateBuild: function() {}
		});

	/** The session names the machine the contexts were saved under, so restore keeps the active layout. */
	static function restoreWithRealMachine(workspace:workspace.Workspace, dock:haxeon.ui.docking.DockWorkspaceModel, saved:UiWorkbenchHost):Void {
		var first = newHost(workspace, dock);
		var root = ContextKey.make("m-abc", "ws", ""), other = ContextKey.make("m-abc", "ws", "g");
		first.initializeContext(root);
		var file = workspace.fileSystem.normalize(FileSystem.fullPath("build/context-switching/a.txt"));
		first.openFile(file, false);
		var view = first.activeView();
		if (view == null) throw "no view";
		view.restoreCursor(3, 1);
		var line = view.cursorLine();
		first.switchContext(other);
		var lines = first.sessionLines();
		var record = new session.WorkspaceSession(); record.machineId = "m-abc";
		require(session.WorkspaceSession.decode(record.encode()).machineId == "m-abc", "session lost the machine id");

		// Persisted id: adopted before restore, so the active key matches and the tabs come back.
		var second = newHost(workspace, dock);
		second.initializeContext(ContextKey.make("local", "ws", "g"));
		second.migrateContextKey = function(k) return ContextKey.migrate(k, "m-abc", "ws");
		second.renameMachine("m-abc");
		second.restoreSessionLines(lines);
		require(second.layoutContextKey == other, "restore changed the active context");
		second.switchContext(root);
		var back = second.activeView();
		require(back != null && back.document.path == file && back.cursorLine() == line, "tabs of the saved machine did not come back: " + (back == null ? "none" : back.document.path + ":" + back.cursorLine() + "/" + line));

		// Without it (an older session), the catalog's rename must park, not overwrite, the saved layout.
		var third = newHost(workspace, dock);
		third.initializeContext(ContextKey.make("local", "ws", ""));
		third.migrateContextKey = function(k) return k;
		third.restoreSessionLines(lines);
		third.renameMachine("m-abc");
		var parked = [for (key in third.knownContextKeys()) if (key.indexOf("#parked") >= 0) key];
		require(third.layoutContextKey == root && parked.length == 1, "rename onto an existing context lost it: " + third.knownContextKeys().join(","));
		third.switchContext(parked[0]);
		var kept = third.activeView();
		require(kept != null && kept.document.path == file, "parked layout lost its tabs");
	}

	static function unsavedView(host:UiWorkbenchHost, workspace:workspace.Workspace, text:String):UiDocumentView {
		var document = workspace.documents.createUntitled();
		host.openDocument(document);
		var view = host.activeView();
		if (view == null) throw "no view for the untitled document";
		view.document.buffer.replaceAllText(text, view.selection);
		return view;
	}

	static function hasTab(host:UiWorkbenchHost, document:editor.Document):Bool {
		for (view in host.tabs) if (view.document == document) return true;
		return false;
	}

	/** Untitled text across a cold drop, a session save and a restore; quitting cold; recovered layouts; deleting a workspace. */
	static function unsavedCases(workspace:workspace.Workspace, dock:haxeon.ui.docking.DockWorkspaceModel):Void {
		var machine = "mu";
		var one = ContextKey.make(machine, "ws-one", ""), two = ContextKey.make(machine, "ws-two", "");

		// An untitled buffer survives being dropped to its snapshot, a save of the session while cold, and a restart.
		var host = newHost(workspace, dock);
		host.warmLimit = 0;
		host.initializeContext(one);
		var untitled = unsavedView(host, workspace, "untitled text");
		var document = untitled.document;
		untitled.restoreCursor(0, 4);
		host.switchContext(two);
		require(!host.contextIsWarm(one), "limit 0 kept the first context warm");
		var lines = host.sessionLines();
		host.dispose();
		require(workspace.documents.documents.indexOf(document) >= 0 && document.dirty, "quitting while cold lost the untitled document");
		var restarted = newHost(workspace, dock);
		restarted.initializeContext(two);
		restarted.restoreSessionLines(lines);
		restarted.switchContext(one);
		var back = restarted.activeView();
		require(back != null && back.document == document && back.document.buffer.text == "untitled text" && back.cursorLine() == 0 && back.cursorColumn() == 4,
			"untitled tab did not come back after restart");
		restarted.dispose();

		// Eviction leaves contexts with a live shell alone.
		var shells = newHost(workspace, dock);
		shells.warmLimit = 0;
		shells.initializeContext(one);
		shells.panelTerminals.push(new ui.UiTerminalTab("t1", "Terminal", "/tmp", new StubPanel()));
		shells.switchContext(two);
		require(shells.contextIsWarm(one), "a context with a shell was dropped to a snapshot");
		shells.dispose();

		// Parking: a rename onto an existing context keeps its unsaved tab, reachable as a recovered layout.
		var collide = newHost(workspace, dock);
		var other = ContextKey.make(machine, "ws-other", "");
		collide.initializeContext(other);
		collide.switchContext(one);
		var kept = unsavedView(collide, workspace, "parked text");
		collide.switchContext(other);
		collide.renameContext(other, one);
		var recovered = collide.recoveredContextKeys();
		require(collide.layoutContextKey == one && recovered.length == 1, "collision did not park the existing context: " + recovered.join(","));
		require(collide.recoveredSummary(recovered[0]) == "1 tab, 1 unsaved", "recovered summary: " + collide.recoveredSummary(recovered[0]));
		require(collide.mergeContext(recovered[0], false) == 1 && hasTab(collide, kept.document) && collide.recoveredContextKeys().length == 0,
			"recovered layout did not merge into the active context");
		// A clean parked layout is dropped at once.
		collide.switchContext(ContextKey.make(machine, "ws-clean", ""));
		File.saveContent("build/context-switching/clean1.txt", "clean
"); collide.openFile(FileSystem.fullPath("build/context-switching/clean1.txt"), false);
		collide.switchContext(other);
		collide.renameContext(other, ContextKey.make(machine, "ws-clean", ""));
		require(collide.recoveredContextKeys().length == 0, "a recovered layout with nothing unsaved was kept");
		collide.dispose();

		// Deleting a workspace never drops unsaved tabs, whether its context is warm or snapshotted.
		for (limit in [4, 0]) {
			var deleting = newHost(workspace, dock);
			deleting.warmLimit = limit;
			deleting.initializeContext(one);
			deleting.switchContext(two);
			var doomed = unsavedView(deleting, workspace, "delete " + limit);
			File.saveContent("build/context-switching/clean2.txt", "clean
"); deleting.openFile(FileSystem.fullPath("build/context-switching/clean2.txt"), false);
			deleting.switchContext(one);
			var moved = deleting.forgetWorkspaceContexts("ws-two");
			require(moved == 1 && hasTab(deleting, doomed.document) && deleting.knownContextKeys().indexOf(two) < 0, "deleting a workspace lost an unsaved tab (limit " + limit + ")");
			deleting.dispose();
		}
	}

	/** A legacy layout whose tab is only a T line (the older flat form) is recovered, and rescued on delete, like a V tab. */
	static function legacyTabCases(workspace:workspace.Workspace, dock:haxeon.ui.docking.DockWorkspaceModel):Void {
		var chrome = "D\tdock\t1\t" + dock.snapshotJson();
		for (mode in ["recover", "delete"]) {
			var untitled = workspace.documents.createUntitled();
			var newer = session.ContextLayoutStore.layoutLine(ContextKey.make("m", "w", ""), [chrome, "P\teditor"]);
			var older = session.ContextLayoutStore.layoutLine("workspace:w", [chrome, "P\teditor", "T\t\t1\t0\t0\t0\t0\tR\t" + untitled.recoveryId]);
			var host = newHost(workspace, dock);
			host.initializeContext(ContextKey.make("m", "elsewhere", ""));
			host.migrateContextKey = function(k) return ContextKey.migrate(k, "m", "elsewhere");
			host.restoreSessionLines([chrome, "P\teditor", newer, older]);
			if (mode == "recover") {
				var recovered = host.recoveredContextKeys();
				require(recovered.length == 1 && host.recoveredSummary(recovered[0]) == "1 tab, 1 unsaved", "a legacy T-only layout was not recovered: " + recovered.join(","));
				require(host.mergeContext(recovered[0], false) == 1 && hasTab(host, untitled), "the legacy untitled tab was discarded on recovery");
			} else {
				require(host.forgetWorkspaceContexts("w") == 1 && hasTab(host, untitled), "deleting the workspace discarded a legacy untitled tab");
			}
			host.dispose();
		}
	}

	/** A real restart: another Workspace, the untitled text coming back through recovery, not through shared documents. */
	static function freshWorkspaceRestart(workspace:workspace.Workspace, dock:haxeon.ui.docking.DockWorkspaceModel):Void {
		var machine = "mr";
		var one = ContextKey.make(machine, "ws-one", ""), two = ContextKey.make(machine, "ws-two", "");
		var host = newHost(workspace, dock);
		host.warmLimit = 0;
		host.initializeContext(one);
		var view = unsavedView(host, workspace, "restart text");
		var id = view.document.recoveryId, title = view.document.title;
		view.restoreCursor(0, 7);
		host.switchContext(two);
		var lines = host.sessionLines();
		host.dispose();

		var other = new FreshWorkspace(new syntax.SyntaxRegistry());
		var otherDock = new haxeon.ui.docking.DockWorkspaceModel();
		otherDock.register(new haxeon.ui.docking.DockPanelDescriptor("editor", "Editor"));
		otherDock.setDefaultLayout(haxeon.ui.docking.DockNode.Panel("editor"));
		var restarted = newHost(other, otherDock);
		restarted.initializeContext(two);
		restarted.restoreSessionLines(lines, function(kind, reference) {
			if (kind == "R" && reference == id) return other.documents.restoreRecovered(id, title, null, "restart text");
			return null;
		});
		restarted.switchContext(one);
		var back = restarted.activeView();
		require(back != null && other.documents.documents.indexOf(back.document) >= 0 && back.document != view.document && back.document.buffer.text == "restart text"
			&& back.cursorColumn() == 7, "a fresh workspace did not get the untitled tab back through recovery");
		restarted.dispose();
	}

	/** Deleting the workspace on screen keeps its context until the window has left it; then every unsaved tab moves. */
	static function activeWorkspaceDelete(workspace:workspace.Workspace, dock:haxeon.ui.docking.DockWorkspaceModel):Void {
		var machine = "md";
		var home = ContextKey.make(machine, "ws-home", ""), doomed = ContextKey.make(machine, "ws-doomed", ""), group = ContextKey.make(machine, "ws-doomed", "g");
		var host = newHost(workspace, dock);
		host.initializeContext(group);
		var inGroup = unsavedView(host, workspace, "group text");
		host.switchContext(doomed);
		var inRoot = unsavedView(host, workspace, "root text");
		// Still on screen: the inactive group closes, its unsaved tab joins the context on screen, which stays.
		require(host.forgetWorkspaceContexts("ws-doomed") == 1 && host.layoutContextKey == doomed && hasTab(host, inRoot.document) && hasTab(host, inGroup.document), "the context on screen was closed or lost a tab");
		host.switchContext(home);
		var moved = host.forgetWorkspaceContexts("ws-doomed");
		require(moved == 2 && hasTab(host, inGroup.document) && hasTab(host, inRoot.document), "leaving and deleting lost an unsaved tab: " + moved);
		host.dispose();
	}

	/** A recovered tab whose document is already open here is not opened twice. */
	static function alreadyOpenRecovered(workspace:workspace.Workspace, dock:haxeon.ui.docking.DockWorkspaceModel):Void {
		var machine = "mo";
		var a = ContextKey.make(machine, "ws-a", ""), b = ContextKey.make(machine, "ws-b", "");
		var host = newHost(workspace, dock);
		host.initializeContext(a);
		host.switchContext(b);
		var shared = unsavedView(host, workspace, "shared text").document;
		host.switchContext(a);
		host.openDocument(shared);
		host.renameContext(a, b);
		var recovered = host.recoveredContextKeys();
		require(recovered.length == 1, "the colliding layout was not parked");
		require(host.mergeContext(recovered[0], false) == 0 && host.recoveredContextKeys().length == 0, "an already open tab was merged again");
		var count = 0;
		for (view in host.tabs) if (view.document == shared) count++;
		require(count == 1, "the recovered tab was opened twice: " + count);
		host.dispose();
	}

	/** Saving a workspace gives it its real id; a focused group stays focused, and recents survive the session file. */
	static function identityAndRecents(workspace:workspace.Workspace):Void {
		var context = new ActiveContext(workspace);
		context.updateWorkspace("workspace", "W", []);
		context.focusGroup("g", "G", "build");
		var changes = 0;
		context.subscribe(function() changes++);
		context.renameWorkspace("workspace", "ws-real");
		context.updateWorkspace("ws-real", "W", []);
		require(context.kind == ContextKind.Group && context.key() == ContextKey.make(ContextKey.DEFAULT_MACHINE, "ws-real", "g") && changes == 0,
			"saving the workspace moved the user out of a focused group");
		var record = new session.WorkspaceSession();
		for (info in context.recent) record.recent.push(info);
		var decoded = session.WorkspaceSession.decode(record.encode());
		var expected = [ContextKey.make(ContextKey.DEFAULT_MACHINE, "ws-real", "g"), ContextKey.make(ContextKey.DEFAULT_MACHINE, "ws-real", "")];
		var found = [for (info in decoded.recent) info.key()];
		require(found.join("|") == expected.join("|"), "recent contexts were not saved exactly: " + found.join("|"));
		require(decoded.recent[0].label == "G" && decoded.recent[0].workspaceLabel == "W" && decoded.recent[0].directory == "build" && decoded.recent[1].isRoot(), "recent contexts lost their labels or folder");
		// Pruning: a workspace the catalog listed and no longer lists is gone; one it never listed stays.
		var pruning = new ActiveContext(workspace);
		pruning.restoreRecent([new workspace.ContextInfo("local", "from-file", "", "File", "File", ""), new workspace.ContextInfo("local", "listed", "", "L", "L", ""),
			new workspace.ContextInfo("local", "from-file", "g", "G", "File", "build"), new workspace.ContextInfo("local", "from-file", "lost", "X", "File", "build/does-not-exist")]);
		var exists = function(path:String) return FileSystem.exists(path);
		pruning.catalogChanged(["listed"], exists);
		var kept = [for (info in pruning.recent) info.key()];
		require(kept.indexOf(ContextKey.make("local", "from-file", "")) >= 0 && kept.indexOf(ContextKey.make("local", "from-file", "g")) >= 0
			&& kept.indexOf(ContextKey.make("local", "from-file", "lost")) < 0 && kept.indexOf(ContextKey.make("local", "listed", "")) >= 0, "a file workspace was pruned or a vanished folder kept: " + kept.join("|"));
		pruning.catalogChanged([], exists);
		kept = [for (info in pruning.recent) info.key()];
		require(kept.indexOf(ContextKey.make("local", "listed", "")) < 0 && kept.indexOf(ContextKey.make("local", "from-file", "")) >= 0, "a deleted workspace stayed in the recents: " + kept.join("|"));
		var fresh = new ActiveContext(workspace);
		fresh.restoreRecent(decoded.recent);
		var adopted = [for (info in fresh.recent) info.key()];
		require(adopted.indexOf(expected[0]) >= 0 && adopted.indexOf(expected[1]) >= 0 && adopted.length == 3 - (adopted.indexOf(fresh.key()) < 0 ? 1 : 0), "restored recents were not adopted: " + adopted.join("|"));
	}

	static function renameWorkspaceKeepsGroups(workspace:workspace.Workspace, dock:haxeon.ui.docking.DockWorkspaceModel):Void {
		var host = newHost(workspace, dock);
		host.initializeContext(ContextKey.make("m", "workspace", ""));
		host.switchContext(ContextKey.make("m", "workspace", "g1"));
		host.switchContext(ContextKey.make("m", "workspace", ""));
		host.renameWorkspace("m", "workspace", "ws-real");
		var keys = host.knownContextKeys();
		require(host.layoutContextKey == ContextKey.make("m", "ws-real", "") && keys.indexOf(ContextKey.make("m", "ws-real", "g1")) >= 0
			&& keys.indexOf(ContextKey.make("m", "workspace", "g1")) < 0, "group keys were orphaned by the workspace rename: " + keys.join(","));
	}

	static function legacyAndNewKeysCollide(workspace:workspace.Workspace, dock:haxeon.ui.docking.DockWorkspaceModel):Void {
		var chrome = "D	dock	1	" + dock.snapshotJson();
		var newer = session.ContextLayoutStore.layoutLine(ContextKey.make("m", "w", ""), [chrome, "P	editor", "V	editor	1	0	0	0	0	P	" + workspace.fileSystem.normalize(FileSystem.fullPath("build/context-switching/a.txt"))]);
		var kept = workspace.documents.createUntitled();
		var older = session.ContextLayoutStore.layoutLine("workspace:w", [chrome, "P	editor", "V	editor	1	0	0	0	0	R	" + kept.recoveryId]);
		for (order in [[newer, older], [older, newer]]) {
			var host = newHost(workspace, dock);
			host.initializeContext(ContextKey.make("m", "other", ""));
			host.migrateContextKey = function(k) return ContextKey.migrate(k, "m", "other");
			host.restoreSessionLines([chrome, "P	editor"].concat(order));
			var keys = host.knownContextKeys();
			require(keys.indexOf(ContextKey.make("m", "w", "") + "#legacy1") >= 0 && keys.indexOf(ContextKey.make("m", "w", "")) >= 0, "colliding legacy layout was dropped: " + keys.join(","));
			host.switchContext(ContextKey.make("m", "w", ""));
			require(host.activeView() != null, "the legacy layout replaced the current-format one, order " + (order[0] == newer ? "new first" : "legacy first"));
		}
	}

	static function main():Int {
		var base = "build/context-switching"; FileSystem.createDirectory(base);
		var files:Array<String> = [];
		for (name in ["a.txt", "b.txt", "c.txt", "d.txt"]) {
			File.saveContent(base + "/" + name, "x\n");
			files.push(FileSystem.fullPath(base + "/" + name));
		}
		var syntax = new syntax.SyntaxRegistry();
		var workspace = new workspace.Workspace(syntax);
		var dock = new haxeon.ui.docking.DockWorkspaceModel();
		dock.register(new haxeon.ui.docking.DockPanelDescriptor("editor", "Editor"));
		dock.setDefaultLayout(haxeon.ui.docking.DockNode.Panel("editor"));
		var host = newHost(workspace, dock);

		// The key names machine, workspace and group; ids with a slash cannot move a boundary.
		var key = ContextKey.make("m1", "ws/one", "g1");
		var parsed = ContextKey.parse(key);
		require(parsed != null && parsed.machine == "m1" && parsed.workspace == "ws/one" && parsed.group == "g1", "key did not round trip");
		require(ContextKey.migrate("workspace:w1", "m1", "x") == ContextKey.make("m1", "w1", "")
			&& ContextKey.migrate("group:g9", "m1", "w2") == ContextKey.make("m1", "w2", "g9")
			&& ContextKey.migrate(key, "m2", "z") == key, "legacy keys did not migrate");
		require(ContextKey.withMachine(key, "m9") == ContextKey.make("m9", "ws/one", "g1"), "machine could not be replaced");

		var machine = "m1";
		var rootA = ContextKey.make(machine, "ws-a", ""), groupA = ContextKey.make(machine, "ws-a", "g1");
		var rootB = ContextKey.make(machine, "ws-b", ""), rootC = ContextKey.make(machine, "ws-c", ""), rootD = ContextKey.make(machine, "ws-d", "");
		host.initializeContext(rootA);
		host.warmLimit = 2;
		var a = dirtyView(host, files[0], 30, 320);
		// A range selection, not just a caret.
		a.selection.restore(a.document.buffer, new editor.BufferPosition(30, 10), new editor.BufferPosition(28, 2));
		var aLine = a.cursorLine(), aColumn = a.cursorColumn(), aScroll = a.scrollY();
		var aAnchor = a.selection.anchor;

		// Workspace A to workspace B: B starts empty, A's view stays attached.
		host.switchContext(rootB);
		require(host.activeView() == null && host.activePane.items.length == 0, "workspace B inherited A's tabs");
		require(host.contextIsWarm(rootA), "A was not kept warm");
		var b = dirtyView(host, files[1], 42, 480);
		var bLine = b.cursorLine(), bColumn = b.cursorColumn(), bScroll = b.scrollY();
		host.switchContext(rootA);
		var warmSeconds = host.lastSwitchSeconds;
		require(!host.lastSwitchCold && host.activeView() == a, "warm switch rebuilt A");
		require(a.document.dirty && a.cursorLine() == aLine && a.cursorColumn() == aColumn && a.scrollY() == aScroll, "warm switch lost A's dirty buffer, caret or scroll");
		host.switchContext(rootB);
		require(host.activeView() == b && b.document.dirty && b.cursorLine() == bLine && b.cursorColumn() == bColumn && b.scrollY() == bScroll, "warm switch lost B's state");

		// Within one workspace the same operation: a group of A has its own tabs.
		host.switchContext(groupA);
		require(host.activeView() == null, "group inherited the workspace's tabs");
		host.switchContext(rootA);
		require(host.activeView() == a, "return from the group lost A");

		// Past the warm limit the least recently used contexts give up their views and come back from the snapshot.
		host.switchContext(rootC);
		dirtyView(host, files[2], 7, 40);
		host.switchContext(rootD);
		dirtyView(host, files[3], 9, 80);
		host.switchContext(rootB);
		require(!host.contextIsWarm(rootA), "A kept its views past the warm limit");
		var before = host.coldSwitches;
		host.switchContext(rootA);
		var coldSeconds = host.lastSwitchSeconds;
		var restored = host.activeView();
		require(restored != null && restored != a && host.lastSwitchCold && host.coldSwitches == before + 1, "A was not rebuilt from its snapshot");
		if (restored == null) throw "unreachable";
		require(restored.document == a.document && restored.document.dirty, "snapshot lost the dirty buffer");
		require(restored.selection.hasSelection() && restored.selection.anchor.line == aAnchor.line && restored.selection.anchor.column == aAnchor.column, "snapshot lost the selection range");
		require(restored.cursorLine() == aLine && restored.cursorColumn() == aColumn && restored.scrollY() == aScroll,
			"snapshot lost the caret or scroll: " + restored.cursorLine() + ":" + restored.cursorColumn() + ":" + restored.scrollY());
		host.switchContext(rootD);
		host.switchContext(rootA);
		var warmAgain = host.lastSwitchSeconds;
		require(!host.lastSwitchCold, "A was evicted again immediately");

		// Closing a workspace drops its inactive contexts and their bookkeeping.
		require(host.knownContextKeys().indexOf(rootB) >= 0, "B is not known before it is closed");
		host.forgetWorkspaceContexts("ws-b");
		require(host.knownContextKeys().indexOf(rootB) < 0, "closed workspace left its context behind");
		require(host.layoutContextKey == rootA, "closing another workspace changed the active context");

		unsavedCases(workspace, dock);
		legacyTabCases(workspace, dock);
		freshWorkspaceRestart(workspace, dock);
		activeWorkspaceDelete(workspace, dock);
		alreadyOpenRecovered(workspace, dock);
		identityAndRecents(workspace);
		restoreWithRealMachine(workspace, dock, host);
		renameWorkspaceKeepsGroups(workspace, dock);
		legacyAndNewKeysCollide(workspace, dock);

		// Saved keys from before Phase 7 move to the current scheme, and the machine id replaces the placeholder.
		var legacy = [session.ContextLayoutStore.activeLine("workspace:old-ws"),
			session.ContextLayoutStore.layoutLine("group:old-group", ["D\tdock\t1\t" + dock.snapshotJson(), "P\teditor"])];
		var fresh = newHost(workspace, dock);
		fresh.initializeContext(ContextKey.make("local", "old-ws", ""));
		fresh.migrateContextKey = function(k) return ContextKey.migrate(k, "local", "old-ws");
		fresh.restoreSessionLines(["D\tdock\t1\t" + dock.snapshotJson(), "P\teditor"].concat(legacy));
		var migrated = fresh.knownContextKeys();
		require(migrated.indexOf(ContextKey.make("local", "old-ws", "old-group")) >= 0, "legacy group layout was lost: " + migrated.join(","));
		fresh.renameMachine("m42");
		require(fresh.layoutContextKey == ContextKey.make("m42", "old-ws", "") && fresh.knownContextKeys().indexOf(ContextKey.make("m42", "old-ws", "old-group")) >= 0,
			"machine rename left contexts behind");

		trace("switch warm " + Math.round(warmSeconds * 1000000) + " us, warm again " + Math.round(warmAgain * 1000000) + " us, cold " + Math.round(coldSeconds * 1000000) + " us");
		require(warmSeconds <= WARM_BUDGET_SECONDS && warmAgain <= WARM_BUDGET_SECONDS, "warm switch over two frames");
		require(coldSeconds <= COLD_BUDGET_SECONDS, "cold switch over 100 ms");
		trace("PASS: tabs round trip across workspaces warm and from snapshot, legacy keys migrate, switches within budget");
		return 0;
	}
}
