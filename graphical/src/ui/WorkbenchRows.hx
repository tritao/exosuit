package ui;

import workspace.client.WorkspaceCatalogMirror;
import workspace.service.GroupFolders;
import workspace.service.WorkspaceAgentProtocol.AgentCatalog;
import workspace.service.WorkspaceAgentProtocol.AgentRecord;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;
import workspace.service.WorkspaceTerminalProtocol.TerminalCatalog;
import workspace.service.WorkspaceTerminalProtocol.TerminalRecord;

/** Where one workspace's rows come from: its link's lists once read, else a copy of its catalog. */
typedef WorkbenchRowSource = {
	/** The link's terminal list (groups and terminals) and session list, once read. */
	var terminals:Null<TerminalCatalog>;
	var agents:Null<AgentCatalog>;
	/** The catalog copy the link watches, else the snapshot the workspace's service left on disk. */
	var snapshot:Null<WorkspaceCatalogMirror>;
	/** Changes whenever any of them does; a workspace's rows are built again only then. */
	var revision:Int;
}

/**
	One workspace's groups, sessions and terminals as rows, laid out by one rule (`layOut`) whatever they come from: the
	lists its link has read, whose records the row actions use, or until then a copy of its catalog, which draws the
	same rows under the same keys. A source that has not changed keeps its rows (`sameSource`), so a busy session in one
	workspace rebuilds that workspace's rows alone.
**/
class WorkbenchRows {
	public final workspace:String;
	public final groups:Map<String, WorkspaceGroup> = [];
	/** The terminal and session records by id, from the link's lists; empty for rows drawn from a catalog copy. */
	public final terminals:Map<String, TerminalRecord> = [];
	public final agents:Map<String, AgentRecord> = [];
	/** Whether the rows come from the link's lists, so the records above are there to act on. */
	public final live:Bool;
	/** The service's root folder, as its terminal list names it; null for rows drawn from a catalog copy. */
	public final root:Null<String>;
	/** The rows directly in the workspace: its top-level groups, then the sessions and terminals in no group. */
	public final top:Array<String> = [];
	/** Each group row's rows. */
	public final kids:Map<String, Array<String>> = [];
	final places:Map<String, RowPlace> = [];
	/** The group each row sits in as the tree shows it (ROOT_GROUP at the workspace root). */
	final placedIn:Map<String, String> = [];
	/** Each session's and terminal's name and state, by row key. */
	final labels:Map<String, RowLabel> = [];
	final source:WorkbenchRowSource;
	final snapshotRevision:Int;
	final draft:Null<WorkspaceGroup>;

	function new(workspace:String, source:WorkbenchRowSource, draft:Null<WorkspaceGroup>, live:Bool, root:Null<String>) {
		this.workspace = workspace; this.source = source; this.draft = draft; this.live = live; this.root = root;
		snapshotRevision = source.snapshot == null ? -1 : source.snapshot.revision;
	}

	/**
		Lays out `source`'s rows: from its lists once the terminal list is read and the session list too (or there is no
		catalog copy to wait with), else from its catalog copy; null when it has neither. `draft` is a group being named
		in this workspace, shown before the service has it.
	**/
	public static function build(workspace:String, source:WorkbenchRowSource, draft:Null<WorkspaceGroup>):Null<WorkbenchRows> {
		var lists = source.terminals, sessions = source.agents, snapshot = source.snapshot;
		var items:Array<RowItem> = [];
		var built:WorkbenchRows;
		var ordered:Array<WorkspaceGroup>;
		if (lists != null && (sessions != null || snapshot == null)) {
			built = new WorkbenchRows(workspace, source, draft, true, lists.workspaceRoot);
			ordered = lists.groups.copy();
			for (t in lists.terminals) {
				built.terminals.set(t.id, t);
				built.labels.set(WorkbenchRowKey.terminal(workspace, t.id), {name: t.name, state: t.state, text: TerminalStateLabels.display(t.state, t.agentProvider)});
				items.push({kind: WorkbenchRowKind.Terminal, id: t.id, group: t.group, order: t.order});
			}
			if (sessions != null)
				for (a in sessions.records) {
					built.agents.set(a.id, a);
					built.labels.set(WorkbenchRowKey.agent(workspace, a.id), {name: a.name, state: a.state, text: agentStateLabel(a.state, a.provider)});
					items.push({kind: WorkbenchRowKind.Agent, id: a.id, group: a.group, order: a.order});
				}
		} else if (snapshot != null) {
			built = new WorkbenchRows(workspace, source, draft, false, null);
			ordered = snapshot.groupList();
			for (t in snapshot.terminalList()) {
				built.labels.set(WorkbenchRowKey.terminal(workspace, t.id), {name: t.name, state: t.state, text: TerminalStateLabels.display(t.state, t.agentProvider)});
				items.push({kind: WorkbenchRowKind.Terminal, id: t.id, group: t.group, order: t.order});
			}
			for (a in snapshot.sessionList()) {
				built.labels.set(WorkbenchRowKey.agent(workspace, a.id), {name: a.name, state: a.state, text: agentStateLabel(a.state, a.provider)});
				items.push({kind: WorkbenchRowKind.Agent, id: a.id, group: a.group, order: a.order});
			}
		} else return null;
		if (draft != null && !Lambda.exists(ordered, function(g) return g.id == draft.id)) ordered.push(draft);
		for (g in ordered) built.groups.set(g.id, g);
		built.layOut(ordered, items);
		return built;
	}

