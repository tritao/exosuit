package ui;

import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.widgets.collections.TreeViewModel;
import haxeon.ui.widgets.collections.TreeRootMetadata;
import haxeon.ui.widgets.text.Text;
import suit.MachineCatalog.MachineWorkspace;
import workspace.client.WorkspaceCatalogMirror;
import workspace.PathKey;
import workspace.service.GroupFolders;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalProtocol;
import workspace.service.WorkspaceCatalogProtocol.CatalogSession;
import workspace.service.WorkspaceCatalogProtocol.CatalogTerminal;
import ui.WorkbenchMachineView.WorkbenchWorkspaceState;

/**
	Projection only: grouping/status belong to the service, expansion/selection to TreeView.

	With suit on, the tree is one tree (docs/architecture/0006-workspaces-without-folders.md): the machine's workspaces,
	status lines and New Workspace…; the open workspace's groups, sessions and terminals nest under its row. The machine
	itself is chosen above the tree (WorkbenchMachineSelector). With suit off it is the group tree alone.
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
	/** Rows of the other workspaces, from their catalogs (M19 Phase 6): read-only, keyed by `WorkbenchRowKey.foreign`. */
	final foreignGroups:Map<String, ForeignGroup> = [];
	final foreignTerminals:Map<String, CatalogTerminal> = [];
	final foreignSessions:Map<String, CatalogSession> = [];
	/** The other workspaces' rows as last built, per workspace id, reused while the catalog copy has the same revision. */
	final projections:Map<String, ForeignProjection> = [];
	final projected:Map<String, Bool> = [];
	/** Projections built so far: tests and measurements count them. */
	public var projectionBuilds(default, null):Int = 0;
	/**
		The workspace rows (`w:` keys) the tree shows expanded; only those project their catalogs. Null projects every workspace.
		Set before `update`: the tree is not asked from inside it.
	**/
	public var expandedRows:Null<Map<String, Bool>>;

	final children:Map<String, Array<String>> = [];
	final roots:Array<String> = [];
	/** How each group, terminal and session row sorts among its siblings. */
	final places:Map<String, RowPlace> = [];
	/** The latest node each row built, to find the row under the pointer while a drag is over the tree. */
	final nodes:Map<String, ProbedRow> = [];
	var probes:Int = 0;
	/** Bumped when rows are built or laid out again; the row index below is valid for one value of it. */
	var layout:Int = 0;
	var indexed:Int = -1;
	/** The tree the rows are laid out in, as last reported; a row that was in it and no longer is has been replaced. */
	var tree:Null<RenderNode>;
	var index:Array<RowSpot> = [];
	var version:Int = 0;
	/** The row an insertion line is drawn at, and whether on its lower edge; null when no drop would land between rows. */
	public var insertion(default, null):Null<String>;
	public var insertionAfter(default, null):Bool = false;
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
		places.clear();
		nodes.clear();
		layout++;
		workspaces.clear();
		foreignGroups.clear();
		foreignTerminals.clear();
		foreignSessions.clear();
		projected.clear();
		groupParent = null;
		openRow = null;
		this.machine = machine;
		version++;
		workspaceRoot = catalog == null ? null : catalog.workspaceRoot;
		if (catalog != null)
			projectGroups(catalog, agentCatalog, draft);
		if (machine == null) {
			for (key in groupRoots) roots.push(key);
			projections.clear();
			return;
		}
		projectMachine(machine, catalog);
		for (id in [for (key in projections.keys()) key])
			if (!projected.exists(id))
				projections.remove(id);
	}

	/** The machine's workspaces and status lines; the groups go under the open workspace once its service is attached. */
	function projectMachine(view:WorkbenchMachineView, catalog:Null<TerminalCatalog>):Void {
		var rows = roots;
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
		// The other workspaces' groups, sessions and terminals come from their catalogs, whether or not the attached one is known yet.
		var watched = view.watched;
		if (state != null && watched != null)
			for (entry in state.workspaces) {
				var watchedState = watched.get(entry.id);
				if (entry.id != view.openWorkspace && watchedState != null)
					projectForeign(entry, watchedState);
			}
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

	/**
		A workspace this window is not attached to: its catalog's groups, sessions and terminals under its row, read-only.
		Only a workspace the tree shows expanded (`expandedRows`; all of them while it is null) is projected, and a projection is
		reused until its catalog changes, so a busy session in one workspace rebuilds that workspace's rows alone.
	**/
	function projectForeign(entry:MachineWorkspace, state:WorkbenchWorkspaceState):Void {
		var mirror = state.catalog;
		var rootKey = WorkbenchRowKey.machineWorkspace(entry.id);
		if (mirror == null || !children.exists(rootKey))
			return;
		var shown = expandedRows;
		if (shown != null && !shown.exists(rootKey))
			return;
		var id = entry.id;
		projected.set(id, true);
		var cached = projections.get(id);
		if (cached == null || cached.mirror != mirror || cached.revision != mirror.revision) {
			cached = buildForeign(id, mirror);
			projections.set(id, cached);
			projectionBuilds++;
		}
		children.set(rootKey, cached.top);
		for (key => items in cached.kids)
			children.set(key, items);
		for (key => group in cached.groups)
			foreignGroups.set(key, group);
		for (key => terminal in cached.terminals)
			foreignTerminals.set(key, terminal);
		for (key => session in cached.sessions)
			foreignSessions.set(key, session);
		for (key => place in cached.places)
			places.set(key, place);
	}

	function buildForeign(id:String, mirror:WorkspaceCatalogMirror):ForeignProjection {
		var built = new ForeignProjection(mirror);
		var top = built.top, kids = built.kids, placed = built.places;
		var groupList = mirror.groupList();
		for (g in groupList) {
			var key = WorkbenchRowKey.foreign(WorkbenchRowKind.Group, id, g.id);
			built.groups.set(key, new ForeignGroup(id, g));
			kids.set(key, []);
			placed.set(key, new RowPlace(WorkspaceProtocol.order(g.order), 0, 0));
		}
		var byId:Map<String, WorkspaceGroup> = [];
		for (g in groupList)
			byId.set(g.id, g);
		for (g in groupList) {
			// A group that is its own ancestor, or hangs under one, sits at the workspace root instead of making a subtree without end.
			var parent = inCycle(g, byId, groupList.length) ? null : g.parent;
			var siblings = parent == null ? top : kids.get(WorkbenchRowKey.foreign(WorkbenchRowKind.Group, id, parent));
			(siblings == null ? top : siblings).push(WorkbenchRowKey.foreign(WorkbenchRowKind.Group, id, g.id));
		}
		var arrival = 0;
		for (t in mirror.terminalList()) {
			var key = WorkbenchRowKey.foreign(WorkbenchRowKind.Terminal, id, t.id);
			built.terminals.set(key, t);
			var siblings = WorkspaceProtocol.isRoot(t.group) ? top : kids.get(WorkbenchRowKey.foreign(WorkbenchRowKind.Group, id, t.group));
			(siblings == null ? top : siblings).push(key);
			placed.set(key, new RowPlace(t.order, 1, arrival++));
		}
		for (a in mirror.sessionList()) {
			var key = WorkbenchRowKey.foreign(WorkbenchRowKind.Agent, id, a.id);
			built.sessions.set(key, a);
			var siblings = WorkspaceProtocol.isRoot(a.group) ? top : kids.get(WorkbenchRowKey.foreign(WorkbenchRowKind.Group, id, a.group));
			(siblings == null ? top : siblings).push(key);
			placed.set(key, new RowPlace(a.order, 2, arrival++));
		}
		var compare = function(a:String, b:String) return RowPlace.compare(placed.get(a), placed.get(b), a, b);
		top.sort(compare);
		for (items in kids)
			items.sort(compare);
		return built;
	}

	/** Whether walking up from `group`'s parent reaches `group` again or never ends (a group can name itself or a descendant as its parent). */
	static function inCycle(group:WorkspaceGroup, byId:Map<String, WorkspaceGroup>, limit:Int):Bool {
		var cursor = group.parent, steps = 0;
		while (cursor != null) {
			if (cursor == group.id || ++steps > limit)
				return true;
			var up = byId.get(cursor);
			if (up == null)
				return false;
			cursor = up.parent;
		}
		return false;
	}

	function projectGroups(catalog:TerminalCatalog, agentCatalog:Null<workspace.service.WorkspaceAgentProtocol.AgentCatalog>, draft:Null<WorkspaceGroup>):Void {
		var ordered = catalog.groups.copy();
        if (draft != null && !Lambda.exists(ordered, function(g) return g.id == draft.id)) ordered.push(draft);
		for (g in ordered) {
			groups.set(g.id, g);
			children.set(WorkbenchRowKey.group(g.id), []);
			places.set(WorkbenchRowKey.group(g.id), new RowPlace(WorkspaceProtocol.order(g.order), 0, 0));
		}
		for (g in ordered) {
			var siblings = g.parent == null ? groupRoots : children.get(WorkbenchRowKey.group(g.parent));
			if (siblings != null)
				siblings.push(WorkbenchRowKey.group(g.id));
		}
		var arrival = 0;
		for (t in catalog.terminals) {
			terminals.set(t.id, t);
			var siblings = itemsOf(t.group);
			if (siblings != null) {
				siblings.push(WorkbenchRowKey.terminal(t.id));
				places.set(WorkbenchRowKey.terminal(t.id), new RowPlace(t.order, 1, arrival++));
			}
		}
		if (agentCatalog != null)
			for (a in agentCatalog.records) {
				agents.set(a.id, a);
				var siblings = itemsOf(a.group);
				if (siblings != null) {
					siblings.push(WorkbenchRowKey.agent(a.id));
					places.set(WorkbenchRowKey.agent(a.id), new RowPlace(a.order, 2, arrival++));
				}
			}
		// Placed rows by position (a group is always placed), then those not yet placed in the order they arrived.
		var compare = function(a:String, b:String) return RowPlace.compare(places.get(a), places.get(b), a, b);
		groupRoots.sort(compare);
		for (items in children) items.sort(compare);
	}

	/** The group a row sits in, as the service names it (the workspace root for a top-level group or a root item); null for other rows. */
	public function groupOfRow(key:String):Null<String> {
		var row = WorkbenchRowKey.parse(key);
		if (row == null) return null;
		return switch row.kind {
			case WorkbenchRowKind.Group: var group = groups.get(row.id); group == null ? null : group.parent == null ? WorkspaceProtocol.ROOT_GROUP : group.parent;
			case WorkbenchRowKind.Terminal: var terminal = terminals.get(row.id); terminal == null ? null : terminal.group;
			case WorkbenchRowKind.Agent: var agent = agents.get(row.id); agent == null ? null : agent.group;
		};
	}

	/** A row's stored position among its siblings; null for a session or terminal not yet placed, and for other rows. */
	public function orderOfRow(key:String):Null<Int> {
		var place = places.get(key);
		return place == null ? null : place.order;
	}

	/** The rows directly in `group` (the workspace root for ROOT_GROUP), in the order the tree shows them. */
	public function siblings(group:String):Array<String> {
		var items = itemsOf(group);
		return items == null ? [] : items.copy();
	}

	/** Moves the insertion line to the upper (or lower) edge of `key`, or removes it; the rows rebuild only when it changes. */
	public function setInsertion(key:Null<String>, after:Bool = false):Void {
		if (key == insertion && (key == null || after == insertionAfter)) return;
		insertion = key;
		insertionAfter = key != null && after;
		version++;
	}

	/** The rows were laid out again, so where they sit must be measured again. */
	public function layoutChanged(root:RenderNode):Void {
		tree = root;
		layout++;
	}

	/** How many rows are probed; rows whose nodes left the tree are forgotten at the next lookup. */
	public function probeCount():Int
		return Lambda.count(nodes);

	/**
		The row under global vertical position `y` and that row's centre; the newest build wins where a recycled row left a stale node.
		Row centres are measured once per layout and searched, not measured on every pointer move.
	**/
	public function rowAt(y:Float):Null<{key:String, centre:Float}> {
		if (indexed != layout || moved()) reindex();
		var half = WorkbenchSessionLabel.ROW_HEIGHT / 2, low = 0, high = index.length;
		while (low < high) {
			var middle = (low + high) >> 1;
			if (index[middle].centre < y - half) low = middle + 1; else high = middle;
		}
		var found:Null<RowSpot> = null;
		while (low < index.length && index[low].centre <= y + half) {
			var spot = index[low++];
			if (found == null || spot.serial > found.serial) found = spot;
		}
		return found == null ? null : {key: found.key, centre: found.centre};
	}

	/** Whether the first or last indexed row is no longer where it was measured, as when the tree scrolled without a new layout. */
	function moved():Bool {
		if (index.length == 0) return false;
		for (spot in [index[0], index[index.length - 1]]) {
			var probe = nodes.get(spot.key);
			var centre = probe == null ? null : probe.centre();
			if (centre == null || centre != spot.centre) return true;
		}
		return false;
	}

	/** Measures every probed row once, forgetting the ones whose nodes are gone, and sorts them top to bottom. */
	function reindex():Void {
		var spots:Array<RowSpot> = [], gone:Array<String> = [];
		for (key => probe in nodes) {
			// A row built but not yet laid out has no centre yet; only one that has left the tree is forgotten.
			if (probe.detachedFrom(tree)) { gone.push(key); continue; }
			var centre = probe.centre();
			if (centre != null) spots.push(new RowSpot(key, centre, probe.serial));
		}
		for (key in gone) nodes.remove(key);
		spots.sort(function(a, b) return a.centre < b.centre ? -1 : a.centre > b.centre ? 1 : 0);
		index = spots; indexed = layout;
	}

	/** The centre of `key`'s row as last laid out, or null when it is not on screen. */
	public function centreOf(key:String):Null<Float> {
		var probe = nodes.get(key);
		return probe == null ? null : probe.centre();
	}

	/** The rows a session or terminal in `group` joins: the group's, or the workspace's own (`groupRoots`) at its root. */
	function itemsOf(group:String):Null<Array<String>>
		return WorkspaceProtocol.isRoot(group) ? groupRoots : children.get(WorkbenchRowKey.group(group));

	public function rootCount():Int
		return roots.length;

	public function rootRange(start:Int, count:Int):Array<TreeRootMetadata>
		return [
			for (index in start...Std.int(Math.min(roots.length, start + count)))
				new TreeRootMetadata(roots[index], initiallyExpanded(roots[index]))
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
		return key == openRow || WorkbenchRowKey.isKind(key, WorkbenchRowKind.Group) && groupRoots.indexOf(key) >= 0;

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
		if (WorkbenchRowKey.isForeign(key)) return foreignItem(key);
		if (WorkbenchRowKey.isMachineRow(key)) return machineItem(key);
		var row = WorkbenchRowKey.parse(key);
		if (row == null) return new Text("");
		var editing:Null<View> = null;
		if (row.kind == WorkbenchRowKind.Group && groupEditor != null) editing = groupEditor(row.id);
		if (row.kind == WorkbenchRowKind.Agent && agentEditor != null) editing = agentEditor(row.id);
		if (editing != null) return editing;
		var label = rowLabel(row);
		var probed = new WorkbenchRowProbe(label, function(node) { nodes.set(key, new ProbedRow(key, node, ++probes)); layout++; });
		return key == insertion ? new WorkbenchInsertionLine(probed, insertionAfter) : probed;
	}

	function rowLabel(row:WorkbenchRowKey):View {
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

	/** A row of a workspace this window is not attached to: its name and state as the catalog says, nothing to edit. */
	function foreignItem(key:String):View {
		var row = WorkbenchRowKey.parseForeign(key);
		if (row == null) return new Text("");
		switch row.kind {
			case WorkbenchRowKind.Group:
				var group = foreignGroups.get(key);
				if (group != null) {
					var owner = workspaces.get(group.workspace);
					return new WorkbenchGroupLabel(group.group.name, group.group.cwd, null, owner == null ? null : owner.name);
				}
			case WorkbenchRowKind.Agent:
				var session = foreignSessions.get(key);
				if (session != null) return new WorkbenchSessionLabel(session.name, session.state, agentStateLabel(session.state));
			case WorkbenchRowKind.Terminal:
				var terminal = foreignTerminals.get(key);
				if (terminal != null) return new WorkbenchSessionLabel(terminal.name, terminal.state, TerminalStateLabels.display(terminal.state));
		}
		return new Text("");
	}

	function machineItem(key:String):View {
		var view = machine;
		if (view == null) return new Text("");
		if (key == WorkbenchRowKey.NEW_WORKSPACE) return WorkbenchMachineLabel.newWorkspace();
		var id = WorkbenchRowKey.workspaceId(key);
		if (id != null) {
			var entry = workspaces.get(id);
			if (entry == null) return new Text("");
			var watched = view.watched, state = watched == null ? null : watched.get(id);
			return WorkbenchMachineLabel.workspace(entry, key == openRow, state);
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

	/** The position after every placed row in `parent` (null for the workspace root): one step past the last, or 0 in a group with none. */
	public function nextOrder(parent:Null<String>):Int {
		var last:Null<Int> = null, into = parent == null ? WorkspaceProtocol.ROOT_GROUP : parent;
		for (key => place in places) {
			var order = place.order;
			if (order != null && groupOfRow(key) == into && (last == null || order > last)) last = order;
		}
		return last == null ? 0 : Std.int(Math.min(WorkspaceProtocol.MAX_ORDER, last + WorkbenchOrder.STEP));
	}
}

/** Where a row sorts among its siblings: by position when it has one, then by kind, then by arrival. */
private class RowPlace {
	public final order:Null<Int>;
	final kind:Int;
	final arrival:Int;

	public function new(order:Null<Int>, kind:Int, arrival:Int) {
		this.order = order; this.kind = kind; this.arrival = arrival;
	}

	/** Placed rows first, by position; ties by kind (groups, terminals, sessions), then groups by id and the rest as they arrived. */
	public static function compare(a:RowPlace, b:RowPlace, keyA:String, keyB:String):Int {
		var left = a.order, right = b.order;
		if (left != null && right == null) return -1;
		if (left == null && right != null) return 1;
		if (left != null && right != null && left != right) return left - right;
		if (a.kind != b.kind) return a.kind - b.kind;
		return a.kind == 0 ? Reflect.compare(keyA, keyB) : a.arrival - b.arrival;
	}
}

/** Where a row's centre was measured, and which build of the row that was. */
private class RowSpot {
	public final key:String;
	public final centre:Float;
	public final serial:Int;

	public function new(key:String, centre:Float, serial:Int) {
		this.key = key; this.centre = centre; this.serial = serial;
	}
}

/** A row's label node and when it was built. */
private class ProbedRow {
	final key:String;
	final node:RenderNode;
	public final serial:Int;
	var inTree = false;

	public function new(key:String, node:RenderNode, serial:Int) {
		this.key = key; this.node = node; this.serial = serial;
	}

	/** Whether the node was once under `root` and no longer is. */
	public function detachedFrom(root:Null<RenderNode>):Bool {
		if (root == null) return false;
		var up:Null<RenderNode> = node;
		while (up != null && up != root) up = up.parent;
		if (up != null) { inTree = true; return false; }
		return inTree;
	}

	/** The vertical centre of the tree's row around the label (the tree labels it with the key), or null before the first layout. */
	public function centre():Null<Float> {
		var row:Null<RenderNode> = node;
		while (row != null && (row.semantics == null || row.semantics.label != key)) row = row.parent;
		var measured = row == null ? node : row;
		try {
			var bounds = measured.globalBounds();
			return bounds.y + bounds.height / 2;
		} catch (_:Dynamic) return null;
	}
}

/** One workspace's foreign rows built from `mirror` at `revision`: shared by every update until the catalog changes. */
private class ForeignProjection {
	public final mirror:WorkspaceCatalogMirror;
	public final revision:Int;
	public final top:Array<String> = [];
	public final kids:Map<String, Array<String>> = [];
	public final groups:Map<String, ForeignGroup> = [];
	public final terminals:Map<String, CatalogTerminal> = [];
	public final sessions:Map<String, CatalogSession> = [];
	public final places:Map<String, RowPlace> = [];

	public function new(mirror:WorkspaceCatalogMirror) {
		this.mirror = mirror; revision = mirror.revision;
	}
}

/** A group of another workspace, with the workspace's id. */
private class ForeignGroup {
	public final workspace:String;
	public final group:WorkspaceGroup;

	public function new(workspace:String, group:WorkspaceGroup) {
		this.workspace = workspace; this.group = group;
	}
}
