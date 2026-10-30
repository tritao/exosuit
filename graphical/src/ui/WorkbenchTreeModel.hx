package ui;

import haxeon.ui.core.View;
import haxeon.ui.widgets.collections.TreeViewModel;
import haxeon.ui.widgets.collections.TreeRootMetadata;
import haxeon.ui.widgets.text.Text;
import suit.MachineCatalog.MachineWorkspace;
import workspace.PathKey;
import workspace.service.GroupFolders;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalProtocol;

/**
	Projection only: grouping/status belong to the service, expansion/selection to TreeView.

	With suit on, the tree is one tree (docs/architecture/0006-workspaces-without-folders.md): this machine, then its
	workspaces, status lines and New Workspace…; the open workspace's groups, sessions and terminals nest under its row.
	With suit off it is the group tree alone.
**/
class WorkbenchTreeModel implements TreeViewModel {
	public final groups:Map<String, WorkspaceGroup> = [];
	/** The machine's workspaces by id; empty when suit is off. */
	public final workspaces:Map<String, MachineWorkspace> = [];
	/**
		The rows directly in the workspace, wherever they sit: its top-level groups, then the sessions and terminals at
		its root (in no group).
	**/
	public final groupRoots:Array<String> = [];
	/** The row the top-level groups sit under: the open workspace's, or null when they are roots. */
	public var groupParent(default, null):Null<String>;
	/** The open workspace's row, attached or not; null without one. */
	public var openRow(default, null):Null<String>;
	public var machine(default, null):Null<WorkbenchMachineView>;
	public final agents:Map<String, workspace.service.WorkspaceAgentProtocol.AgentRecord> = [];
	public final terminals:Map<String, TerminalRecord> = [];

	final children:Map<String, Array<String>> = [];
	final roots:Array<String> = [];
	var version:Int = 0;
	public var groupEditor:Null<String->Null<View>>;
	public var agentEditor:Null<String->Null<View>>;
	/** The open workspace's first folder, as the service serves it; null without a catalog. */
	public var workspaceRoot(default, null):Null<String>;

	public function new() {}

	public function update(catalog:Null<TerminalCatalog>, ?agentCatalog:workspace.service.WorkspaceAgentProtocol.AgentCatalog, ?draft:WorkspaceGroup,
			?machine:WorkbenchMachineView):Void {
		agents.clear();
		groups.clear();
		terminals.clear();
		children.clear();
		roots.resize(0);
		groupRoots.resize(0);
		workspaces.clear();
		groupParent = null;
		openRow = null;
		this.machine = machine;
		version++;
		workspaceRoot = catalog == null ? null : catalog.workspaceRoot;
		if (catalog != null)
			projectGroups(catalog, agentCatalog, draft);
		if (machine == null) {
			for (key in groupRoots) roots.push(key);
			return;
		}
		projectMachine(machine, catalog);
	}

	/** The machine row, its workspaces and status lines; the groups go under the open workspace once its service is attached. */
	function projectMachine(view:WorkbenchMachineView, catalog:Null<TerminalCatalog>):Void {
		var rows:Array<String> = [];
		roots.push(WorkbenchRowKey.MACHINE);
		children.set(WorkbenchRowKey.MACHINE, rows);
		var state = view.machine;
		if (state != null)
			for (entry in state.workspaces) {
				var key = WorkbenchRowKey.machineWorkspace(entry.id);
				workspaces.set(entry.id, entry);
				rows.push(key);
				children.set(key, []);
				if (entry.id == view.openWorkspace) openRow = key;
			}
		if (state != null && state.workspaces.length == 0)
			rows.push(WorkbenchRowKey.status("empty"));
		else if (state == null && view.error == null)
			rows.push(WorkbenchRowKey.status("loading"));
		if (view.error != null)
			rows.push(WorkbenchRowKey.status("error"));
		rows.push(WorkbenchRowKey.NEW_WORKSPACE);
		if (catalog == null)
			return;
		var open = openRow;
		if (open == null) {
			// This window's folders are none of the machine's workspaces (or suit has not answered): the groups follow the machine.
			for (key in groupRoots) roots.push(key);
			return;
		}
		// While a switch is under way the service still holds the previous workspace's groups; they wait.
		// A service too old to name its folder is taken to serve this window's.
		var served = catalog.workspaceRoot;
		if (served != null && !Lambda.exists(view.openRoots, function(root) return PathKey.same(root, served)))
			return;
		groupParent = open;
		children.set(open, groupRoots.copy());
	}

	function projectGroups(catalog:TerminalCatalog, agentCatalog:Null<workspace.service.WorkspaceAgentProtocol.AgentCatalog>, draft:Null<WorkspaceGroup>):Void {
		var ordered = catalog.groups.copy();
        if (draft != null && !Lambda.exists(ordered, function(g) return g.id == draft.id)) ordered.push(draft);
		ordered.sort(function(a, b) {
			var order = WorkspaceProtocol.order(a.order) - WorkspaceProtocol.order(b.order);
			return order == 0 ? Reflect.compare(a.id, b.id) : order;
		});
		for (g in ordered) {
			groups.set(g.id, g);
			children.set(WorkbenchRowKey.group(g.id), []);
		}
		for (g in ordered) {
			var siblings = g.parent == null ? groupRoots : children.get(WorkbenchRowKey.group(g.parent));
			if (siblings != null)
				siblings.push(WorkbenchRowKey.group(g.id));
		}
		for (t in catalog.terminals) {
			terminals.set(t.id, t);
			var siblings = itemsOf(t.group);
			if (siblings != null)
				siblings.push(WorkbenchRowKey.terminal(t.id));
		}
		if (agentCatalog != null)
			for (a in agentCatalog.records) {
				agents.set(a.id, a);
				var siblings = itemsOf(a.group);
				if (siblings != null)
					siblings.push(WorkbenchRowKey.agent(a.id));
			}
	}

