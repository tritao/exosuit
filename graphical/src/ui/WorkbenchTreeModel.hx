package ui;

import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.widgets.collections.TreeViewModel;
import haxeon.ui.widgets.collections.TreeRootMetadata;
import haxeon.ui.widgets.text.Text;
import exohost.MachineCatalog.MachineWorkspace;
import workspace.service.WorkspaceProtocol;
import ui.WorkbenchMachineView.WorkbenchWorkspaceState;
import ui.WorkbenchRows.WorkbenchRowSource;

/**
	Projection only: grouping/status belong to the service, expansion/selection to TreeView.

	The tree is one tree (docs/architecture/0006-workspaces-without-folders.md): the machine's workspaces, status lines
	and, where the window may make workspaces, New Workspace…. The machine is this one's exohost on the desktop and a paired
	machine's directory on a device (WorkbenchMachine). Every workspace's groups, sessions and terminals nest under its
	row by one rule (WorkbenchRows), keyed by workspace and item: the open workspace's always, another's while its row is
	expanded, from its link's lists or a copy of its catalog. An expanded workspace with nothing to show says so in a
	child row.

	Observable: `update` and `setInsertion` write `version`, and every tree method reads it, so the TreeView's index
	and its rows follow each projection. The containers are filled in place and stand behind `version`; the row index
	below is a layout cache that row builds write, so it is not tracked.
**/
class WorkbenchTreeModel implements TreeViewModel implements Observable {
	/** The machine's workspaces by id. */
	@:unobservable public final workspaces:Map<String, MachineWorkspace> = [];
	/** The workspace this window shows, or null when it shows none. */
	public var openWorkspace(default, null):Null<String>;
	/** The open workspace's row; null without one. */
	public var openRow(default, null):Null<String>;
	public var machine(default, null):Null<WorkbenchMachineView>;
	/** The rows shown now, per workspace id: the open workspace's, and each expanded one's that has a source. */
	@:unobservable final shown:Map<String, WorkbenchRows> = [];
	/** Each workspace's rows as last built, reused while their source has not changed. */
	@:unobservable final built:Map<String, WorkbenchRows> = [];
	/** Rows built so far: tests and measurements count them. */
	public var projectionBuilds(default, null):Int = 0;
	/**
		The workspace rows (`w:` keys) the tree shows expanded; only those (and the open one) are projected. Null projects
		every workspace. Set before `update`: the tree is not asked from inside it.
	**/
	public var expandedRows:Null<Map<String, Bool>>;
	/** Why this window could not connect to the open workspace, or null; its row says so instead of "Loading…". */
	public var openFailure:Null<String>;
	/**
		Whether each workspace row starts expanded: a row first shown as the open workspace's does (the window starts
		there, or the workspace was just made); every other row starts collapsed and stays as it was shown when a click
		opens it, since only the chevron expands (Workbench design Q1).
	**/
	@:unobservable final startsExpanded:Map<String, Bool> = [];

	/** The rows under each workspace row (its top-level rows, or a note). */
	@:unobservable final children:Map<String, Array<String>> = [];
	@:unobservable final roots:Array<String> = [];
	/** The latest node each row built, to find the row under the pointer while a drag is over the tree. */
	@:unobservable final nodes:Map<String, ProbedRow> = [];
	@:unobservable var probes:Int = 0;
	/** Bumped when rows are built or laid out again; the row index below is valid for one value of it. */
	@:unobservable var layout:Int = 0;
	@:unobservable var indexed:Int = -1;
	/** The tree the rows are laid out in, as last reported; a row that was in it and no longer is has been replaced. */
	@:unobservable var tree:Null<RenderNode>;
	@:unobservable var index:Array<RowSpot> = [];
	var version:Int = 0;
	/** The row an insertion line is drawn at, and whether on its lower edge; null when no drop would land between rows. */
	public var insertion(default, null):Null<String>;
	public var insertionAfter(default, null):Bool = false;
	/** The inline name editor of a group or session row, by row key, or null for a row that shows its label. */
	public var groupEditor:Null<String->Null<View>>;
	public var agentEditor:Null<String->Null<View>>;

