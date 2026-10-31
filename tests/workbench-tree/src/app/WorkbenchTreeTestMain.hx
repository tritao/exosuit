package app;

import haxe.Int64;
// Works around a compiler defect: TabTooltip's default argument names config.Settings, and Haxeon resolves a package
// path in a default value only once a module of it is loaded (docs/roadmap/COMPILER-TYPING.md, Recorded defects).
import config.Settings;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.widgets.collections.TreeView;
import suit.MachineCatalog.MachineWorkspace;
import ui.AgentScope;
import ui.CatalogThrottle;
import ui.WorkbenchMachineLabel;
import ui.WorkbenchMachineView;
import ui.WorkbenchMachineView.WorkbenchWorkspaceState;
import ui.WorkbenchRowKind;
import workspace.client.WorkspaceCatalogMirror;
import ui.WorkbenchRowKey;
import ui.WorkbenchTreeModel;
import workspace.service.WorkspaceAgentProtocol.AgentCatalog;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;
import workspace.service.WorkspaceTerminalProtocol.TerminalCatalog;

/** The Workbench as one tree: workspaces, then the open workspace's groups, sessions and terminals; the machine above it. */
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

	static function view(workspaces:Null<Array<MachineWorkspace>>, open:Null<String>, roots:Array<String>, ?error:String):WorkbenchMachineView
		return {machine: workspaces == null ? null : {id: "m", name: "cube", workspaces: workspaces}, error: error,
			openWorkspace: open, openRoots: roots, revision: 1};

	static function children(model:WorkbenchTreeModel, key:String):Array<String>
		return [for (index in 0...model.childCount(key)) model.childKeyAt(key, index)];

	static function roots(model:WorkbenchTreeModel):Array<String>
		return [for (index in 0...model.rootCount()) model.rootKeyAt(index)];

	static final machineWorkspaces = [
		workspaceEntry("exo", "exosuit", ["C:/src/exosuit"]),
		workspaceEntry("resume", "resume-2026", ["C:/work/resume"]),
		workspaceEntry("eon", "eon-series", [])
	];

	static function main():Void {
		ordering();
		foreignWorkspaces();
		cyclicGroups();
		foreignProjection();
		catalogThrottle();
		emptyAndLoading();
		suitOff();
		workspaceRoot();
		switching();
		rendered();
		Sys.println("workbench-tree: ok");
	}

	/** Workspaces in suit's order, then New Workspace…; groups (by order), then their terminals and sessions. */
	static function ordering():Void {
		var model = new WorkbenchTreeModel();
		model.update(catalog("C:/work/resume"), agents("C:/work/resume"), null, view(machineWorkspaces, "resume", ["C:/work/resume"]));
		require(roots(model).join(",") == "w:exo,w:resume,w:eon,n:new-workspace", "the workspaces are not the roots: " + roots(model));
		require(children(model, "w:resume").join(",") == "g:work,g:apps", "open workspace's groups: " + children(model, "w:resume"));
		require(children(model, "g:work").join(",") == "g:drafts,t:t1,a:a1", "group contents: " + children(model, "g:work"));
		require(model.childCount("w:exo") == 0 && model.childCount("w:eon") == 0, "a workspace that is not open shows groups");
		require(model.groupParent == "w:resume" && model.openRow == "w:resume", "the groups' parent is not the open workspace");
		require(model.initiallyExpanded("w:resume") && model.initiallyExpanded("g:work"),
			"the open workspace or a top-level group starts collapsed");
		require(!model.initiallyExpanded("w:exo") && !model.initiallyExpanded("g:drafts"), "a closed workspace or sub-group starts expanded");
		require(model.expandable("w:eon") && model.expandable("w:resume") && !model.expandable("n:new-workspace") && !model.expandable("t:t1"),
			"every workspace and only workspaces expand without children");
		// The machine is no row: a selector above the tree names it, with this machine its only choice for now.
		var machines = ui.WorkbenchMachineSelector.choices(view(machineWorkspaces, "resume", ["C:/work/resume"]));
		require(machines.length == 1 && machines[0].label == "cube · this machine" && machines[0].value == ui.WorkbenchMachineSelector.THIS_MACHINE,
			"machine choices: " + [for (choice in machines) choice.label]);
		require(ui.WorkbenchMachineSelector.choices(view(null, null, []))[0].label == "This machine", "the machine before suit answers");
		var owner = model.groupWorkspace();
		require(owner != null && owner.name == "resume-2026", "the groups' workspace");
		// Machine rows are not group rows, so drag, menus and scope code pass over them.
		require(WorkbenchRowKey.parse("w:resume") == null && WorkbenchRowKey.parse("s:error") == null && WorkbenchRowKey.parse("n:new-workspace") == null,
			"a machine row parsed as a group row");
		require(WorkbenchRowKey.isMachineRow("w:resume") && WorkbenchRowKey.isMachineRow("s:error") && !WorkbenchRowKey.isMachineRow("g:work"),
			"machine row recognition");
		require(WorkbenchRowKey.statusKind(WorkbenchRowKey.status("error")) == "error" && WorkbenchRowKey.statusKind("w:resume") == null
			&& WorkbenchRowKey.statusKind("s:") == null, "status row kinds");
		var scope = AgentScope.resolve(model, null, null);
		require(scope != null && scope.groupId == "work", "the right panel's first-group fallback skipped the nested groups");
		require(scope.equals(AgentScope.resolve(model, "w:exo", scope)), "selecting a workspace row changed the scope");
		// Windows paths compare the Windows way.
		model.update(catalog("c:\\work\\resume"), null, null, view(machineWorkspaces, "resume", ["C:/work/resume"]));
		require(model.groupParent == "w:resume", "a differently spelled root kept the groups out");
	}

	/** A workspace the window is not attached to shows its catalog's groups, sessions and terminals, read-only; an idle one shows a marker. */
	static function foreignWorkspaces():Void {
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
		var shown = view(machineWorkspaces, "resume", ["C:/work/resume"]);
		shown.watched = watched;
		shown.watchRevision = 1;
		var model = new WorkbenchTreeModel();
		model.update(catalog("C:/work/resume"), agents("C:/work/resume"), null, shown);
		require(roots(model).join(",") == "w:exo,w:resume,w:eon,n:new-workspace", "foreign catalogs changed the roots: " + roots(model));
		var top = children(model, "w:exo");
		require(top.join(",") == "f:gexo|docs,f:gexo|build,f:aexo|s2", "foreign workspace's top level: " + top);
		var build = children(model, "f:gexo|build");
		require(build.join(",") == "f:gexo|lint,f:aexo|s1", "foreign group's contents: " + build);
		require(children(model, "f:gexo|lint").join(",") == "f:texo|t1", "foreign sub-group: " + children(model, "f:gexo|lint"));
		require(model.childCount("w:eon") == 0 && model.expandable("w:eon"), "an idle workspace has no rows but expands");
		require(model.childCount("w:resume") == 2 && model.groupParent == "w:resume", "the attached workspace still shows its own groups");
		// Foreign rows are not the attached workspace's rows, so drag, menus and scope code pass over them.
		require(WorkbenchRowKey.parse("f:gexo|build") == null && WorkbenchRowKey.isForeign("f:aexo|s1") && !WorkbenchRowKey.isMachineRow("f:aexo|s1"),
			"foreign rows are group rows");
		var parsed = WorkbenchRowKey.parseForeign("f:aexo|s1");
		require(parsed != null && parsed.kind == WorkbenchRowKind.Agent && parsed.workspace == "exo" && parsed.id == "s1", "foreign row parse");
		require(WorkbenchRowKey.foreign(WorkbenchRowKind.Terminal, "exo", "t1") == "f:texo|t1" && WorkbenchRowKey.parseForeign("g:work") == null, "foreign row spelling");
		var own = model.terminals.get("t1");
		require(!model.groups.exists("build") && !model.agents.exists("s1") && own != null && own.name == "Terminal",
			"foreign rows leaked into the attached workspace's maps");
		for (key in top.concat(build)) model.buildItem(key);
		model.buildItem("w:eon");
		model.buildItem("w:exo");
		// The marker says what a workspace is doing.
		require(WorkbenchMachineLabel.stateMarker(watched.get("exo")) == "running" && WorkbenchMachineLabel.stateMarker(watched.get("eon")) == "idle",
			"running and idle markers");
		require(WorkbenchMachineLabel.stateMarker({running: true, live: false, starting: false, catalog: null}) == "reconnecting"
			&& WorkbenchMachineLabel.stateMarker({running: false, live: false, starting: true, catalog: null}) == "starting…"
			&& WorkbenchMachineLabel.stateMarker(null) == null, "reconnecting and starting markers");
		// The window's own workspace is read through its full client, never its catalog.
		watched.set("resume", {running: true, live: true, starting: false, catalog: mirror});
		model.update(catalog("C:/work/resume"), agents("C:/work/resume"), null, shown);
		require(children(model, "w:resume").join(",") == "g:work,g:apps", "the attached workspace's own catalog drew foreign rows: " + children(model, "w:resume"));
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

	/** Only expanded workspaces project their catalogs, and a projection is rebuilt only when its catalog changed. */
	static function foreignProjection():Void {
		var page = function(token:String, reset:Bool, name:String):workspace.service.WorkspaceCatalogProtocol.WorkspaceCatalog return {ref: {machine: "m", workspace: "exo"}, instance: "i",
			token: token, reset: reset, more: false, name: "exosuit", folders: [], scratch: null, status: "running", attention: 0, groups: [group("g", name, null, 0)],
			sessions: [{id: "s", name: "Session", group: "g", directory: "/d", provider: null, state: "idle", attention: 0}], terminals: [],
			removedGroups: [], removedSessions: [], removedTerminals: [], watching: true};
		var exo = new WorkspaceCatalogMirror(), other = new WorkspaceCatalogMirror();
		exo.apply(page("t1", true, "Build"));
		var otherPage = page("t1", true, "Other");
		otherPage.ref.workspace = "resume";
		other.apply(otherPage);
		var watched:Map<String, WorkbenchWorkspaceState> = [];
		watched.set("exo", {running: true, live: true, starting: false, catalog: exo});
		watched.set("eon", {running: true, live: true, starting: false, catalog: other});
		var shown = view(machineWorkspaces, "resume", ["C:/work/resume"]);
		shown.watched = watched;
		shown.watchRevision = 1;
		var model = new WorkbenchTreeModel();
		var expanded:Map<String, Bool> = [];
		model.expandedRows = expanded;
		model.update(catalog("C:/work/resume"), agents("C:/work/resume"), null, shown);
		require(model.childCount("w:exo") == 0 && model.childCount("w:eon") == 0 && model.projectionBuilds == 0, "nothing is projected while every workspace is collapsed");
		expanded.set("w:exo", true);
		model.update(catalog("C:/work/resume"), agents("C:/work/resume"), null, shown);
		require(children(model, "w:exo").join(",") == "f:gexo|g" && model.childCount("w:eon") == 0 && model.projectionBuilds == 1, "only the expanded workspace projects");
		model.update(catalog("C:/work/resume"), agents("C:/work/resume"), null, shown);
		require(model.projectionBuilds == 1 && children(model, "f:gexo|g").join(",") == "f:aexo|s", "an unchanged catalog reuses its projection");
		expanded.set("w:eon", true);
		model.update(catalog("C:/work/resume"), agents("C:/work/resume"), null, shown);
		require(model.projectionBuilds == 2, "expanding another workspace builds only that one");
		var change = page("t2", false, "Renamed");
		exo.apply(change);
		model.update(catalog("C:/work/resume"), agents("C:/work/resume"), null, shown);
		require(model.projectionBuilds == 3, "one workspace's change rebuilds that workspace alone: " + model.projectionBuilds);
		expanded.remove("w:eon");
		model.update(catalog("C:/work/resume"), agents("C:/work/resume"), null, shown);
		require(model.childCount("w:eon") == 0 && model.childCount("w:exo") == 1, "collapsing hides a workspace's rows");
	}

	/** A group naming itself, a descendant, or a missing group as its parent sits at the workspace root; the tree is finite. */
	static function cyclicGroups():Void {
		var mirror = new WorkspaceCatalogMirror();
		mirror.apply({ref: {machine: "m", workspace: "exo"}, instance: "i", token: "t1", reset: true, more: false, name: "exosuit", folders: [],
			scratch: null, status: "running", attention: 0,
			groups: [group("a", "Self", "a", 0), group("b", "Loop one", "c", 1), group("c", "Loop two", "b", 2), group("d", "Under the loop", "b", 3),
				group("o", "Orphan", "missing", 4), group("k", "Kid", "o", 5)],
			sessions: [], terminals: [], removedGroups: [], removedSessions: [], removedTerminals: [], watching: true});
		var watched:Map<String, WorkbenchWorkspaceState> = [];
		watched.set("exo", {running: true, live: true, starting: false, catalog: mirror});
		var shown = view(machineWorkspaces, "resume", ["C:/work/resume"]);
		shown.watched = watched;
		shown.watchRevision = 1;
		var model = new WorkbenchTreeModel();
		model.update(catalog("C:/work/resume"), agents("C:/work/resume"), null, shown);
		var top = children(model, "w:exo");
		for (id in ["a", "b", "c", "d", "o"])
			require(top.indexOf("f:g" + "exo|" + id) >= 0, "group " + id + " sits at the workspace root: " + top);
		require(top.indexOf("f:gexo|k") < 0 && children(model, "f:gexo|o").join(",") == "f:gexo|k", "an ordinary child stays under an orphan");
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

	/** No workspaces, suit still answering, and suit failing are rows of the tree, above New Workspace…. */
	static function emptyAndLoading():Void {
		var model = new WorkbenchTreeModel();
		model.update(null, null, null, view([], null, []));
		require(roots(model).join(",") == "s:empty,n:new-workspace", "empty machine: " + roots(model));
		model.update(null, null, null, view(null, null, []));
		require(roots(model).join(",") == "s:loading,n:new-workspace", "loading: " + roots(model));
		model.update(null, null, null, view(null, null, [], "suit is not running"));
		require(roots(model).join(",") == "s:error,n:new-workspace", "suit error: " + roots(model));
		model.update(null, null, null, view(machineWorkspaces, "resume", ["C:/work/resume"], "suit did not answer"));
		require(roots(model).join(",") == "w:exo,w:resume,w:eon,s:error,n:new-workspace",
			"a refresh error hid the known workspaces");
		// A folderless workspace, open on its scratch folder, nests its groups like any other.
		model.update(catalog("C:/Users/me/Exosuit/eon-series"), null, null, view(machineWorkspaces, "eon", ["C:/Users/me/Exosuit/eon-series"]));
		require(children(model, "w:eon").join(",") == "g:work,g:apps", "a scratch-folder workspace's groups");
		// Once it has a folder, it opens on that folder; the scratch folder stays apart and the groups nest plainly.
		var attached = [workspaceEntry("eon", "eon-series", ["C:/src/eon"], "C:/Users/me/Exosuit/eon-series")];
		model.update(catalog("C:/src/eon"), null, null, view(attached, "eon", ["C:/src/eon"]));
		require(children(model, "w:eon").join(",") == "g:work,g:apps", "an attached folder's groups: " + children(model, "w:eon"));
	}

	/** Sessions and terminals in no group sit directly under the workspace, after its top-level groups. */
	static function workspaceRoot():Void {
		var terminals = catalog("C:/work/resume"), sessions = agents("C:/work/resume");
		terminals.terminals[0].group = WorkspaceProtocol.ROOT_GROUP;
		sessions.records[0].group = WorkspaceProtocol.ROOT_GROUP;
		var model = new WorkbenchTreeModel();
		model.update(terminals, sessions, null, view(machineWorkspaces, "resume", ["C:/work/resume"]));
		require(children(model, "w:resume").join(",") == "g:work,g:apps,t:t1,a:a1", "workspace root items: " + children(model, "w:resume"));
		require(children(model, "g:work").join(",") == "g:drafts", "a root item stayed in its old group");
		require(WorkbenchRowKey.groupOf(model, "t:t1") == null && WorkbenchRowKey.parentGroupId(model, "a:a1") == WorkspaceProtocol.ROOT_GROUP,
			"a root item has a group");
		// A root item, or the workspace row, scopes the right panel to the workspace; the scope then stays.
		var scope = AgentScope.resolve(model, "a:a1", null);
		require(scope != null && WorkspaceProtocol.isRoot(scope.groupId) && scope.label == "resume-2026" && scope.directory == "C:/work/resume",
			"a root item did not scope to the workspace");
		require(scope.equals(AgentScope.resolve(model, null, scope)) && scope.equals(AgentScope.resolve(model, "w:resume", null)),
			"the workspace scope did not stay or the workspace row did not choose it");
		var group = AgentScope.resolve(model, "g:drafts", scope);
		require(group != null && group.groupId == "drafts", "a group row did not take over from the workspace scope");
		model.update(terminals, sessions);
		require(roots(model).join(",") == "g:work,g:apps,t:t1,a:a1", "suit off root items: " + roots(model));
		require(!model.initiallyExpanded("t:t1") && !model.expandable("a:a1"), "a root item expands");
	}

	/** With suit off there is no machine: the tree is today's group tree. */
	static function suitOff():Void {
		var model = new WorkbenchTreeModel();
		model.update(catalog("C:/work/resume"), agents("C:/work/resume"));
		require(roots(model).join(",") == "g:work,g:apps", "suit off roots: " + roots(model));
		require(model.groupParent == null && model.openRow == null && model.machine == null, "suit off kept machine state");
		require(model.initiallyExpanded("g:work") && !model.expandable("g:apps"), "suit off expansion");
		model.update(null);
		require(model.rootCount() == 0, "suit off without a catalog has rows");
	}

	/** While a switch is under way, the old service's groups never appear under the new workspace. */
	static function switching():Void {
		var model = new WorkbenchTreeModel();
		model.update(catalog("C:/work/resume"), null, null, view(machineWorkspaces, "exo", ["C:/src/exosuit"]));
		require(model.openRow == "w:exo" && model.groupParent == null && model.childCount("w:exo") == 0 && model.childCount("w:resume") == 0,
			"the previous workspace's groups showed under the new one");
		require(roots(model).join(",") == "w:exo,w:resume,w:eon,n:new-workspace", "waiting groups leaked to the roots");
		// A window whose folders are none of the machine's workspaces keeps its groups, after the machine's rows.
		model.update(catalog("C:/elsewhere"), null, null, view(machineWorkspaces, null, ["C:/elsewhere"]));
		require(roots(model).join(",") == "w:exo,w:resume,w:eon,n:new-workspace,g:work,g:apps", "an unlisted folder's groups: " + roots(model));
	}

	/** Through a real TreeView: the open workspace is expanded with its groups; the others are collapsed but expandable. */
	static function rendered():Void {
		var model = new WorkbenchTreeModel();
		model.update(catalog("C:/work/resume"), agents("C:/work/resume"), null, view(machineWorkspaces, "resume", ["C:/work/resume"]));
		var fonts = haxeon.ui.FontCollection.create();
		fonts.add("../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
		var context = new UiContext(null, fonts);
		var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.height = LayoutAxis.grow();
		var tree = new TreeView("workbench-tree", model, style);
		tree.hasChildrenHint = model.expandable;
		var opened:Array<String> = [];
		tree.onExpansionRequested = function(key, expanded, _) {
			var id = WorkbenchRowKey.workspaceId(key);
			if (id == null || !expanded || key == model.openRow) return true;
			opened.push(id);
			return false;
		};
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
		require(visible().join(",") == "w:exo,w:resume,g:work,g:drafts,t:t1,a:a1,g:apps,w:eon,n:new-workspace",
			"rendered order: " + visible());
		require(tree.isExpanded("w:resume") && !tree.isExpanded("w:exo"), "the open workspace is not the expanded one");
		var text = labels();
		require(text.indexOf("Workspace resume-2026, open in this window · C:/work/resume") >= 0, "workspace label: " + text);
		require(text.indexOf("Workspace eon-series · no folders attached") >= 0, "folderless workspace label: " + text);
		require(text.indexOf("Group Work in workspace resume-2026 · C:/work/resume") >= 0, "group label names its workspace: " + text);
		// Expanding a closed workspace asks to open it instead, and leaves it closed until it is.
		tree.setExpanded("w:exo", true);
		submit();
		require(opened.join(",") == "exo" && !tree.isExpanded("w:exo"), "expanding a closed workspace did not ask to open it");
		// Once it is open (its service attached), it expands; the previous one collapses.
		model.update(catalog("C:/src/exosuit"), null, null, view(machineWorkspaces, "exo", ["C:/src/exosuit"]));
		tree.setExpanded("w:resume", false);
		tree.setExpanded("w:exo", true);
		submit();
		require(visible().join(",") == "w:exo,g:work,g:drafts,t:t1,g:apps,w:resume,w:eon,n:new-workspace", "after switching: " + visible());
		// Collapsing the open workspace is the window's own choice and survives a refresh.
		tree.setExpanded("w:exo", false);
		model.update(catalog("C:/src/exosuit"), null, null, view(machineWorkspaces, "exo", ["C:/src/exosuit"]));
		submit();
		require(!tree.isExpanded("w:exo") && visible().join(",") == "w:exo,w:resume,w:eon,n:new-workspace", "collapse did not stick");
	}
}