	/** Whether these rows were built from `source` as it is now, with the same group being named. */
	public function sameSource(next:WorkbenchRowSource, nextDraft:Null<WorkspaceGroup>):Bool
		return next.revision == source.revision && next.terminals == source.terminals && next.agents == source.agents
			&& next.snapshot == source.snapshot && (next.snapshot == null || next.snapshot.revision == snapshotRevision) && nextDraft == draft;

	/** Claude and Pi continue the same conversation when a prompt arrives; a Codex session is only disconnected. */
	public static function agentStateLabel(state:String, ?provider:String):String {
		return switch (state) {
			case "reconnecting": "Reconnecting…";
			case "reconnect-failed": "Session unavailable";
			// Stopped with the service; a message (or Resume) continues the same conversation.
			case "disconnected": provider == "claude" || provider == "pi" ? "Resumable" : "Disconnected";
			default: state;
		};
	}

	/**
		The one rule that lays a workspace's rows out: groups under their parent, sessions and terminals under their group.
		A row whose group is unknown, and a group that is its own ancestor or hangs under one, sits at the workspace root
		(`top`), so every item shows once and the tree is finite. Placed rows sort by position, then by kind and arrival.
	**/
	function layOut(groupList:Array<WorkspaceGroup>, items:Array<RowItem>):Void {
		var byId:Map<String, WorkspaceGroup> = [];
		var lists:Array<Array<String>> = [top];
		for (g in groupList) {
			byId.set(g.id, g);
			var rows:Array<String> = [];
			kids.set(WorkbenchRowKey.group(workspace, g.id), rows);
			lists.push(rows);
			places.set(WorkbenchRowKey.group(workspace, g.id), new RowPlace(WorkspaceProtocol.order(g.order), 0, 0));
		}
		var place = function(row:String, group:Null<String>):Void {
			var siblings = group == null ? null : kids.get(WorkbenchRowKey.group(workspace, group));
			if (siblings == null) top.push(row); else siblings.push(row);
			placedIn.set(row, siblings == null || group == null ? WorkspaceProtocol.ROOT_GROUP : group);
		};
		for (g in groupList)
			place(WorkbenchRowKey.group(workspace, g.id), inCycle(g, byId, groupList.length) ? null : g.parent);
		var arrival = 0;
		for (item in items) {
			var row = new WorkbenchRowKey(item.kind, workspace, item.id).toString();
			place(row, WorkspaceProtocol.isRoot(item.group) ? null : item.group);
			places.set(row, new RowPlace(item.order, item.kind == WorkbenchRowKind.Terminal ? 1 : 2, arrival++));
		}
		var compare = function(a:String, b:String) return RowPlace.compare(places.get(a), places.get(b), a, b);
		for (rows in lists)
			rows.sort(compare);
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

	/** The rows under group row `key`, or null for a row with none. */
	public function rowsUnder(key:String):Null<Array<String>>
		return kids.get(key);

	/** A session's or terminal's name and state, or null for a row this workspace does not have. */
	public function label(key:String):Null<RowLabel>
		return labels.get(key);

	/** The group a session or terminal of this workspace is in, as its source says; null for one it does not have. */
	public function itemGroup(kind:WorkbenchRowKind, id:String):Null<String> {
		var key = new WorkbenchRowKey(kind, workspace, id).toString(), at = placedIn.get(key);
		if (at == null) return null;
		var record:Null<String> = switch kind {
			case WorkbenchRowKind.Terminal: var terminal = terminals.get(id); terminal == null ? null : terminal.group;
			case WorkbenchRowKind.Agent: var agent = agents.get(id); agent == null ? null : agent.group;
			case WorkbenchRowKind.Group: null;
		};
		return record != null ? record : at;
	}

	/** The group a row sits in as the tree shows it (the workspace root for a top-level group or a root item); null for other rows. */
	public function groupOfRow(key:String):Null<String>
		return placedIn.get(key);

	/** A row's stored position among its siblings; null for a session or terminal not yet placed, and for other rows. */
	public function orderOfRow(key:String):Null<Int> {
		var place = places.get(key);
		return place == null ? null : place.order;
	}

	/** The rows directly in `group` (the workspace root for ROOT_GROUP), in the order the tree shows them. */
	public function siblings(group:String):Array<String> {
		var items = WorkspaceProtocol.isRoot(group) ? top : kids.get(WorkbenchRowKey.group(workspace, group));
		return items == null ? [] : items.copy();
	}

	/** The position after every placed row in `parent` (null for the workspace root): one step past the last, or 0 in a group with none. */
	public function nextOrder(parent:Null<String>):Int {
		var last:Null<Int> = null, into = parent == null ? WorkspaceProtocol.ROOT_GROUP : parent;
		for (key => place in places) {
			var order = place.order;
			if (order != null && placedIn.get(key) == into && (last == null || order > last)) last = order;
		}
		return last == null ? 0 : Std.int(Math.min(WorkspaceProtocol.MAX_ORDER, last + WorkbenchOrder.STEP));
	}

	/** The folder `group` works in: its own or inherited, else `first`, the workspace's first folder. */
	public function directory(group:WorkspaceGroup, first:Null<String>):Null<String> {
		var folder = GroupFolders.nearest(groups, group);
		return folder == null ? first : folder;
	}
}

/** What a session or terminal row shows: its name, its state, and the state as words. */
typedef RowLabel = {name:String, state:String, text:String};

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

/** What the layout rule needs of a session or terminal: where it goes and where it sorts. */
private typedef RowItem = {kind:WorkbenchRowKind, id:String, group:String, order:Null<Int>};