	public function new() {}

	/**
		Lays out `view`'s workspaces with each workspace's rows from `sources`, by workspace id. `draft` is a group being
		named in workspace `draftWorkspace`.
	**/
	public function update(view:WorkbenchMachineView, sources:Map<String, WorkbenchRowSource>, ?draft:WorkspaceGroup, ?draftWorkspace:String):Void {
		children.clear();
		roots.resize(0);
		nodes.clear();
		shown.clear();
		workspaces.clear();
		layout++;
		version++;
		machine = view;
		openWorkspace = view.openWorkspace;
		openRow = openWorkspace == null ? null : WorkbenchRowKey.machineWorkspace(openWorkspace);
		projectMachine(view, sources, draft, draftWorkspace);
		for (id in [for (key in built.keys()) key])
			if (!shown.exists(id))
				built.remove(id);
	}

	/** The machine's workspaces and status lines, and under each shown workspace its rows or a note. */
	function projectMachine(view:WorkbenchMachineView, sources:Map<String, WorkbenchRowSource>, draft:Null<WorkspaceGroup>, draftWorkspace:Null<String>):Void {
		var state = view.machine;
		if (state != null)
			for (entry in state.workspaces) {
				var key = WorkbenchRowKey.machineWorkspace(entry.id);
				workspaces.set(entry.id, entry);
				roots.push(key);
				children.set(key, []);
				if (!startsExpanded.exists(key)) startsExpanded.set(key, key == openRow);
			}
		if (state != null && state.workspaces.length == 0)
			roots.push(WorkbenchRowKey.status("empty"));
		else if (state == null && view.error == null)
			roots.push(WorkbenchRowKey.status("loading"));
		if (view.error != null)
			roots.push(WorkbenchRowKey.status("error"));
		if (view.manages) { roots.push(WorkbenchRowKey.NEW_WORKSPACE); roots.push(WorkbenchRowKey.FOLDER_WORKSPACE); }
		if (state == null) return;
		var expanded = expandedRows;
		for (entry in state.workspaces) {
			var key = WorkbenchRowKey.machineWorkspace(entry.id);
			if (key != openRow && expanded != null && !expanded.exists(key)) continue;
			var rows = project(entry.id, sources, draft, draftWorkspace);
			if (rows != null && rows.top.length > 0) {
				children.set(key, rows.top);
				continue;
			}
			var watched = view.watched, status = watched == null ? null : watched.get(entry.id);
			children.get(key).push(WorkbenchRowKey.note(noteKind(key, rows != null, status), entry.id));
		}
	}

	/**
		Why an expanded workspace row has no rows under it: nothing in it yet, still loading, its service not running, or
		the reason this window could not connect to it. Its menu is the workspace's, so a session can be made from it.
	**/
	function noteKind(key:String, hasRows:Bool, status:Null<WorkbenchWorkspaceState>):String {
		if (hasRows) return WorkbenchRowKey.NOTE_EMPTY;
		if (key == openRow && openFailure != null) return WorkbenchRowKey.NOTE_FAILED;
		if (status != null && !status.running && !status.starting) return WorkbenchRowKey.NOTE_IDLE;
		return WorkbenchRowKey.NOTE_LOADING;
	}

	/** Workspace `id`'s rows from its source, rebuilt only when that changed; null without a source. */
	function project(id:String, sources:Map<String, WorkbenchRowSource>, draft:Null<WorkspaceGroup>, draftWorkspace:Null<String>):Null<WorkbenchRows> {
		var source = sources.get(id);
		if (source == null) return null;
		var named = draftWorkspace == id ? draft : null;
		var rows = built.get(id);
		if (rows == null || !rows.sameSource(source, named)) {
			rows = WorkbenchRows.build(id, source, named);
			if (rows == null) return null;
			built.set(id, rows);
			projectionBuilds++;
		}
		shown.set(id, rows);
		return rows;
	}

	/** The rows of workspace `id` the tree shows now, or null. */
	public function rows(id:Null<String>):Null<WorkbenchRows>
		return id == null ? null : shown.get(id);