	/** The rows a session or terminal in `group` joins: the group's, or the workspace's own (`groupRoots`) at its root. */
	function itemsOf(group:String):Null<Array<String>>
		return WorkspaceProtocol.isRoot(group) ? groupRoots : children.get(WorkbenchRowKey.group(group));

	public function rootCount():Int
		return roots.length;

	public function rootRange(start:Int, count:Int):Array<TreeRootMetadata>
		return [
			for (index in start...Std.int(Math.min(roots.length, start + count)))
				new TreeRootMetadata(roots[index], true)
		];

	public function rootKeyAt(index:Int):String
		return roots[index];

	public function childCount(key:String):Int {
		var items = children.get(key);
		return items == null ? 0 : items.length;
	}

	public function childKeyAt(key:String, index:Int):String {
		var items = children.get(key);
		if (items == null)
			throw "Unknown tree branch";
		return items[index];
	}

	public function initiallyExpanded(key:String):Bool
		return key == WorkbenchRowKey.MACHINE || key == openRow || WorkbenchRowKey.isKind(key, WorkbenchRowKind.Group) && groupRoots.indexOf(key) >= 0;

	/** True for a row the tree draws as expandable even without children: every workspace, open or not. */
	public function expandable(key:String):Bool
		return childCount(key) > 0 || WorkbenchRowKey.workspaceId(key) != null;

	/** The workspace whose groups the tree shows, or null. */
	public function groupWorkspace():Null<MachineWorkspace> {
		var id = WorkbenchRowKey.workspaceId(groupParent);
		return id == null ? null : workspaces.get(id);
	}

	public function estimatedExtent():Float
		return WorkbenchSessionLabel.ROW_HEIGHT;

	public function extentIsUniform():Bool
		return true;

	public function extentAt(key:String):Float
		return WorkbenchSessionLabel.ROW_HEIGHT;

	public function revision():Int
		return version;

	static function agentStateLabel(state:String):String {
		return switch (state) {
			case "reconnecting": "Reconnecting…";
			case "reconnect-failed": "Session unavailable";
			case "disconnected": "Disconnected";
			default: state;
		};
	}

	public function buildItem(key:String):View {
		if (WorkbenchRowKey.isMachineRow(key)) return machineItem(key);
		var row = WorkbenchRowKey.parse(key);
		if (row == null) return new Text("");
		var editing:Null<View> = null;
		if (row.kind == WorkbenchRowKind.Group && groupEditor != null) editing = groupEditor(row.id);
		if (row.kind == WorkbenchRowKind.Agent && agentEditor != null) editing = agentEditor(row.id);
		if (editing != null) return editing;
		switch row.kind {
			case WorkbenchRowKind.Group:
				var group = groups.get(row.id);
				if (group != null) {
					var owner = groupWorkspace();
					return new WorkbenchGroupLabel(group.name, directory(group), workspaceRoot, owner == null ? null : owner.name);
				}
			case WorkbenchRowKind.Agent:
				var a = agents.get(row.id);
				if (a != null) return new WorkbenchSessionLabel(a.name, a.state, agentStateLabel(a.state));
			case WorkbenchRowKind.Terminal:
				var terminal = terminals.get(row.id);
				if (terminal != null) return new WorkbenchSessionLabel(terminal.name, terminal.state, TerminalStateLabels.display(terminal.state));
		}
		return new Text("");
	}

	function machineItem(key:String):View {
		var view = machine;
		if (view == null) return new Text("");
		if (key == WorkbenchRowKey.MACHINE) {
			var state = view.machine;
			return WorkbenchMachineLabel.machine(state == null ? "This machine" : state.name + " · this machine");
		}
		if (key == WorkbenchRowKey.NEW_WORKSPACE) return WorkbenchMachineLabel.newWorkspace();
		var id = WorkbenchRowKey.workspaceId(key);
		if (id != null) {
			var entry = workspaces.get(id);
			return entry == null ? new Text("") : WorkbenchMachineLabel.workspace(entry, key == openRow);
		}
		var error = view.error;
		return switch WorkbenchRowKey.statusKind(key) {
			case "empty": WorkbenchMachineLabel.status("No workspaces yet. Make one to hold groups, sessions and terminals.");
			case "loading": WorkbenchMachineLabel.status("Looking for this machine's workspaces…");
			case "error": WorkbenchMachineLabel.status(error == null ? "" : error, true);
			default: new Text("");
		};
	}

	public function directory(group:WorkspaceGroup):Null<String> {
		var folder = GroupFolders.nearest(groups, group);
		return folder == null ? workspaceRoot : folder;
	}

	public function nextOrder(parent:Null<String>):Int {
		var next = 0;
		for (g in groups)
			if (g.parent == parent)
				next = Std.int(Math.max(next, WorkspaceProtocol.order(g.order) + 1));
		return Std.int(Math.min(1000000, next));
	}
}
