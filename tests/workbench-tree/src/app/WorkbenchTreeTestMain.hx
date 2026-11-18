package app;

import haxe.Int64;
// Works around a compiler defect: TabTooltip's default argument names config.Settings, and Haxeon resolves a package
// path in a default value only once a module of it is loaded (docs/compiler-typing.md, Recorded defects).
import config.Settings;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.widgets.collections.TreeView;
import exohost.MachineCatalog.MachineWorkspace;
import ui.AgentScope;
import ui.CatalogThrottle;
import ui.WorkbenchMachineLabel;
import ui.WorkbenchMachineView;
import ui.WorkbenchMachineView.WorkbenchWorkspaceState;
import ui.WorkbenchRowKind;
import ui.WorkbenchRows;
import ui.WorkbenchRows.WorkbenchRowSource;
import workspace.client.WorkspaceCatalogMirror;
import ui.WorkbenchPanel;
import ui.WorkbenchRowKey;
import ui.WorkbenchTreeModel;
import ui.WorkbenchTreeSafe;
import workspace.service.WorkspaceAgentProtocol.AgentCatalog;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;
import workspace.service.WorkspaceTerminalProtocol.TerminalCatalog;

/** The Workbench as one tree: the machine's workspaces, each with its groups, sessions and terminals under its row by one rule. */
class WorkbenchTreeTestMain {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }

	static function group(id:String, name:String, ?parent:String, order:Int = 0):WorkspaceGroup
		return {id: id, name: name, cwd: null, revision: 1, parent: parent, order: order};

	static function catalog(root:String):TerminalCatalog
		return {instance: "i", next: null, workspaceRoot: root,
			groups: [group("apps", "Applications", null, 1), group("work", "Work", null, 0), group("drafts", "Drafts", "work", 0)],
			terminals: [{id: "t1", name: "Terminal", group: "work", cwd: root, instance: "i", state: "running", exitCode: 0,
				available: true, revision: Int64.ofInt(1)}]};

	static function agents(root:String):AgentCatalog
		return {instance: "i", root: root, status: "ready", next: null, records: [
			{id: "a1", name: "Codex", group: "work", cwd: root, thread: "", state: "idle", turn: null, workspaceRoot: root}]};

	static function workspaceEntry(id:String, name:String, folders:Array<String>, ?scratch:String):MachineWorkspace
		return {id: id, name: name, folders: folders, scratch: scratch, revision: 1};

	static function view(workspaces:Null<Array<MachineWorkspace>>, open:Null<String>, ?error:String, manages:Bool = true):WorkbenchMachineView
		return {machine: workspaces == null ? null : {id: "m", name: "cube", workspaces: workspaces}, error: error,
			openWorkspace: open, revision: 1, manages: manages};

	/** A workspace's rows from its link's lists. */
	static function lists(terminals:TerminalCatalog, ?sessions:AgentCatalog):WorkbenchRowSource
		return {terminals: terminals, agents: sessions, snapshot: null, revision: 1};

	/** A workspace's rows from a copy of its catalog. */
	static function copy(mirror:WorkspaceCatalogMirror):WorkbenchRowSource
		return {terminals: null, agents: null, snapshot: mirror, revision: 0};

	static function children(model:WorkbenchTreeModel, key:String):Array<String>
		return [for (index in 0...model.childCount(key)) model.childKeyAt(key, index)];

	static function roots(model:WorkbenchTreeModel):Array<String>
		return [for (index in 0...model.rootCount()) model.rootKeyAt(index)];

	static final machineWorkspaces = [
		workspaceEntry("exo", "exosuit", ["C:/src/exosuit"]),
		workspaceEntry("resume", "resume-2026", ["C:/work/resume"]),
		workspaceEntry("eon", "eon-series", [])
	];

	/** A workspace row shows its first folder, else its scratch folder, shortened as a group row's folder is. */
	static function workspaceFolder():Void {
		require(WorkbenchMachineLabel.folder(workspaceEntry("a", "a", ["C:/src/a", "C:/src/b"], "C:/Users/me/Exosuit/a")) == "C:/src/a",
			"a workspace with folders shows its first");
		var scratch = WorkbenchMachineLabel.folder(workspaceEntry("eon", "eon-series", [], "C:\\Users\\me\\Exosuit\\eon-series"));
		require(scratch == "C:\\Users\\me\\Exosuit\\eon-series" && ui.WorkbenchGroupLabel.shortDirectory("C:\\Users\\me\\Exosuit\\eon-series", null) == "…\\Exosuit\\eon-series",
			"a folderless workspace shows its scratch folder: " + scratch);
		require(WorkbenchMachineLabel.folder(workspaceEntry("old", "old", [])) == null, "a workspace with neither shows none");
	}

	/**
		A workspace made with New Workspace starts its service in the scratch folder, which the service keeps after a
		folder is attached: the tree, the right panel's scope, the chooser and the terminal backend use the attached folder.
	**/
	static function scratchStarted():Void {
		var scratch = "C:/Users/me/Exosuit/eon", folder = "C:/src/eon";
		var model = new WorkbenchTreeModel();
		model.update(view([workspaceEntry("eon", "eon-series", [folder, "C:/src/other"], scratch)], "eon"), ["eon" => lists(catalog(scratch))]);
		require(model.firstFolder("eon") == folder, "firstFolder is the attached folder, not the service root: " + model.firstFolder("eon"));
		require(model.directory("eon", group("loose", "Loose")) == folder, "a folderless group works in the attached folder: " + model.directory("eon", group("loose", "Loose")));
		var scope = AgentScope.resolve(model, "w:eon", null);
		require(scope != null && scope.directory == folder, "the workspace scope lists the attached folder: " + (scope == null ? "none" : scope.directory));
		// Without an attached folder the service's root (the scratch folder) is all there is.
		model.update(view([workspaceEntry("eon", "eon-series", [], scratch)], "eon"), ["eon" => lists(catalog(scratch))]);
		require(model.firstFolder("eon") == scratch, "no folder attached falls back to the service root: " + model.firstFolder("eon"));
		// The chooser sends the attached folder when the service would place the session in its own root.
		var groups = [group("loose", "Loose")];
		require(ui.SessionFolderChooser.explicitFor(groups, "loose", folder, scratch) == folder, "a root session started in the scratch folder is sent the attached folder");
		require(ui.SessionFolderChooser.explicitFor(groups, "loose", scratch, scratch) == null, "no folder is sent when the service would choose it anyway");
		require(ui.SessionFolderChooser.explicitFor(groups, "loose", null, scratch) == null, "a folderless workspace sends none");
		// A terminal keyed by the attached folder belongs to the service that started in the scratch folder.
		function status(endpoint:workspace.client.WorkspaceRpcEndpoint):String
			return new workspace.client.RpcTerminalBackend(function() return endpoint, "t", folder, false).controlStatus();
		require(status(new FakeEndpoint(scratch, true)) == "Connecting to workspace terminal…", "terminal rejected a served folder: " + status(new FakeEndpoint(scratch, true)));
		require(status(new FakeEndpoint(scratch, false)).indexOf("Open this terminal's workspace to reconnect") == 0, "terminal accepted a service that serves another root");
	}

	static function main():Void {
		workspaceFolder();
		hiddenRowsDoNotThrow();
		unreachableMachine();
		scratchStarted();
		ordering();
		everyWorkspace();
		cyclicGroups();
		projection();
		catalogThrottle();
		emptyAndLoading();
		device();
		workspaceRoot();
		notes();
		rendered();
		Sys.println("workbench-tree: ok");
	}

	/** Workspaces in exohost's order, then New Workspace…; groups (by order), then their terminals and sessions. */
	static function ordering():Void {
		var model = new WorkbenchTreeModel();
		model.update(view(machineWorkspaces, "resume"), ["resume" => lists(catalog("C:/work/resume"), agents("C:/work/resume"))]);
		require(roots(model).join(",") == "w:exo,w:resume,w:eon,n:new-workspace,n:folder-workspace", "the workspaces are not the roots: " + roots(model));
		require(children(model, "w:resume").join(",") == "g:resume|work,g:resume|apps", "open workspace's groups: " + children(model, "w:resume"));
		require(children(model, "g:resume|work").join(",") == "g:resume|drafts,t:resume|t1,a:resume|a1", "group contents: " + children(model, "g:resume|work"));
		// A workspace with nothing to show yet says it is loading while its row is expanded.
		require(children(model, "w:exo").join(",") == "s:loading-rows|exo" && children(model, "w:eon").join(",") == "s:loading-rows|eon",
			"a workspace without rows: " + children(model, "w:exo"));
		require(WorkbenchRowKey.noteWorkspace("s:loading-rows|exo") == "exo" && WorkbenchRowKey.isMachineRow("s:loading-rows|exo")
			&& WorkbenchRowKey.statusKind("s:loading-rows|exo") == WorkbenchRowKey.NOTE_LOADING, "a note row names its workspace");
		require(model.openRow == "w:resume" && model.openWorkspace == "resume", "the open workspace");
		require(model.initiallyExpanded("w:resume") && model.initiallyExpanded("g:resume|work"),
			"the open workspace or a top-level group starts collapsed");
		require(!model.initiallyExpanded("w:exo") && !model.initiallyExpanded("g:resume|drafts"), "a closed workspace or sub-group starts expanded");
		require(model.expandable("w:eon") && model.expandable("w:resume") && !model.expandable("n:new-workspace") && !model.expandable("t:resume|t1"),
			"every workspace and only workspaces expand without children");
		// Only sessions whose prompt resumes them (Claude, Pi) are called Resumable; Codex is merely disconnected.
		require(WorkbenchRows.agentStateLabel("disconnected", "claude") == "Resumable" && WorkbenchRows.agentStateLabel("disconnected", "pi") == "Resumable"
			&& WorkbenchRows.agentStateLabel("disconnected", null) == "Disconnected", "disconnected labels");
		// Machine rows are not group rows, so drag, menus and scope code pass over them.
		require(WorkbenchRowKey.parse("w:resume") == null && WorkbenchRowKey.parse("s:error") == null && WorkbenchRowKey.parse("n:new-workspace") == null,
			"a machine row parsed as a group row");
		require(WorkbenchRowKey.isMachineRow("w:resume") && WorkbenchRowKey.isMachineRow("s:error") && !WorkbenchRowKey.isMachineRow("g:resume|work"),
			"machine row recognition");
		require(WorkbenchRowKey.statusKind(WorkbenchRowKey.status("error")) == "error" && WorkbenchRowKey.statusKind("w:resume") == null
			&& WorkbenchRowKey.statusKind("s:") == null, "status row kinds");
		var scope = AgentScope.resolve(model, null, null);
		require(scope != null && scope.groupId == "work", "the right panel's first-group fallback skipped the nested groups");
		require(scope.equals(AgentScope.resolve(model, "w:exo", scope)), "selecting a workspace row changed the scope");
	}

	/**
		Every workspace's rows follow one rule, keyed by workspace and item: from a copy of its catalog (an idle or not yet
		linked workspace's), or from its link's lists, which win once read. An idle workspace with neither shows a marker.
	**/
	static function everyWorkspace():Void {
		var mirror = new WorkspaceCatalogMirror();
		mirror.apply({ref: {machine: "m", workspace: "exo"}, instance: "i", token: "t1", reset: true, more: false, name: "exosuit", folders: ["C:/src/exosuit"],
			scratch: null, status: "running", attention: 2,
			groups: [group("build", "Build", null, 1), group("lint", "Lint", "build", 0), group("docs", "Docs", null, 0)],
			sessions: [{id: "s1", name: "Fix tests", group: "build", directory: "C:/src/exosuit", provider: null, state: "working", attention: 1},
				{id: "s2", name: "Loose session", group: "", directory: "C:/src/exosuit", provider: null, state: "idle", attention: 0}],
			terminals: [{id: "t1", name: "Shell", group: "lint", directory: "C:/src/exosuit", state: "running", exitCode: 0, available: true,
				revision: Int64.ofInt(1), agentProvider: null, attention: 0}],
			removedGroups: [], removedSessions: [], removedTerminals: [], watching: true});
		var watched:Map<String, WorkbenchWorkspaceState> = [];
		watched.set("exo", {running: true, live: true, starting: false, catalog: mirror});
		watched.set("resume", {running: true, live: true, starting: false, catalog: null});
		watched.set("eon", {running: false, live: false, starting: false, catalog: null});
		var shown = view(machineWorkspaces, "resume");
		shown.watched = watched;
		shown.watchRevision = 1;
		var resume = lists(catalog("C:/work/resume"), agents("C:/work/resume"));
		var sources:Map<String, WorkbenchRowSource> = ["exo" => copy(mirror), "resume" => resume];
		var model = new WorkbenchTreeModel();
		model.update(shown, sources);
		require(roots(model).join(",") == "w:exo,w:resume,w:eon,n:new-workspace,n:folder-workspace", "other workspaces' rows changed the roots: " + roots(model));
		var top = children(model, "w:exo");
		require(top.join(",") == "g:exo|docs,g:exo|build,a:exo|s2", "another workspace's top level: " + top);
		var build = children(model, "g:exo|build");
		require(build.join(",") == "g:exo|lint,a:exo|s1", "another workspace's group: " + build);
		require(children(model, "g:exo|lint").join(",") == "t:exo|t1", "another workspace's sub-group: " + children(model, "g:exo|lint"));
		require(children(model, "w:eon").join(",") == "s:not-running|eon" && model.expandable("w:eon"), "an idle workspace says it is not running: " + children(model, "w:eon"));
		watched.set("eon", {running: false, live: false, starting: true, catalog: null});
		model.update(shown, sources);
		require(children(model, "w:eon").join(",") == "s:loading-rows|eon", "a starting workspace is loading: " + children(model, "w:eon"));
		watched.set("eon", {running: false, live: false, starting: false, catalog: null});
		model.update(shown, sources);
		require(model.childCount("w:resume") == 2, "the open workspace still shows its own groups");
		// Every row names its workspace and item; the same spelling for every workspace.
		var parsed = WorkbenchRowKey.parse("a:exo|s1");
		require(parsed != null && parsed.kind == WorkbenchRowKind.Agent && parsed.workspace == "exo" && parsed.id == "s1", "row parse");
		require(WorkbenchRowKey.terminal("exo", "t1") == "t:exo|t1" && WorkbenchRowKey.parse("g:work") == null && !WorkbenchRowKey.isMachineRow("a:exo|s1"),
			"row spelling");
		require(model.workspaceOfRow("g:exo|lint") == "exo" && model.workspaceOfRow("t:resume|t1") == "resume" && model.workspaceOfRow("s:not-running|eon") == "eon",
			"a row's workspace");
		// Each workspace's rows are its own; records to act on come only from a link's lists.
		var exo = model.rows("exo"), own = model.rows("resume");
		require(exo != null && !exo.live && exo.groups.exists("build") && exo.terminals.get("t1") == null, "a catalog copy's rows");
		var shell = own == null ? null : own.terminals.get("t1");
		require(own != null && own.live && !own.groups.exists("build") && shell != null && shell.name == "Terminal",
			"a workspace's lists' rows");
		var lint = WorkbenchRowKey.groupOf(model, "t:exo|t1");
		require(lint != null && lint.id == "lint" && WorkbenchRowKey.parentGroupId(model, "a:exo|s2") == WorkspaceProtocol.ROOT_GROUP,
			"another workspace's rows know their groups");
		for (key in top.concat(build)) model.buildItem(key);
		model.buildItem("w:eon");
		model.buildItem("s:not-running|eon");
		model.buildItem("w:exo");
		// The marker says what a workspace is doing.
		require(WorkbenchMachineLabel.stateMarker(watched.get("exo")) == "running" && WorkbenchMachineLabel.stateMarker(watched.get("eon")) == "idle",
			"running and idle markers");
		require(WorkbenchMachineLabel.stateMarker({running: true, live: false, starting: false, catalog: null}) == "reconnecting"
			&& WorkbenchMachineLabel.stateMarker({running: false, live: false, starting: true, catalog: null}) == "starting…"
			&& WorkbenchMachineLabel.stateMarker(null) == null, "reconnecting and starting markers");
		// A workspace whose link has read its lists shows them, not its catalog copy, under the same keys.
		sources.set("exo", {terminals: catalog("C:/src/exosuit"), agents: agents("C:/src/exosuit"), snapshot: mirror, revision: 2});
		model.update(shown, sources);
		var linked = model.rows("exo");
		require(children(model, "w:exo").join(",") == "g:exo|work,g:exo|apps" && linked != null && linked.live, "a link's lists did not replace the catalog copy: " + children(model, "w:exo"));
		// Until the session list is read too, the catalog copy stays, so the sessions do not blink out.
		sources.set("exo", {terminals: catalog("C:/src/exosuit"), agents: null, snapshot: mirror, revision: 3});
		model.update(shown, sources);
		require(children(model, "w:exo").join(",") == "g:exo|docs,g:exo|build,a:exo|s2", "the catalog copy gave way before the session list: " + children(model, "w:exo"));
	}

	/** A catalog change alone waits out 100 ms and then applies, last change included; a structure change applies at once. */
	static function catalogThrottle():Void {
		var throttle = new CatalogThrottle();
		require(throttle.due("s1", "s1
1", 0.0), "the first inputs apply");
		throttle.took("s1", "s1
1", 0.0);
		require(!throttle.due("s1", "s1
2", 0.05) && throttle.waiting, "a catalog change within 100 ms is held and asks for another frame");
		require(!throttle.due("s1", "s1
3", 0.08) && throttle.waiting, "a newer one is held too");
		require(throttle.due("s1", "s1
3", 0.11) && !throttle.waiting, "after 100 ms the last change applies");
		throttle.took("s1", "s1
3", 0.11);
		require(!throttle.due("s1", "s1
3", 0.5) && !throttle.waiting, "nothing is pending afterwards");
		require(throttle.due("s2", "s2
3", 0.12), "a structure change does not wait");
	}

	/** Only the open workspace and expanded ones are projected, and a workspace's rows are rebuilt only when its source changed. */
	static function projection():Void {
		var page = function(token:String, reset:Bool, name:String):workspace.service.WorkspaceCatalogProtocol.WorkspaceCatalog return {ref: {machine: "m", workspace: "exo"}, instance: "i",
			token: token, reset: reset, more: false, name: "exosuit", folders: [], scratch: null, status: "running", attention: 0, groups: [group("g", name, null, 0)],
			sessions: [{id: "s", name: "Session", group: "g", directory: "/d", provider: null, state: "idle", attention: 0}], terminals: [],
			removedGroups: [], removedSessions: [], removedTerminals: [], watching: true};
		var exo = new WorkspaceCatalogMirror(), other = new WorkspaceCatalogMirror();
		exo.apply(page("t1", true, "Build"));
		var otherPage = page("t1", true, "Other");
		otherPage.ref.workspace = "eon";
		other.apply(otherPage);
		var sources:Map<String, WorkbenchRowSource> = ["exo" => copy(exo), "eon" => copy(other),
			"resume" => lists(catalog("C:/work/resume"), agents("C:/work/resume"))];
		var shown = view(machineWorkspaces, "resume");
		var model = new WorkbenchTreeModel();
		var expanded:Map<String, Bool> = [];
		model.expandedRows = expanded;
		model.update(shown, sources);
		require(model.childCount("w:exo") == 0 && model.childCount("w:eon") == 0 && model.projectionBuilds == 1,
			"only the open workspace is projected while every other is collapsed: " + model.projectionBuilds);
		expanded.set("w:exo", true);
		model.update(shown, sources);
		require(children(model, "w:exo").join(",") == "g:exo|g" && model.childCount("w:eon") == 0 && model.projectionBuilds == 2, "only the expanded workspace projects");
		model.update(shown, sources);
		require(model.projectionBuilds == 2 && children(model, "g:exo|g").join(",") == "a:exo|s", "an unchanged source reuses its rows");
		expanded.set("w:eon", true);
		model.update(shown, sources);
		require(model.projectionBuilds == 3, "expanding another workspace builds only that one");
		exo.apply(page("t2", false, "Renamed"));
		model.update(shown, sources);
		require(model.projectionBuilds == 4, "one workspace's change rebuilds that workspace alone: " + model.projectionBuilds);
		expanded.remove("w:eon");
		model.update(shown, sources);
		require(model.childCount("w:eon") == 0 && model.childCount("w:exo") == 1 && model.rows("eon") == null, "collapsing hides a workspace's rows");
	}

	/** A group naming itself, a descendant, or a missing group as its parent sits at the workspace root; the tree is finite. */
	static function cyclicGroups():Void {
		var mirror = new WorkspaceCatalogMirror();
		mirror.apply({ref: {machine: "m", workspace: "exo"}, instance: "i", token: "t1", reset: true, more: false, name: "exosuit", folders: [],
			scratch: null, status: "running", attention: 0,
			groups: [group("a", "Self", "a", 0), group("b", "Loop one", "c", 1), group("c", "Loop two", "b", 2), group("d", "Under the loop", "b", 3),
				group("o", "Orphan", "missing", 4), group("k", "Kid", "o", 5)],
			sessions: [], terminals: [], removedGroups: [], removedSessions: [], removedTerminals: [], watching: true});
		var model = new WorkbenchTreeModel();
		model.update(view(machineWorkspaces, "resume"), ["exo" => copy(mirror)]);
		var top = children(model, "w:exo");
		for (id in ["a", "b", "c", "d", "o"])
			require(top.indexOf("g:exo|" + id) >= 0, "group " + id + " sits at the workspace root: " + top);
		require(top.indexOf("g:exo|k") < 0 && children(model, "g:exo|o").join(",") == "g:exo|k", "an ordinary child stays under an orphan");
		var reached = 0;
		var walk:String->Int->Void = null;
		walk = function(key, depth) {
			reached++;
			require(depth < 10, "the tree does not end under " + key);
			for (index in 0...model.childCount(key)) walk(model.childKeyAt(key, index), depth + 1);
		};
		walk("w:exo", 0);
		require(reached == 7, "every group is reached once: " + reached);
	}

	/** No workspaces, exohost still answering, and exohost failing are rows of the tree, above New Workspace…. */
	static function emptyAndLoading():Void {
		var model = new WorkbenchTreeModel();
		model.update(view([], null), []);
		require(roots(model).join(",") == "s:empty,n:new-workspace,n:folder-workspace", "empty machine: " + roots(model));
		model.update(view(null, null), []);
		require(roots(model).join(",") == "s:loading,n:new-workspace,n:folder-workspace", "loading: " + roots(model));
		model.update(view(null, null, "exohost is not running"), []);
		require(roots(model).join(",") == "s:error,n:new-workspace,n:folder-workspace", "exohost error: " + roots(model));
		model.update(view(machineWorkspaces, "resume", "exohost did not answer"), []);
		require(roots(model).join(",") == "w:exo,w:resume,w:eon,s:error,n:new-workspace,n:folder-workspace",
			"a refresh error hid the known workspaces");
		// A folderless workspace, open on its scratch folder, nests its groups like any other.
		model.update(view(machineWorkspaces, "eon"), ["eon" => lists(catalog("C:/Users/me/Exosuit/eon-series"))]);
		require(children(model, "w:eon").join(",") == "g:eon|work,g:eon|apps", "a scratch-folder workspace's groups");
	}

	/** Sessions and terminals in no group sit directly under the workspace, after its top-level groups. */
	static function workspaceRoot():Void {
		var terminals = catalog("C:/work/resume"), sessions = agents("C:/work/resume");
		terminals.terminals[0].group = WorkspaceProtocol.ROOT_GROUP;
		sessions.records[0].group = WorkspaceProtocol.ROOT_GROUP;
		var model = new WorkbenchTreeModel();
		model.update(view(machineWorkspaces, "resume"), ["resume" => lists(terminals, sessions)]);
		require(children(model, "w:resume").join(",") == "g:resume|work,g:resume|apps,t:resume|t1,a:resume|a1", "workspace root items: " + children(model, "w:resume"));
		require(children(model, "g:resume|work").join(",") == "g:resume|drafts", "a root item stayed in its old group");
		require(WorkbenchRowKey.groupOf(model, "t:resume|t1") == null && WorkbenchRowKey.parentGroupId(model, "a:resume|a1") == WorkspaceProtocol.ROOT_GROUP,
			"a root item has a group");
		// A root item, or the workspace row, scopes the right panel to the workspace; the scope then stays.
		var scope = AgentScope.resolve(model, "a:resume|a1", null);
		require(scope != null && WorkspaceProtocol.isRoot(scope.groupId) && scope.label == "resume-2026" && scope.directory == "C:/work/resume",
			"a root item did not scope to the workspace");
		require(scope.equals(AgentScope.resolve(model, null, scope)) && scope.equals(AgentScope.resolve(model, "w:resume", null)),
			"the workspace scope did not stay or the workspace row did not choose it");
		var group = AgentScope.resolve(model, "g:resume|drafts", scope);
		require(group != null && group.groupId == "drafts", "a group row did not take over from the workspace scope");
		// Another workspace's row is no choice for the right panel, which follows the workspace the window shows.
		require(scope.equals(AgentScope.resolve(model, "g:exo|drafts", scope)), "another workspace's row scoped the right panel");
		require(!model.initiallyExpanded("t:resume|t1") && !model.expandable("a:resume|a1"), "a root item expands");
	}

	/**
		A device (the phone, the browser) shows its paired machine's granted workspaces by the same rule, with the open
		one's rows under its row; it makes no workspaces, so there is no New Workspace….
	**/
	static function device():Void {
		var model = new WorkbenchTreeModel();
		model.update(view(machineWorkspaces, "resume", null, false), ["resume" => lists(catalog("C:/work/resume"), agents("C:/work/resume"))]);
		require(roots(model).join(",") == "w:exo,w:resume,w:eon", "device roots: " + roots(model));
		require(model.openRow == "w:resume" && model.initiallyExpanded("w:resume"), "the device's open workspace is not expanded");
		require(children(model, "w:resume").join(",") == "g:resume|work,g:resume|apps", "the device's open workspace rows: " + children(model, "w:resume"));
		model.update(view([], null, null, false), []);
		require(roots(model).join(",") == "s:empty", "a device granted nothing: " + roots(model));
	}

	/** The open workspace's row says why it shows nothing: still loading, the reason it could not connect, or nothing in it yet. */
	static function notes():Void {
		var model = new WorkbenchTreeModel();
		model.update(view(machineWorkspaces, "exo"), ["resume" => lists(catalog("C:/work/resume"))]);
		require(model.openRow == "w:exo" && children(model, "w:exo").join(",") == "s:loading-rows|exo", "the open workspace before its rows: " + children(model, "w:exo"));
		model.openFailure = "the service did not start";
		model.update(view(machineWorkspaces, "exo"), []);
		require(children(model, "w:exo").join(",") == "s:failed|exo", "a failed connection: " + children(model, "w:exo"));
		model.openFailure = null;
		var none:TerminalCatalog = {instance: "i", next: null, workspaceRoot: "C:/src/exosuit", groups: [], terminals: []};
		model.update(view(machineWorkspaces, "exo"), ["exo" => lists(none)]);
		require(children(model, "w:exo").join(",") == "s:none|exo", "an empty workspace: " + children(model, "w:exo"));
		require(roots(model).join(",") == "w:exo,w:resume,w:eon,n:new-workspace,n:folder-workspace", "rows leaked to the roots");
	}

	/**
		After a live reload the Workbench asked for a row its rebuilt tree did not show, TreeView threw "selection key is
		not visible" from a layout or event callback, and the window died. The Workbench's selection waits instead.
	**/
	static function hiddenRowsDoNotThrow():Void {
		var model = new WorkbenchTreeModel();
		model.update(view(machineWorkspaces, "resume"), ["resume" => lists(catalog("C:/work/resume"), agents("C:/work/resume"))]);
		var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.height = LayoutAxis.grow();
		var tree = new TreeView("workbench-tree", model, style);
		tree.select("w:resume", false);
		// The exo workspace is collapsed: its (would-be) rows are not in the tree.
		require(!WorkbenchTreeSafe.select(tree, "g:exo|work"), "a row that is not shown was selected");
		require(!WorkbenchTreeSafe.select(tree, "nothing", false), "an unknown row was selected");
		require(tree.selectedKey == "w:resume", "a refused selection moved the selection to " + tree.selectedKey);
		require(!WorkbenchTreeSafe.scrollTo(tree, "g:exo|work"), "scrolled to a row that is not shown");
		require(WorkbenchTreeSafe.select(tree, "w:eon", false) && tree.selectedKey == "w:eon", "a shown row was not selected");
	}

	/**
		A window that cannot reach exohost used to say "Looking for this machine's workspaces…" for ever. It says why (not
		built, start failed, not answering) and the row offers a retry.
	**/
	static function unreachableMachine():Void {
		var reasons = [
			exohost.ExohostClient.explainUnreachable(false, false, null),
			exohost.ExohostClient.explainUnreachable(true, true, null),
			exohost.ExohostClient.explainUnreachable(false, true, "no such file"),
			exohost.ExohostClient.explainUnreachable(false, true, null)
		];
		for (index in 0...reasons.length) for (other in index + 1...reasons.length) require(reasons[index] != reasons[other], "two causes read the same: " + reasons[index]);
		require(reasons[0].indexOf("not built") >= 0 && reasons[1].indexOf("AUTOSTART") >= 0 && reasons[2].indexOf("no such file") >= 0 && reasons[3].indexOf("not answering") >= 0,
			"the reasons do not name their causes: " + reasons);
		var model = new WorkbenchTreeModel();
		model.update(view(null, null, reasons[0]), []);
		require(roots(model).join(",") == "s:error,n:new-workspace,n:folder-workspace", "an unreachable exohost: " + roots(model));
		require(model.machineMissing(), "the model does not know the machine is missing");
		model.update(view(null, null), []);
		require(roots(model)[0] == "s:loading" && !model.machineMissing(), "waiting for exohost: " + roots(model));
		model.update(view(machineWorkspaces, "resume", "a push failed"), ["resume" => lists(catalog("C:/work/resume"))]);
		require(!model.machineMissing(), "a failed push with a machine offers the retry");
		// Through a real TreeView: the row says why, and that clicking it retries.
		model.update(view(null, null, reasons[3]), []);
		var fonts = haxeon.ui.FontCollection.create();
		fonts.add("../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
		var context = new UiContext(null, fonts);
		var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.height = LayoutAxis.grow();
		var tree = new TreeView("workbench-tree", model, style);
		context.verifyRetentionEvery = 0;
		var root:RenderNode = null;
		for (_ in 0...3) root = context.submit(tree, new haxeon.ui.LayoutFrame(520, 300));
		var found = false;
		root.walk(function(node) {
			if (node.semantics != null && node.semantics.label != null && node.semantics.label.indexOf("not answering") >= 0 && node.semantics.label.indexOf("retry") >= 0) found = true;
		});
		require(found, "the row does not say why exohost is not reached and that it can be retried");
		context.dispose();
	}

	/** Through a real TreeView: the open workspace is expanded with its groups; the others are collapsed but expandable. */
	static function rendered():Void {
		var model = new WorkbenchTreeModel();
		var resume = lists(catalog("C:/work/resume"), agents("C:/work/resume"));
		model.update(view(machineWorkspaces, "resume"), ["resume" => resume]);
		var fonts = haxeon.ui.FontCollection.create();
		fonts.add("../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
		var context = new UiContext(null, fonts);
		var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.height = LayoutAxis.grow();
		var tree = new TreeView("workbench-tree", model, style);
		tree.hasChildrenHint = model.expandable;
		var root:RenderNode = null;
		function submit():Void { for (_ in 0...2) root = context.submit(tree, new haxeon.ui.LayoutFrame(320, 600)); }
		function visible():Array<String> {
			var keys:Array<String> = [];
			root.walk(function(node) {
				if (node.semantics != null && node.semantics.role == AccessibilityRole.TreeItem) keys.push(node.semantics.label);
			});
			return keys;
		}
		function labels():Array<String> {
			var found:Array<String> = [];
			root.walk(function(node) {
				if (node.semantics != null && node.semantics.role == AccessibilityRole.Text && node.semantics.label != null) found.push(node.semantics.label);
			});
			return found;
		}
		submit();
		require(visible().join(",") == "w:exo,w:resume,g:resume|work,g:resume|drafts,t:resume|t1,a:resume|a1,g:resume|apps,w:eon,n:new-workspace,n:folder-workspace",
			"rendered order: " + visible());
		require(tree.isExpanded("w:resume") && !tree.isExpanded("w:exo"), "the open workspace is not the expanded one");
		var text = labels();
		require(text.indexOf("Workspace resume-2026, open in this window · C:/work/resume") >= 0, "workspace label: " + text);
		require(text.indexOf("Workspace eon-series · no folders attached") >= 0, "folderless workspace label: " + text);
		require(text.indexOf("Group Work in workspace resume-2026 · C:/work/resume") >= 0, "group label names its workspace: " + text);
		// The keyboard: with the open workspace's row selected and focused, Down selects its first group and Enter activates that row.
		var activated:Array<String> = [];
		tree.onActivate = function(key, _) { activated.push(key); return true; }
		tree.select("w:resume", false);
		tree.focusItem("w:resume");
		submit();
		context.key(haxeon.ui.core.UiEventKind.KeyDown, haxeon.ui.core.UiKey.Down);
		submit();
		require(tree.selectedKey == "g:resume|work", "Down from the workspace row selected " + tree.selectedKey);
		context.key(haxeon.ui.core.UiEventKind.KeyDown, haxeon.ui.core.UiKey.Enter);
		submit();
		require(activated.join(",") == "g:resume|work", "Enter activated " + activated);
		tree.select("w:resume", false);
		submit();
		// Expanding a closed workspace only expands it: until its rows are in, it says it is loading.
		tree.setExpanded("w:exo", true);
		submit();
		require(tree.isExpanded("w:exo") && visible().slice(0, 2).join(",") == "w:exo,s:loading-rows|exo", "expanding a closed workspace: " + visible());
		text = labels();
		require(text.indexOf("Loading…") >= 0, "the loading note: " + text);
		// Once it is open with its lists read, its groups replace the note.
		var exo = lists(catalog("C:/src/exosuit"));
		model.update(view(machineWorkspaces, "exo"), ["exo" => exo, "resume" => resume]);
		tree.setExpanded("w:resume", false);
		submit();
		require(visible().join(",") == "w:exo,g:exo|work,g:exo|drafts,t:exo|t1,g:exo|apps,w:resume,w:eon,n:new-workspace,n:folder-workspace", "after switching: " + visible());
		// Collapsing the open workspace is the window's own choice and survives a refresh.
		tree.setExpanded("w:exo", false);
		model.update(view(machineWorkspaces, "exo"), ["exo" => exo, "resume" => resume]);
		submit();
		require(!tree.isExpanded("w:exo") && visible().join(",") == "w:exo,w:resume,w:eon,n:new-workspace,n:folder-workspace", "collapse did not stick");
		// Another window's focus marks its workspace and its group (M19 Phase 8); a window on a group marks the group and its workspace.
		var withWindows = view(machineWorkspaces, "resume");
		withWindows.windows = [{window: "w2", pid: 9, context: "m/eon/"}, {window: "w3", pid: 10, context: "m/resume/work"}];
		model.update(withWindows, ["resume" => resume]);
		tree.setExpanded("w:resume", true);
		submit();
		text = labels();
		require(text.indexOf("Workspace eon-series, open in another window · no folders attached") >= 0, "workspace in another window: " + text);
		require(text.indexOf("Workspace resume-2026, open in this window, open in another window · C:/work/resume") >= 0, "a window on a group of a workspace marks the workspace too: " + text);
		require(Lambda.exists(text, function(label) return StringTools.startsWith(label, "Group Work in workspace resume-2026") && StringTools.endsWith(label, ", open in another window")), "group in another window: " + text);
		require(!Lambda.exists(text, function(label) return StringTools.startsWith(label, "Group Drafts") && label.indexOf("another window") >= 0), "an unfocused group is not marked: " + text);
		model.update(view(machineWorkspaces, "resume"), ["resume" => resume]);
		tree.setExpanded("w:resume", true);
		submit();
		require(!Lambda.exists(labels(), function(label) return label.indexOf("another window") >= 0), "no other window, no marker: " + labels());
	}
}

/** A service endpoint rooted in `root`; with `serving`, it answers for the workspace's attached folder too. */
private class FakeEndpoint extends testing.TestEndpoint implements workspace.client.ServedRoots {
	final serving:Bool;
	public function new(root:String, serving:Bool) {
		super();
		this.root = root; this.serving = serving; generation = "g"; epoch = "e"; events = false;
	}
	public function servesRoot(path:String):Bool return serving && path == "C:/src/eon";
}