	/** The open workspace's rows, or null. */
	public function open():Null<WorkbenchRows>
		return rows(openWorkspace);

	/**
		The workspace a row belongs to: a workspace row's own, a note's, a group's, session's or terminal's. Null for the
		machine's status rows and New Workspace….
	**/
	public function workspaceOfRow(key:Null<String>):Null<String> {
		var id = WorkbenchRowKey.workspaceId(key);
		if (id != null) return id;
		var noted = WorkbenchRowKey.noteWorkspace(key);
		if (noted != null) return noted;
		var row = WorkbenchRowKey.parse(key);
		return row == null ? null : row.workspace;
	}

	/** The group a row sits in as the tree shows it (the workspace root for a top-level group or a root item); null for other rows. */
	public function groupOfRow(key:String):Null<String> {
		var rows = rowsOf(key);
		return rows == null ? null : rows.groupOfRow(key);
	}

	/** A row's stored position among its siblings; null for a session or terminal not yet placed, and for other rows. */
	public function orderOfRow(key:String):Null<Int> {
		var rows = rowsOf(key);
		return rows == null ? null : rows.orderOfRow(key);
	}

	/** The rows of the workspace a group, session or terminal row belongs to. */
	public function rowsOf(key:Null<String>):Null<WorkbenchRows> {
		var row = WorkbenchRowKey.parse(key);
		return row == null ? null : rows(row.workspace);
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

	/** Reads `version`, so a build that asks the tree's shape is invalidated by the next projection. */
	function observe():Void {
		var current = version;
	}

	public function rootCount():Int {
		observe();
		return roots.length;
	}

	public function rootRange(start:Int, count:Int):Array<TreeRootMetadata> {
		observe();
		return [
			for (index in start...Std.int(Math.min(roots.length, start + count)))
				new TreeRootMetadata(roots[index], initiallyExpanded(roots[index]))
		];
	}

	public function rootKeyAt(index:Int):String {
		observe();
		return roots[index];
	}

	function itemsUnder(key:String):Null<Array<String>> {
		observe();
		var items = children.get(key);
		if (items != null) return items;
		var rows = rowsOf(key);
		return rows == null ? null : rows.rowsUnder(key);
	}

	public function childCount(key:String):Int {
		var items = itemsUnder(key);
		return items == null ? 0 : items.length;
	}

	public function childKeyAt(key:String, index:Int):String {
		var items = itemsUnder(key);
		if (items == null)
			throw "Unknown tree branch";
		return items[index];
	}

	/** A workspace row first shown as the open one starts expanded, and so does every workspace's top-level group. */
	public function initiallyExpanded(key:String):Bool {
		observe();
		if (startsExpanded.get(key) == true) return true;
		var row = WorkbenchRowKey.parse(key), rows = rowsOf(key);
		return row != null && row.kind == WorkbenchRowKind.Group && rows != null && rows.top.indexOf(key) >= 0;
	}

	/** True for a row the tree draws as expandable even without children: every workspace, open or not. */
	public function expandable(key:String):Bool
		return childCount(key) > 0 || WorkbenchRowKey.workspaceId(key) != null;

	public function estimatedExtent():Float
		return WorkbenchSessionLabel.ROW_HEIGHT;

	public function extentIsUniform():Bool
		return true;

	public function extentAt(key:String):Float
		return WorkbenchSessionLabel.ROW_HEIGHT;

	/** Moves with every projection and insertion line: a cache key for what is worked out from the rows. */
	public function revision():Int
		return version;

	public function buildItem(key:String):View {
		observe();
		if (WorkbenchRowKey.isMachineRow(key)) return machineItem(key);
		var row = WorkbenchRowKey.parse(key), rows = rowsOf(key);
		if (row == null || rows == null) return new Text("");
		var editing:Null<View> = null;
		if (row.kind == WorkbenchRowKind.Group && groupEditor != null) editing = groupEditor(key);
		if (row.kind == WorkbenchRowKind.Agent && agentEditor != null) editing = agentEditor(key);
		if (editing != null) return editing;
		var label = rowLabel(key, row, rows);
		var probed = new WorkbenchRowProbe(label, function(node) { nodes.set(key, new ProbedRow(key, node, ++probes)); layout++; });
		return key == insertion ? new WorkbenchInsertionLine(probed, insertionAfter) : probed;
	}

	/** A group, session or terminal row of any workspace: its name and state as its source says. */
	function rowLabel(key:String, row:WorkbenchRowKey, rows:WorkbenchRows):View {
		if (row.kind == WorkbenchRowKind.Group) {
			var group = rows.groups.get(row.id);
			if (group == null) return new Text("");
			var first = firstFolder(row.workspace), owner = workspaces.get(row.workspace);
			var folder = rows.directory(group, first);
			return new WorkbenchGroupLabel(group.name, folder, first, owner == null ? null : owner.name, anotherWindow(row.workspace, group.id));
		}
		var shown = rows.label(key);
		return shown == null ? new Text("") : new WorkbenchSessionLabel(shown.name, shown.state, shown.text);
	}

	/**
		Whether another editor window (not this one) has the workspace focused, or its group `group` when given
		(M19 Phase 8). Exohost lists every window's focus; this window's own is left out of the view.
	**/
	public function anotherWindow(workspaceId:Null<String>, ?group:String):Bool {
		var view = machine;
		if (view == null || view.windows == null || workspaceId == null) return false;
		return exohost.WindowFocus.WindowFocuses.elsewhere(view.windows, null, workspaceId, group).length > 0;
	}

	function machineItem(key:String):View {
		var view = machine;
		if (view == null) return new Text("");
		if (key == WorkbenchRowKey.NEW_WORKSPACE) return WorkbenchMachineLabel.newWorkspace();
		if (key == WorkbenchRowKey.FOLDER_WORKSPACE) return WorkbenchMachineLabel.fromFolder();
		var id = WorkbenchRowKey.workspaceId(key);
		if (id != null) {
			var entry = workspaces.get(id);
			if (entry == null) return new Text("");
			var watched = view.watched, state = watched == null ? null : watched.get(id);
			return WorkbenchMachineLabel.workspace(entry, key == openRow, state, anotherWindow(id, null));
		}
		var error = view.error, kind = WorkbenchRowKey.statusKind(key);
		if (kind == WorkbenchRowKey.NOTE_EMPTY) return WorkbenchMachineLabel.status("No sessions yet");
		if (kind == WorkbenchRowKey.NOTE_LOADING) return WorkbenchMachineLabel.status("Loading…");
		if (kind == WorkbenchRowKey.NOTE_IDLE) return WorkbenchMachineLabel.status("Not running · click to open");
		if (kind == WorkbenchRowKey.NOTE_FAILED) return WorkbenchMachineLabel.status("Could not connect: " + openFailure, true);
		return switch kind {
			case "empty": WorkbenchMachineLabel.status(view.manages ? "No workspaces yet. Make one to hold groups, sessions and terminals."
				: "No workspaces are shared with this device yet.");
			case "loading": WorkbenchMachineLabel.status("Looking for this machine's workspaces…");
			case "error": WorkbenchMachineLabel.status(error == null ? "" : error, true);
			default: new Text("");
		};
	}

	/** The folder `group` of workspace `id` works in: its own or inherited, else the workspace's first folder. */
	public function directory(id:String, group:WorkspaceGroup):Null<String> {
		var rows = rows(id);
		return rows == null ? firstFolder(id) : rows.directory(group, firstFolder(id));
	}

	/**
		Workspace `id`'s first folder, where its root and folderless groups work: its first attached folder, else its
		service's root as its lists name it, else its scratch folder. A service keeps the folder it started in, so a
		workspace started in its scratch folder still names that after a folder is attached.
	**/
	public function firstFolder(id:Null<String>):Null<String> {
		var entry = id == null ? null : workspaces.get(id), rows = rows(id);
		if (entry != null && entry.folders.length > 0) return entry.folders[0];
		if (rows != null && rows.root != null) return rows.root;
		return entry == null ? null : entry.scratch;
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
