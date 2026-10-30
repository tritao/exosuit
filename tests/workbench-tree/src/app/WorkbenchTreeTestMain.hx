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
import ui.WorkbenchMachineView;
import ui.WorkbenchRowKey;
import ui.WorkbenchTreeModel;
import workspace.service.WorkspaceAgentProtocol.AgentCatalog;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;
import workspace.service.WorkspaceTerminalProtocol.TerminalCatalog;

/** The Workbench as one tree: machine, workspaces, then the open workspace's groups, sessions and terminals. */
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
		emptyAndLoading();
		suitOff();
		switching();
		rendered();
		Sys.println("workbench-tree: ok");
	}

	/** Machine, then workspaces in suit's order, then New Workspace…; groups (by order), then their terminals and sessions. */
	static function ordering():Void {
		var model = new WorkbenchTreeModel();
		model.update(catalog("C:/work/resume"), agents("C:/work/resume"), null, view(machineWorkspaces, "resume", ["C:/work/resume"]));
		require(roots(model).join(",") == "m:this", "the machine is not the only root: " + roots(model));
		require(children(model, WorkbenchRowKey.MACHINE).join(",") == "w:exo,w:resume,w:eon,n:new-workspace",
			"machine rows: " + children(model, WorkbenchRowKey.MACHINE));
		require(children(model, "w:resume").join(",") == "g:work,g:apps", "open workspace's groups: " + children(model, "w:resume"));
		require(children(model, "g:work").join(",") == "g:drafts,t:t1,a:a1", "group contents: " + children(model, "g:work"));
		require(model.childCount("w:exo") == 0 && model.childCount("w:eon") == 0, "a workspace that is not open shows groups");
		require(model.groupParent == "w:resume" && model.openRow == "w:resume", "the groups' parent is not the open workspace");
		require(model.initiallyExpanded("m:this") && model.initiallyExpanded("w:resume") && model.initiallyExpanded("g:work"),
			"machine, open workspace or top-level group starts collapsed");
		require(!model.initiallyExpanded("w:exo") && !model.initiallyExpanded("g:drafts"), "a closed workspace or sub-group starts expanded");
		require(model.expandable("w:eon") && model.expandable("w:resume") && !model.expandable("n:new-workspace") && !model.expandable("t:t1"),
			"every workspace and only workspaces expand without children");
		var owner = model.groupWorkspace();
		require(owner != null && owner.name == "resume-2026", "the groups' workspace");
		// Machine rows are not group rows, so drag, menus and scope code pass over them.
		require(WorkbenchRowKey.parse("w:resume") == null && WorkbenchRowKey.parse("m:this") == null && WorkbenchRowKey.parse("n:new-workspace") == null,
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

	/** No workspaces, suit still answering, and suit failing are rows of the tree, above New Workspace…. */
	static function emptyAndLoading():Void {
		var model = new WorkbenchTreeModel();
		model.update(null, null, null, view([], null, []));
		require(children(model, WorkbenchRowKey.MACHINE).join(",") == "s:empty,n:new-workspace", "empty machine: " + children(model, WorkbenchRowKey.MACHINE));
		model.update(null, null, null, view(null, null, []));
		require(children(model, WorkbenchRowKey.MACHINE).join(",") == "s:loading,n:new-workspace", "loading: " + children(model, WorkbenchRowKey.MACHINE));
		model.update(null, null, null, view(null, null, [], "suit is not running"));
		require(children(model, WorkbenchRowKey.MACHINE).join(",") == "s:error,n:new-workspace", "suit error: " + children(model, WorkbenchRowKey.MACHINE));
		model.update(null, null, null, view(machineWorkspaces, "resume", ["C:/work/resume"], "suit did not answer"));
		require(children(model, WorkbenchRowKey.MACHINE).join(",") == "w:exo,w:resume,w:eon,s:error,n:new-workspace",
			"a refresh error hid the known workspaces");
		// A folderless workspace, open on its scratch folder, nests its groups like any other.
		model.update(catalog("C:/Users/me/Exosuit/eon-series"), null, null, view(machineWorkspaces, "eon", ["C:/Users/me/Exosuit/eon-series"]));
		require(children(model, "w:eon").join(",") == "g:work,g:apps", "a scratch-folder workspace's groups");
		// Once it has a folder, it opens on that folder; the scratch folder stays apart and the groups nest plainly.
		var attached = [workspaceEntry("eon", "eon-series", ["C:/src/eon"], "C:/Users/me/Exosuit/eon-series")];
		model.update(catalog("C:/src/eon"), null, null, view(attached, "eon", ["C:/src/eon"]));
		require(children(model, "w:eon").join(",") == "g:work,g:apps", "an attached folder's groups: " + children(model, "w:eon"));
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
		require(roots(model).join(",") == "m:this", "waiting groups leaked to the roots");
		// A window whose folders are none of the machine's workspaces keeps its groups, after the machine.
		model.update(catalog("C:/elsewhere"), null, null, view(machineWorkspaces, null, ["C:/elsewhere"]));
		require(roots(model).join(",") == "m:this,g:work,g:apps", "an unlisted folder's groups: " + roots(model));
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
		require(visible().join(",") == "m:this,w:exo,w:resume,g:work,g:drafts,t:t1,a:a1,g:apps,w:eon,n:new-workspace",
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
		require(visible().join(",") == "m:this,w:exo,g:work,g:drafts,t:t1,g:apps,w:resume,w:eon,n:new-workspace", "after switching: " + visible());
		// Collapsing the open workspace is the window's own choice and survives a refresh.
		tree.setExpanded("w:exo", false);
		model.update(catalog("C:/src/exosuit"), null, null, view(machineWorkspaces, "exo", ["C:/src/exosuit"]));
		submit();
		require(!tree.isExpanded("w:exo") && visible().join(",") == "m:this,w:exo,w:resume,w:eon,n:new-workspace", "collapse did not stick");
	}
}
