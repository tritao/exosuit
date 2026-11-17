package ui;

import haxeon.ui.widgets.overlays.TooltipHoverGroup;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Insets;
import haxeon.ui.Rect;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.core.UiEvent;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.collections.TreeView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.overlays.MenuItem;
import haxeon.ui.widgets.text.Text;
import exohost.MachineCatalog.MachineWorkspace;
import ui.WorkbenchOrder;
import ui.WorkbenchRows.WorkbenchRowSource;
import workspace.client.WorkspaceWorkbenchClient;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalProtocol;

/**
	Groups and sessions own the sidebar; secondary actions live in contextual surfaces.

	Every row belongs to a workspace (WorkbenchRowKey) and acts through that workspace's client (`clientOf`): the
	window's own for the workspace it shows, else the link the window holds or makes for it (WorkbenchActions). Only
	what opens a tab of another workspace takes the window there first (`goThere`).
**/
class WorkbenchPanel implements View {
	/** The client of the workspace the window shows: the focused link's, which a switch replaces (ExosuitApp.focusLink). */
	var client(get, never):WorkspaceWorkbenchClient;
	final source:Void->WorkspaceWorkbenchClient;
	inline function get_client():WorkspaceWorkbenchClient return source();
	/** Opens a terminal of the given client's workspace in a tab here. */
	final open:(WorkspaceWorkbenchClient, TerminalRecord)->Bool;
	/** New Terminal in a workspace's group, in a tab here; the workspace's link has read its lists. */
	final createTerminal:(String, String)->Void;
	/** Opens a session of the workspace the window shows. */
	final openAgent:String->Void;
	/** A group's own action from its menu: "inherit", "remove", "parent", "directory" or "order". */
	final edit:(WorkspaceWorkbenchClient, WorkspaceGroup, String)->Void;
	final terminalActions:(WorkspaceWorkbenchClient, TerminalRecord)->Array<MenuItem>;
	final requestFrame:Void->Void;
	final showMenu:(Array<MenuItem>, UiEvent, Void->Bool)->Void;
	/** Attach existing Codex thread…: the workspace's client, the group and the folder it works in. */
	final attach:(WorkspaceWorkbenchClient, WorkspaceGroup, String)->Void;
	final closeAgentTab:(String, String)->Void;
	/** New Agent Session in the workspace the window shows. */
	final createProvider:(String, String)->Void;
	final canCreateAgent:Void->Bool;
	final tooltipDelay:Void->Float;
	public final model = new WorkbenchTreeModel();
	public final tree:TreeView;
	public var onError:Null<String->Void>;
	/** Makes the group the window's context (a click or Enter on its row); set by the app, which owns the context. */
	public var focusGroup:Null<String->Void>;
	/** Makes the open workspace's root the window's context (a click or Enter on its row). */
	public var focusRoot:Null<Void->Void>;
	/** Closes a catalog terminal and its views; selection actions use it. */
	public var closeTerminal:Null<(WorkspaceWorkbenchClient, TerminalRecord)->Void>;
	/** Asks which group (or the workspace root) a session moves to: its Move to Group…. */
	public var moveAgent:Null<(WorkspaceWorkbenchClient, WorkspaceAgentProtocol.AgentRecord)->Void>;
	/** What the rows do to workspaces; its machine's workspaces are the tree's top level. */
	public var actions:Null<WorkbenchActions>;
	/** The provider New Agent Session starts at once (the "Default agent provider" setting). */
	public var defaultProvider:Void->String = function() return "claude";
	/** New Agent Session With… › Change Folder…: picks a folder, then starts a session of the provider in the group. */
	public var chooseSessionFolder:Null<(String, String)->Void>;
	/** Why the window could not connect to the workspace it shows, or null; set by the app. */
	public var connectionFailure:Null<Void->Null<String>>;
	var lastReportedError:Null<String>;
	// Selection actions run one step at a time, in one workspace: the service drops a mutation while another is in flight.
	var batchWorkspace = "";
	var batchKeys:Array<String> = [];
	var batchTarget:Null<String>;
	var batchPlan:Array<PlaceStep> = [];
	// A drag in progress, seen from the panel's capture handlers: where the pointer is, and whether it left the press.
	var dragSource:Null<String>;
	var pressX = 0.0;
	var pressY = 0.0;
	var pointerY = Math.NaN;
	var dragMoved = false;
	var batchOwner = "";
	var batchTerminalError:Null<String>;
	var batchAgentError:Null<String>;
	var agentDraft:Null<AgentRecord>;
	var agentDraftWorkspace = "";
	var agentDraftOwner = "";
	var agentDraftName = "";
	var agentRenameNative = false;
	var agentPending = false;
	var agentEditor:Null<WorkbenchNameEditor>;
	var draft:Null<WorkspaceGroup>;
	var draftWorkspace = "";
	var draftName = "";
	var draftOwner = "";
	var creating = false;
	var pending = false;
	var pendingSince = 0.0;
	var draftError:Null<String>;
	var inlineEditor:Null<WorkbenchNameEditor>;
	var refreshModel = false;
	var pendingReveal:Null<String>;
	var pendingRevealUntil = 0.0;
	/** The row that entered a context: the tree's selection is kept per context, so the entered context's own selection must yield to it. */
	var pendingEnterKey:Null<String>;
	/**
		Until when the re-keyed tree may still come back with the old selection. A time, not a count of updates: the
		switch can take many frames (a group to its workspace's root, say), and the clicked row stays selected meanwhile.
	**/
	var pendingEnterUntil:Float = 0;
	var scrollTarget:Null<String>;
	var scrollPasses = 0;
	var pendingSessionSelection:Null<String>;
	// The machine rows' inputs at the last projection, kept to throttle catalog changes.
	final throttle = new CatalogThrottle();
	/** The workspace rows the tree has open, which are the ones whose rows the model projects. */
	final expandedWorkspaces:Map<String, Bool> = [];
	var expandRevision = 0;
	var observedOpenRow:Null<String>;

	public function new(source:Void->WorkspaceWorkbenchClient, open:(WorkspaceWorkbenchClient, TerminalRecord)->Bool, createTerminal:(String, String)->Void,
			edit:(WorkspaceWorkbenchClient, WorkspaceGroup, String)->Void, terminalActions:(WorkspaceWorkbenchClient, TerminalRecord)->Array<MenuItem>,
			requestFrame:Void->Void, openAgent:String->Void, showMenu:(Array<MenuItem>, UiEvent, Void->Bool)->Void,
			attach:(WorkspaceWorkbenchClient, WorkspaceGroup, String)->Void, closeAgentTab:(String, String)->Void, createProvider:(String, String)->Void,
			canCreateAgent:Void->Bool, ?tooltipDelay:Void->Float) {
		this.source = source; this.open = open; this.createTerminal = createTerminal; this.edit = edit;
		this.terminalActions = terminalActions; this.requestFrame = requestFrame;
		this.openAgent = openAgent; this.showMenu = showMenu; this.attach = attach; this.closeAgentTab = closeAgentTab;
		this.createProvider = createProvider;
		this.canCreateAgent = canCreateAgent;
		this.tooltipDelay = tooltipDelay == null ? function() return config.Settings.DEFAULT_TOOLTIP_DELAY : tooltipDelay;
		var style = new LayoutStyle(); style.width = LayoutAxis.stretch(); style.height = LayoutAxis.grow();
		tree = new TreeView("workbench-tree", model, style);
		tree.multiSelect = true;
		tree.canDragItem = canDragNode;
		tree.canDropItem = canDropNode;
		tree.onItemDrop = dropNode;
		tree.onSelectionChanged = function(key) {
			// The user chose another row (a key, a click): the entered row's wish to be selected and focused is over, or the
			// tree's next build would take the keyboard back to it (TreeView.focusItem holds for 2 s). The re-keyed tree's
			// restore of a context's old selection does not notify, so it still yields to the entered row.
			if (key != pendingEnterKey) { pendingEnterKey = null; tree.focusItem(null); }
			requestFrame();
		};
		tree.onExpandedChanged = function(key, expanded) {
			if (WorkbenchRowKey.workspaceId(key) != null) {
				if (expanded) expandedWorkspaces.set(key, true);
				else expandedWorkspaces.remove(key);
				expandRevision++;
			}
			requestFrame();
		};
		tree.onItemContextMenu = function(key, event) {
			event.preventDefault(); event.stopPropagation();
			rowMenu(key, event);
		};
		// Every workspace row can expand, by its chevron. One with a running service shows its groups, sessions and
		// terminals from its link; an idle one shows them from the snapshot its service left, and starts nothing.
		tree.hasChildrenHint = model.expandable;
		// Enter, Space or a double click do what a click does.
		tree.onActivate = function(key, _) return openRow(key);
		tree.onItemActivatedWithEvent = function(key, event) {
			// A click already ran New Workspace… (or Add Workspace from Folder…) on its first press.
			if (event.kind == haxeon.ui.core.UiEventKind.Click) return;
			if (key == WorkbenchRowKey.NEW_WORKSPACE) createWorkspace();
			else if (key == WorkbenchRowKey.FOLDER_WORKSPACE) createWorkspaceFromFolder();
		};
		model.groupEditor = function(key) return draft != null && key == WorkbenchRowKey.group(draftWorkspace, draft.id) ? inlineEditor : null;
		model.agentEditor = function(key) return agentDraft != null && key == WorkbenchRowKey.agent(agentDraftWorkspace, agentDraft.id) ? agentEditor : null;
		// A click opens what the row is (Workbench design Q1): a workspace in this window, a group as the window's
		// context, a session or terminal in its tab, going to its workspace first. Only the chevron expands.
		tree.onItemClicked = function(key, count) {
			if (agentDraft != null || draft != null) return;
			pendingEnterKey = null; // a later click is the user's choice; openRow below makes a new wish for its own row
			if (key == WorkbenchRowKey.NEW_WORKSPACE && count == 1) { createWorkspace(); return; }
			if (key == WorkbenchRowKey.FOLDER_WORKSPACE && count == 1) { createWorkspaceFromFolder(); return; }
			openRow(key);
		};
	}

	/**
		The client of workspace `id`'s link: the window's own for the workspace it shows, else the link the window holds
		for it, or null when it holds none. Asking makes no link; acting does (`inWorkspace`).
	**/
	function clientOf(id:Null<String>):Null<WorkspaceWorkbenchClient> {
		if (id == null) return null;
		if (id == model.openWorkspace) return client;
		var act = actions;
		return act == null ? null : act.linked(id);
	}

	/** Whether workspace `id`'s rows are the ones its link read, so its records can be acted on now. */
	function liveRows(id:String):Null<WorkbenchRows> {
		var rows = model.rows(id);
		return rows != null && rows.live && clientOf(id) != null ? rows : null;
	}

	/** The `w:` row of workspace `id`, where its root-level rows sit; null for a workspace the machine does not list. */
	function workspaceRow(id:String):Null<String>
		return model.workspaces.exists(id) ? WorkbenchRowKey.machineWorkspace(id) : null;

	/**
		Runs `action` with workspace `id`'s client once its link has read its lists (WorkbenchActions.inWorkspace): at
		once when it has. The window stays where it is.
	**/
	function inWorkspace(id:Null<String>, action:WorkspaceWorkbenchClient->Void, agents:Bool = false):Void {
		var act = actions, entry = id == null ? null : model.workspaces.get(id), known = clientOf(id);
		if (id != null && known != null && liveRows(id) != null && WorkbenchActions.rowsRead(known, agents)) action(known);
		else if (act != null && entry != null) act.inWorkspace(entry, action, agents);
		else if (id == model.openWorkspace) action(client);
	}

	/**
		Runs `action` in workspace `id` with the window there: at once when the window shows it with its rows in, else
		once it does (WorkbenchActions.goTo opens it here first). For what opens that workspace's tab or context
		(Workbench design Q2).
	**/
	function goThere(id:Null<String>, action:Void->Void, agents:Bool = false):Void {
		var act = actions, entry = id == null ? null : model.workspaces.get(id);
		if (id != null && id == model.openWorkspace && liveRows(id) != null && WorkbenchActions.rowsRead(client, agents)) action();
		else if (act != null && entry != null) act.goTo(entry, action, agents);
		else if (id == model.openWorkspace) action();
	}

	/** Opens the row (a click, Enter or a double click); false for a row that opens nothing. */
	function openRow(key:String):Bool {
		var id = WorkbenchRowKey.workspaceId(key);
		if (id == null) id = WorkbenchRowKey.noteWorkspace(key);
		if (id != null) {
			var entry = model.workspaces.get(id), act = actions;
			if (entry == null || act == null) return false;
			var row = WorkbenchRowKey.machineWorkspace(id);
			// The open workspace's row enters its root, keeping the keyboard on the tree.
			if (row == model.openRow && focusRoot != null) focusRoot();
			else act.open(entry);
			tree.focusItem(row);
			selectAfterEnter(row);
			return true;
		}
		var row = WorkbenchRowKey.parse(key);
		if (row == null) return false;
		// A group is entered, and a session or terminal opened, in its workspace: the window goes there. It can get there
		// at once, before the tree's model follows, so the action opens the row without asking where the window is again.
		if (row.workspace != model.openWorkspace) goThere(row.workspace, function() openInWorkspace(key, row), row.kind == WorkbenchRowKind.Agent);
		else openInWorkspace(key, row);
		return true;
	}

	/** Opens a group, session or terminal row with the window on its workspace, whose client `client` is. */
	function openInWorkspace(key:String, row:WorkbenchRowKey):Void {
		if (row.kind == WorkbenchRowKind.Group) {
			if (focusGroup != null) focusGroup(row.id);
			// Entering a context rebuilds the window's views, which drops focus; keep the keyboard on this row.
			tree.focusItem(key);
			selectAfterEnter(key);
			return;
		}
		if (row.kind == WorkbenchRowKind.Agent) {
			client.agentService().agentAction(row.id, "read", "", null);
			openAgent(row.id);
		} else {
			var rows = liveRows(row.workspace), terminal = rows == null ? null : rows.terminals.get(row.id);
			if (terminal != null) open(client, terminal);
		}
	}

	function selectAfterEnter(key:String):Void {
		pendingEnterKey = key; pendingEnterUntil = Sys.time() + 1.5;
		requestFrame();
	}

	/**
		The re-keyed tree comes back with the selection the entered context last had; the row that was entered wins. Only
		for the moment the switch takes (and not past the user's next choice of row), so a later selection is never
		overridden.
	**/
	function applyPendingEnterSelection():Void {
		var key = pendingEnterKey;
		if (key == null) return;
		if (Sys.time() > pendingEnterUntil) { pendingEnterKey = null; return; }
		if (tree.selectedKey == key) { requestFrame(); return; }
		pendingEnterKey = null;
		try tree.select(key, false) catch (_:Dynamic) {}
		requestFrame();
	}

	/** The workspaces whose rows are expanded now (the window keeps a link to each that runs, for its rows). */
	public function expandedWorkspaceIds():Array<String> {
		var ids:Array<String> = [];
		for (key in expandedWorkspaces.keys()) {
			var id = WorkbenchRowKey.workspaceId(key);
			if (id != null) ids.push(id);
		}
		return ids;
	}

	function createWorkspace():Void {
		var act = actions;
		if (act != null) act.create();
	}

	function createWorkspaceFromFolder():Void {
		var act = actions;
		if (act != null) act.createFromFolder();
	}

	/**
		Every row's menu (Workbench design Q1), the same in every workspace: a workspace's (its note's too) whether it is
		open, running or idle; a group's, session's or terminal's; New Workspace….
	**/
	function rowMenu(key:String, event:UiEvent):Void {
		var id = WorkbenchRowKey.workspaceId(key);
		if (id == null) id = WorkbenchRowKey.noteWorkspace(key);
		var entry = id == null ? null : model.workspaces.get(id);
		if (entry != null) { workspaceMenu(entry, event); return; }
		if (WorkbenchRowKey.isMachineRow(key)) { machineMenu(event); return; }
		var row = WorkbenchRowKey.parse(key);
		if (row == null) return;
		if (liveRows(row.workspace) != null) menu(row.workspace, groupFor(key), event, key);
		else snapshotMenu(row, key, event);
	}

	/** New Workspace… and Add Workspace from Folder…, from the machine's status rows and their own rows. */
	function machineMenu(event:UiEvent):Void {
		var act = actions;
		if (act != null && act.manages()) showMenu([
			new MenuItem("machine-new-workspace", "New Workspace…", act.create, !act.busy()),
			new MenuItem("machine-folder-workspace", "Add Workspace from Folder…", act.createFromFolder, !act.busy())
		], event, function() return true);
	}

	/** A workspace row's menu, the same for every workspace: create in it, then its own actions and New Workspace…. */
	function workspaceMenu(entry:MachineWorkspace, event:UiEvent):Void {
		var act = actions;
		if (act == null) return;
		var idle = !act.busy(), target = entry;
		var items = createItems(entry.id, WorkspaceProtocol.ROOT_GROUP, event);
		// A device uses the workspaces it is granted; only exohost's own machine changes them.
		if (!act.manages()) { showMenu(items, event, function() return act.workspaceById(target.id) != null); return; }
		items.push(new MenuItem("machine-workspace-rename", "Rename…", function() act.rename(target), idle, "F2", true));
		items.push(new MenuItem("machine-workspace-attach-folder", "Attach Folder…", function() act.attachFolder(target), idle));
		items.push(new MenuItem("machine-workspace-detach-folder", "Detach Folder…", function() act.detachFolder(target), idle && target.folders.length > 0));
		items.push(new MenuItem("machine-workspace-new-window", "Open in New Window", function() act.openInNewWindow(target, null), true, null, true));
		items.push(new MenuItem("machine-workspace-remove", "Remove from This Machine", function() act.remove(target), idle, null, true));
		items.push(new MenuItem("machine-new-workspace", "New Workspace…", act.create, idle, null, true));
		items.push(new MenuItem("machine-folder-workspace", "Add Workspace from Folder…", act.createFromFolder, idle));
		showMenu(items, event, function() return act.workspaceById(target.id) != null);
	}

	/**
		What every row makes in its workspace `id` or group (`group`, ROOT_GROUP for the workspace itself): New Agent
		Session with the default provider at once (Workbench design Q7), New Agent Session With… for the other providers
		and Change Folder…, New Terminal and New Group. Until the workspace's link has read its lists they are offered,
		and refused with the reason once it has.
	**/
	function createItems(id:String, group:String, event:Null<UiEvent>):Array<MenuItem> {
		var known = liveRows(id) == null ? null : clientOf(id);
		var provider = defaultProvider();
		var canAgent = id != model.openWorkspace || canCreateAgent();
		var items = [
			new MenuItem("new-agent", "New Agent Session", function() make(id, group, false, provider), canAgent,
				WorkbenchActions.providerLabel(provider)),
			new MenuItem("new-agent-with", "New Agent Session With…", function() { if (event != null) showMenu(providerItems(id, group, provider), event, function() return true); }, canAgent),
			new MenuItem("new-chat-with", "New Chat With…", function() { if (event != null) showMenu(chatItems(id, group), event, function() return true); }, actions != null),
			new MenuItem("new-terminal", "New Terminal", function() make(id, group, true),
				known == null || known.canCreateGroupedTerminals() && !known.terminalCatalogBusy()),
			new MenuItem("new-group", "New Group", function() inWorkspace(id, function(_) {
				var rows = model.rows(id), parent = WorkspaceProtocol.isRoot(group) ? null : group;
				reveal(id);
				beginGroup(id, {id: workspace.client.WorkspaceIds.create("group"), name: "", cwd: null, revision: 0, parent: parent,
					order: rows == null ? 0 : rows.nextOrder(parent)}, true);
			}), known == null || known.canEditGroups() && !known.terminalCatalogBusy() && !pending)
		];
		return items;
	}

	/**
		What New Terminal (`terminal`) or New Agent Session with `provider` (the default one when null) on a row does, in
		workspace `id` (the open one when null), in `group` (ROOT_GROUP for the workspace itself). A terminal is made in
		that workspace and opens in a tab here; a session opens in its workspace, and the window goes there (Workbench
		design Q2). The control plane's `exosuit.terminal.create` and `exosuit.agent.create` run this too.
	**/
	public function make(id:Null<String>, group:String, terminal:Bool, ?provider:String):Void {
		var workspace = id == null ? model.openWorkspace : id;
		if (workspace == null) return;
		if (terminal) inWorkspace(workspace, function(_) { reveal(workspace); createTerminal(workspace, group); });
		else goThere(workspace, function() { reveal(workspace); createProvider(provider == null ? defaultProvider() : provider, group); });
	}

	/** Expands the row of workspace `id`, so what is made in it is in view. */
	function reveal(id:String):Void {
		var row = workspaceRow(id);
		if (row != null) tree.setExpanded(row, true);
	}

	/**
		New Chat With… `provider` in workspace `id` (the open one when null), in `group`: the session opens in the chat
		view, not a terminal, and the window goes to its workspace as New Agent Session's does.
	**/
	public function makeChat(id:Null<String>, group:String, provider:String):Void {
		var workspace = id == null ? model.openWorkspace : id, act = actions;
		if (workspace == null || act == null) return;
		goThere(workspace, function() { reveal(workspace); act.createChat(provider, group); });
	}

	/** New Chat With…: every provider, each opening its chat in the workspace. */
	function chatItems(id:String, group:String):Array<MenuItem> {
		var items:Array<MenuItem> = [];
		for (provider in WorkbenchActions.PROVIDERS) {
			var chosen = provider;
			items.push(new MenuItem("new-chat-" + chosen, WorkbenchActions.providerLabel(chosen), function() makeChat(id, group, chosen)));
		}
		return items;
	}

	/** New Agent Session With…: the other providers, then Change Folder… for the default one; each goes to the workspace. */
	function providerItems(id:String, group:String, provider:String):Array<MenuItem> {
		var items:Array<MenuItem> = [];
		for (other in WorkbenchActions.PROVIDERS) if (other != provider) {
			var chosen = other;
			items.push(new MenuItem("new-agent-" + chosen, WorkbenchActions.providerLabel(chosen), function() make(id, group, false, chosen)));
		}
		var choose = chooseSessionFolder;
		if (choose != null)
			items.push(new MenuItem("new-agent-folder", "Change Folder…", function() goThere(id, function() { reveal(id); choose(provider, group); }), true, null, true));
		return items;
	}

	/**
		The menu of a group, session or terminal drawn from a copy of its workspace's catalog, before the workspace's link
		has read its lists (an idle workspace's row, say): the same actions as a live row's, each run on the row once the
		lists are in (`runItem`); creating and Open in New Window need no row.
	**/
	function snapshotMenu(row:WorkbenchRowKey, key:String, event:UiEvent):Void {
		var act = actions, entry = model.workspaces.get(row.workspace);
		if (act == null || entry == null) return;
		var agents = row.kind == WorkbenchRowKind.Agent, id = row.workspace;
		var deferred = function(item:String, label:String, separator:Bool = false)
			return new MenuItem(item, label, function() inWorkspace(id, function(_) runItem(key, item, label), agents), true, null, separator);
		var items:Array<MenuItem> = switch row.kind {
			case WorkbenchRowKind.Group:
				var made = createItems(id, row.id, event);
				made.push(deferred("rename-group", "Rename Group", true));
				made.push(deferred("group-directory", "Change Working Directory…"));
				made.push(deferred("group-parent", "Move to Group…", true));
				made.push(deferred("group-order", "Change Sort Order…"));
				var group = row.id;
				if (act.manages()) made.push(new MenuItem("group-new-window", "Open in New Window", function() act.openInNewWindow(entry, group), true, null, true));
				made.push(deferred("group-remove", "Remove Group", true));
				made;
			case WorkbenchRowKind.Agent:
				[new MenuItem("open-codex", "Open agent session", function() openRow(key)), deferred("rename-agent", "Rename session…"),
					deferred("move-agent", "Move to Group…"), deferred("delete-codex-leaf", "Remove from Workbench")];
			case WorkbenchRowKind.Terminal:
				[deferred("terminal-open", "Open Terminal"), deferred("terminal-rename", "Rename Terminal…"),
					deferred("terminal-group", "Move to Group…"), deferred("terminal-close", "Close Terminal", true)];
		};
		showMenu(items, event, function() return model.workspaces.exists(id));
	}

	/** Runs menu item `item` of row `key`, as its live menu offers it now; says so when it cannot. */
	function runItem(key:String, item:String, label:String):Void {
		var row = WorkbenchRowKey.parse(key);
		if (row != null && liveRows(row.workspace) != null)
			for (candidate in rowItems(row.workspace, groupFor(key), key, null)) if (candidate.key == item) {
				if (candidate.enabled) { candidate.onSelect(); requestFrame(); return; }
				break;
			}
		reportError(label + " is not available for that row now");
	}

	/** Asked on every hover, so it only answers. */
	function canDragNode(key:String):Bool
		return canDragRow(key);

	function canDragRow(key:String):Bool {
		var row = WorkbenchRowKey.parse(key);
		if (row == null || draft != null || agentDraft != null || pending) return false;
		var rows = liveRows(row.workspace), known = clientOf(row.workspace);
		if (rows == null || known == null || known.terminalCatalogBusy()) return false;
		return switch row.kind {
			case WorkbenchRowKind.Group: known.canEditGroups() && rows.groups.exists(row.id);
			case WorkbenchRowKind.Terminal: known.canControlTerminals() && rows.terminals.exists(row.id);
			case WorkbenchRowKind.Agent: known.agentService().canControlAgents() && !known.agentService().agentBusy() && rows.agents.exists(row.id);
		};
	}

	/** Whether the pointer is over the middle of `target` now; only that moves a row into it, the edges place it between rows. */
	function canDropNode(source:String, target:String):Bool
		return rowZone(target) == WorkbenchDropZone.Into && canMoveInto(source, target);

	/** Whether `source` may move into `target` (of the same workspace) by the live catalog, permissions and mutation state; says nothing of the pointer. */
	function canMoveInto(source:String, target:String):Bool {
		var row = WorkbenchRowKey.parse(source);
		if (row == null || model.workspaceOfRow(target) != row.workspace || !canDragRow(source)) return false;
		var known = clientOf(row.workspace), catalog = known == null ? null : known.terminalCatalog();
		if (known == null || catalog == null) return false;
		return WorkbenchDropRules.canDrop(source, target, catalog, known.agentService().agents(), workspaceRow(row.workspace));
	}

	/** Where the pointer is on `key`'s row; onto it when the row or the pointer is not known. */
	function rowZone(key:String):WorkbenchDropZone {
		var row = WorkbenchRowKey.parse(key), centre = model.centreOf(key);
		if (row == null || centre == null) return WorkbenchDropZone.Into;
		return WorkbenchDropRules.zone(pointerY - centre, WorkbenchSessionLabel.ROW_HEIGHT, row.kind == WorkbenchRowKind.Group);
	}

	function dropNode(source:String, target:String):Void {
		var keys = tree.isSelected(source) ? outermost(tree.selectedKeys()).filter(function(key) return key != target) : [source];
		var movable = keys.filter(function(key) return canDropNode(key, target));
		reportSkipped(keys.length - movable.length);
		if (movable.length > 1) startBatch(movable, target);
		else if (movable.length == 1) moveNode(movable[0], target);
		tree.setExpanded(target, true);
		requestFrame();
	}

	/** Rows of a multi-row drop that could not go there stay where they are, and the user is told. */
	function reportSkipped(count:Int):Void {
		if (count > 0) reportError(plural(count, "selected row") + " could not be moved there and " + (count == 1 ? "was" : "were") + " left in place");
	}

	/** The rows a drag started on `source` carries: the selection when it is selected, else the row alone. */
	function dragKeys(source:String):Array<String>
		return tree.isSelected(source) ? outermost(tree.selectedKeys()) : [source];

	/** Where a drop at height `y` would put the dragged rows between siblings, or null for a position that places nothing. */
	function placementAt(source:String, y:Float):Null<Placement> {
		var from = WorkbenchRowKey.parse(source), hit = model.rowAt(y);
		if (from == null || hit == null || !canDragRow(source)) return null;
		var known = clientOf(from.workspace), rows = liveRows(from.workspace), catalog = known == null ? null : known.terminalCatalog();
		var row = WorkbenchRowKey.parse(hit.key);
		if (known == null || rows == null || catalog == null || !known.canReorder() || row == null || row.workspace != from.workspace) return null;
		var zone = WorkbenchDropRules.zone(y - hit.centre, WorkbenchSessionLabel.ROW_HEIGHT, row.kind == WorkbenchRowKind.Group);
		if (zone == WorkbenchDropZone.Into) return null;
		var anchor = hit.key, after = zone == WorkbenchDropZone.After;
		if (after && row.kind == WorkbenchRowKind.Group && tree.isExpanded(hit.key)) {
			// The lower edge of an open group is the upper edge of its first row.
			var inside = rows.siblings(row.id);
			if (inside.length > 0) { anchor = inside[0]; after = false; }
		}
		return WorkbenchOrder.plan(rows, catalog, known.agentService().agents(), dragKeys(source), anchor, after, canWriteRow);
	}

	/** Whether the row's client can write `key`'s group or position now; a write it cannot make is dropped silently by the client. */
	function canWriteRow(key:String):Bool {
		var row = WorkbenchRowKey.parse(key);
		if (row == null) return false;
		var known = clientOf(row.workspace), rows = liveRows(row.workspace), catalog = known == null ? null : known.terminalCatalog();
		if (known == null || rows == null || catalog == null) return false;
		return switch row.kind {
			case WorkbenchRowKind.Group: known.canEditGroups() && rows.groups.exists(row.id);
			case WorkbenchRowKind.Terminal:
				var terminal = rows.terminals.get(row.id);
				known.canControlTerminals() && terminal != null && terminal.workspaceRoot == catalog.workspaceRoot;
			case WorkbenchRowKind.Agent:
				var service = known.agentService(), agents = service.agents();
				service.canControlAgents() && agents != null && agents.canMove == true && agents.instance == catalog.instance
					&& agents.root == catalog.workspaceRoot && rows.agents.exists(row.id);
		};
	}

	/** Alt+Up and Alt+Down move the selected row one place among its siblings. */
	function nudge(delta:Int):Bool {
		var key = tree.selectedKey, row = WorkbenchRowKey.parse(key);
		if (key == null || row == null || tree.selectedKeys().length != 1 || !canDragRow(key)) return false;
		var known = clientOf(row.workspace), rows = liveRows(row.workspace), catalog = known == null ? null : known.terminalCatalog();
		if (known == null || rows == null || catalog == null || !known.canReorder() || !batchIdle()) return false;
		var group = rows.groupOfRow(key);
		if (group == null) return false;
		var siblings = rows.siblings(group), at = siblings.indexOf(key), to = at + delta;
		if (at < 0 || to < 0 || to >= siblings.length) return false;
		var plan = WorkbenchOrder.plan(rows, catalog, known.agentService().agents(), [key], siblings[to], delta > 0, canWriteRow);
		if (plan == null) return false;
		if (plan.refusal != null) { reportError(plan.refusal); return true; }
		startPlan(row.workspace, plan.steps);
		return true;
	}

	function startPlan(workspace:String, steps:Array<PlaceStep>):Void {
		var known = clientOf(workspace), catalog = known == null ? null : known.terminalCatalog();
		if (known == null || catalog == null || steps.length == 0 || batchKeys.length > 0 || batchPlan.length > 0) return;
		batchWorkspace = workspace; batchPlan = steps.copy(); batchOwner = catalog.instance;
		batchTerminalError = known.terminalCatalogError(); batchAgentError = known.agentService().agentError();
		runBatch();
	}

	/** Writes one step of a placement against the catalogs as they are now. */
	function placeNode(known:WorkspaceWorkbenchClient, step:PlaceStep):Void {
		var catalog = known.terminalCatalog(), row = WorkbenchRowKey.parse(step.key);
		if (catalog == null || row == null) return;
		var id = row.id;
		switch row.kind {
			case WorkbenchRowKind.Group:
				for (group in catalog.groups) if (group.id == id)
					known.changeGroup(catalog.instance, group, group.name, WorkspaceProtocol.parentFor(step.group), group.cwd, step.order, false);
			case WorkbenchRowKind.Terminal:
				for (terminal in catalog.terminals) if (terminal.id == id) known.renameTerminal(terminal, terminal.name, step.group, step.order);
			case WorkbenchRowKind.Agent:
				var agents = known.agentService().agents();
				if (agents == null) return;
				for (agent in agents.records) if (agent.id == id)
					known.agentService().agentAction(id, "move", step.group, agent.group, null, null, null, null, null, step.order);
		}
	}

	/** The pointer moved with a row held: show where it would land between rows. */
	function dragMovedTo(y:Float):Void {
		var source = dragSource;
		if (source == null) return;
		var placement = placementAt(source, y);
		if (placement == null || placement.refusal != null) model.setInsertion(null);
		else model.setInsertion(placement.anchor, placement.after);
		requestFrame();
	}

	static function overPanel(node:RenderNode, x:Float, y:Float):Bool {
		var bounds = node.globalBounds();
		return x >= bounds.x && x <= bounds.x + bounds.width && y >= bounds.y && y <= bounds.y + bounds.height;
	}

	function endDrag():Void {
		dragSource = null; dragMoved = false;
		model.setInsertion(null);
	}

	function moveNode(source:String, target:String):Void {
		// The zone was decided once at release; a batch step rechecks only the live catalog, permissions and mutation state.
		if (!canMoveInto(source, target)) return;
		var row = WorkbenchRowKey.parse(source);
		if (row == null) return;
		var known = clientOf(row.workspace), rows = model.rows(row.workspace), catalog = known == null ? null : known.terminalCatalog();
		if (known == null || rows == null || catalog == null) return;
		// A group id, or the workspace root for its workspace's row.
		var into = WorkbenchDropRules.destination(target, workspaceRow(row.workspace));
		if (into == null) return;
		var id = row.id, parent = WorkspaceProtocol.parentFor(into);
		switch row.kind {
			case WorkbenchRowKind.Group:
				for (group in catalog.groups) if (group.id == id)
					known.changeGroup(catalog.instance, group, group.name, parent, group.cwd, rows.nextOrder(parent), false);
			case WorkbenchRowKind.Terminal:
				for (terminal in catalog.terminals) if (terminal.id == id) known.renameTerminal(terminal, terminal.name, into, rows.nextOrder(parent));
			case WorkbenchRowKind.Agent:
				var agents = known.agentService().agents();
				if (agents == null) return;
				for (agent in agents.records) if (agent.id == id)
					known.agentService().agentAction(id, "move", into, agent.group, null, null, null, null, null, rows.nextOrder(parent));
		}
	}

	/** A moved group carries its contents, so selected rows inside a selected group stay where they are. */
	function outermost(keys:Array<String>):Array<String> {
		var selected = [for (key in keys) key => true];
		return keys.filter(function(key) {
			var row = WorkbenchRowKey.parse(key), rows = model.rowsOf(key);
			if (row == null || rows == null) return true;
			var visited:Map<String, Bool> = [];
			var parent = WorkbenchRowKey.parentGroupId(model, key);
			while (parent != null && !visited.exists(parent)) {
				if (selected.exists(WorkbenchRowKey.group(row.workspace, parent))) return false;
				visited.set(parent, true);
				var group = rows.groups.get(parent);
				parent = group == null ? null : group.parent;
			}
			return true;
		});
	}

	/** Selected terminals and agent sessions that can be closed or removed now, of the workspace of the first such row. */
	function removableKeys(keys:Array<String>):Array<String> {
		var workspace:Null<String> = null;
		return keys.filter(function(key) {
			var row = WorkbenchRowKey.parse(key);
			if (row == null || (workspace != null && row.workspace != workspace)) return false;
			var known = clientOf(row.workspace), rows = liveRows(row.workspace);
			if (known == null || rows == null) return false;
			var removable = switch row.kind {
				case WorkbenchRowKind.Terminal: closeTerminal != null && known.canControlTerminals() && rows.terminals.exists(row.id);
				case WorkbenchRowKind.Agent: known.agentService().canControlAgents() && agentCanBeRemoved(rows.agents.get(row.id));
				case WorkbenchRowKind.Group: false;
			};
			if (removable) workspace = row.workspace;
			return removable;
		});
	}

	function removeNode(key:String):Void {
		var row = WorkbenchRowKey.parse(key);
		if (row == null || row.kind == WorkbenchRowKind.Group) return;
		if (row.kind == WorkbenchRowKind.Agent) { removeAgent(key, false); return; }
		var known = clientOf(row.workspace), catalog = known == null ? null : known.terminalCatalog(), close = closeTerminal;
		if (known == null || catalog == null || close == null) return;
		for (terminal in catalog.terminals) if (terminal.id == row.id) { close(known, terminal); return; }
	}

	/** Whether no selection action runs and the batch's workspace (the open one when none ran) is not busy. */
	function batchIdle():Bool {
		var known = clientOf(batchKeys.length > 0 || batchPlan.length > 0 ? batchWorkspace : model.openWorkspace);
		return batchKeys.length == 0 && batchPlan.length == 0 && (known == null || !known.terminalCatalogBusy() && !known.agentService().agentBusy());
	}

	/** Removes (null target) or moves rows of one workspace in order, each against the catalog current at its turn. */
	function startBatch(keys:Array<String>, target:Null<String>):Void {
		var workspace = keys.length == 0 ? null : model.workspaceOfRow(keys[0]);
		var known = clientOf(workspace), catalog = known == null ? null : known.terminalCatalog();
		if (workspace == null || known == null || catalog == null || batchKeys.length > 0) return;
		batchWorkspace = workspace; batchKeys = keys.copy(); batchTarget = target; batchOwner = catalog.instance;
		batchTerminalError = known.terminalCatalogError(); batchAgentError = known.agentService().agentError();
		runBatch();
	}

	function runBatch():Void {
		if (batchKeys.length == 0 && batchPlan.length == 0) return;
		var known = clientOf(batchWorkspace), catalog = known == null ? null : known.terminalCatalog();
		if (known == null || catalog == null || catalog.instance != batchOwner) { batchKeys = []; batchPlan = []; return; }
		var service = known.agentService();
		if (known.terminalCatalogBusy() || service.agentBusy()) return;
		// A failed step stops the rest; the panel already reports its error.
		var terminalError = known.terminalCatalogError(), agentError = service.agentError();
		if ((terminalError != null && terminalError != batchTerminalError) || (agentError != null && agentError != batchAgentError)) {
			batchKeys = []; batchPlan = []; return;
		}
		batchTerminalError = terminalError; batchAgentError = agentError;
		if (batchPlan.length > 0) {
			placeNode(known, batchPlan.shift());
			requestFrame();
			return;
		}
		var key = batchKeys.shift(), target = batchTarget;
		if (target == null) removeNode(key); else moveNode(key, target);
		requestFrame();
	}

	static function plural(count:Int, noun:String):String return count + " " + noun + (count == 1 ? "" : "s");

	/** Closing treats every row alike: terminals stop and are forgotten, sessions leave Workbench. */
	static function closeSelectionLabel(keys:Array<String>, removable:Array<String>):String {
		var terminals = removable.filter(function(key) return WorkbenchRowKey.isKind(key, WorkbenchRowKind.Terminal)).length;
		var noun = terminals == removable.length ? "Terminal" : terminals == 0 ? "Session" : "Item";
		var busy = keys.filter(function(key) return WorkbenchRowKey.isKind(key, WorkbenchRowKind.Agent)).length
			- (removable.length - terminals);
		return "Close " + plural(removable.length, noun) + (busy > 0 ? ' ($busy busy)' : "");
	}

	function selectionMenu(keys:Array<String>, event:UiEvent):Void {
		var removable = removableKeys(keys);
		var known = clientOf(removable.length == 0 ? null : model.workspaceOfRow(removable[0]));
		var catalog = known == null ? null : known.terminalCatalog();
		var owner = catalog == null ? "" : catalog.instance;
		var items = [new MenuItem("selection-count", keys.length + " items selected", null, false)];
		if (removable.length > 0)
			items.push(new MenuItem("close-selection", closeSelectionLabel(keys, removable), function() startBatch(removable, null), batchIdle()));
		showMenu(items, event, function() {
			var current = known == null ? null : known.terminalCatalog();
			return known == null || current != null && current.instance == owner;
		});
	}

	function reportError(message:String):Void {
		var handler = onError;
		if (handler != null) handler(message);
	}

	/** The selected row's group, when it belongs to the workspace the window shows. */
	public function selectedGroupId():Null<String> {
		var key = tree.selectedKey, group = groupFor(key);
		return group == null || model.workspaceOfRow(key) != model.openWorkspace ? null : group.id;
	}

	/** A row's group: a group row's own, a session's or terminal's; null for the workspace root or no row. */
	function groupFor(key:Null<String>):Null<WorkspaceGroup>
		return WorkbenchRowKey.groupOf(model, key);

	/**
		Where New terminal and New Codex create: the selected group, or the group of the selected session or terminal;
		otherwise (nothing selected, a root item, a workspace row) the workspace root.
	**/
	function createTarget(key:Null<String>):String {
		var group = groupFor(key);
		return group == null ? WorkspaceProtocol.ROOT_GROUP : group.id;
	}

	function agentCanBeRemoved(agent:Null<WorkspaceAgentProtocol.AgentRecord>):Bool {
		if (agent == null) return false;
		return agent.state != "creating" && agent.state != "reconnecting"
			&& agent.state != "working" && agent.state != "needs-attention";
	}

	/** The menu of a row of workspace `id` (or of the panel's background, with no `key`), whose link has read its lists. */
	function menu(id:Null<String>, group:Null<WorkspaceGroup>, event:UiEvent, ?key:String, ?overflow:Array<MenuItem>):Void {
		if (key != null && tree.isSelected(key)) {
			var selection = tree.selectedKeys();
			if (selection.length > 1) { selectionMenu(selection, event); return; }
		}
		var known = clientOf(id);
		if (id == null || known == null) return;
		var catalog = known.terminalCatalog();
		var owner = catalog == null ? "" : catalog.instance;
		var valid = function() {
			var current = known.terminalCatalog();
			if (current == null || current.instance != owner) return false;
			if (group == null) return true;
			for (candidate in current.groups) if (candidate.id == group.id) return candidate.revision == group.revision;
			return false;
		};
		var terminalId = WorkbenchRowKey.idOf(key, WorkbenchRowKind.Terminal), rows = model.rows(id);
		var terminal = terminalId == null || rows == null ? null : rows.terminals.get(terminalId);
		if (terminal != null) {
			var shown = terminal;
			valid = function() {
				var current = known.terminalCatalog();
				if (current == null || current.instance != owner) return false;
				for (candidate in current.terminals) if (candidate.id == shown.id)
					return candidate.instance == shown.instance && haxe.Int64.compare(candidate.revision, shown.revision) == 0;
				return false;
			};
		}
		var items = rowItems(id, group, key, event, overflow);
		if (items.length > 0) showMenu(items, event, valid);
	}

	/**
		The menu items of row `key` of workspace `id` (null for the panel's background), in `group`: a terminal's, a
		session's, or a group's and the workspace root's. Its workspace's link has read its lists.
	**/
	function rowItems(id:String, group:Null<WorkspaceGroup>, key:Null<String>, event:Null<UiEvent>, ?overflow:Array<MenuItem>):Array<MenuItem> {
		var known = clientOf(id), rows = model.rows(id);
		if (known == null || rows == null) return [];
		var catalog = known.terminalCatalog();
		var editable = known.canEditGroups() && !known.terminalCatalogBusy();
		var cwd = group == null ? null : model.directory(id, group);
		var items:Array<MenuItem> = [];
		var terminalId = WorkbenchRowKey.idOf(key, WorkbenchRowKind.Terminal);
		if (terminalId != null) {
			var terminal = rows.terminals.get(terminalId);
			return terminal == null ? [] : terminalActions(known, terminal);
		}
		var agentId = WorkbenchRowKey.idOf(key, WorkbenchRowKind.Agent);
		if (agentId != null && key != null) {
			var agent = rows.agents.get(agentId), row = key;
			if (agent == null) return [];
			var service = known.agentService();
			items.push(new MenuItem("open-codex", "Open agent session", function() openRow(row)));
			var nativeName = canRenameNative(known, agent.id);
			var canRename = service.canControlAgents() && !service.agentBusy() && !pending && !agentPending;
			items.push(new MenuItem("rename-agent", nativeName ? "Rename session…" : "Rename in Workbench…",
				function() beginAgentRename(row, nativeName), canRename, "F2"));
			if (nativeName) items.push(new MenuItem("rename-agent-label", "Rename in Workbench…",
				function() beginAgentRename(row, false), canRename));
			var move = moveAgent;
			if (move != null && service.canControlAgents())
				items.push(new MenuItem("move-agent", "Move to Group…", function() { move(known, agent); }, !service.agentBusy()));
			if (service.canControlAgents() && agentCanBeRemoved(agent))
				items.push(new MenuItem("delete-codex-leaf", "Remove from Workbench", function() removeAgent(row), !service.agentBusy()));
			return items;
		}
		// Without a group (no row selected), they create at the workspace root.
		for (item in createItems(id, group == null ? WorkspaceProtocol.ROOT_GROUP : group.id, event)) items.push(item);
		if (known.canEditGroups()) {
			if (group != null) {
				items.push(new MenuItem("rename-group", "Rename Group", function() beginGroup(id, group, false), editable && !pending, null, true));
				items.push(new MenuItem("group-directory", "Change Working Directory…", function() edit(known, group, "directory"), editable));
				if (GroupContextActions.canInherit(group))
					items.push(new MenuItem("group-inherit", "Use Inherited Working Directory", function() edit(known, group, "inherit"), editable));
				var moveSeparator = true;
				if (catalog != null && GroupContextActions.canMove(group, catalog.groups)) {
					items.push(new MenuItem("group-parent", "Move to Group…", function() edit(known, group, "parent"), editable, null, true));
					moveSeparator = false;
				}
				items.push(new MenuItem("group-order", "Change Sort Order…", function() edit(known, group, "order"), editable, null, moveSeparator));
			}
		}
		if (cwd != null && group != null)
			items.push(new MenuItem("open-folder", "Open folder", function() openRow(WorkbenchRowKey.group(id, group.id)), true, null, true));
		var owner = model.workspaces.get(id), act = actions;
		if (group != null && owner != null && act != null)
			items.push(new MenuItem("group-new-window", "Open in New Window", function() act.openInNewWindow(owner, group.id), true));
		if (group != null && cwd != null && known.agentService().canControlAgents()) {
			var folder = cwd;
			items.push(new MenuItem("attach-codex", "Attach existing Codex thread…", function() attach(known, group, folder)));
		}
		// Shown whenever the service can remove groups; disabled, with the reason, while this one still has contents.
		var removal = group == null ? GroupRemoval.NotPermitted : GroupContextActions.removal(group, known);
		if (group != null && removal != GroupRemoval.NotPermitted)
			items.push(new MenuItem("group-remove", GroupContextActions.removeLabel(removal), function() edit(known, group, "remove"),
				editable && removal == GroupRemoval.Allowed, null, true));
		if (key == null) {
			items.push(new MenuItem("refresh", "Refresh Workbench", function() {
				if (known.canReadTerminals()) known.refreshTerminals(true);
				if (known.agentService().canReadAgents()) known.agentService().refreshAgents();
			}, known.canReadTerminals() || known.agentService().canReadAgents(), null, true));
		}
		if (overflow != null) for (item in overflow) items.push(item);
		return items;
	}

	/** Removes session row `key` from its workspace's Workbench, closing its tab here. */
	function removeAgent(key:String, select:Bool = true):Void {
		var row = WorkbenchRowKey.parse(key);
		if (row == null) return;
		var known = clientOf(row.workspace), rows = liveRows(row.workspace);
		var agent = rows == null ? null : rows.agents.get(row.id);
		if (known == null || agent == null || !agentCanBeRemoved(agent) || !known.agentService().canControlAgents() || known.agentService().agentBusy()) return;
		if (select) tree.select(key);
		var group = agent.group, workspace = row.workspace;
		known.agentService().deleteAgent(row.id, function() {
			closeAgentTab(row.id, agent.workspaceRoot);
			var after = model.rows(workspace);
			if (select && after != null && after.groups.exists(group)) tree.select(WorkbenchRowKey.group(workspace, group));
			requestFrame();
		});
		requestFrame();
	}

	/** Names a group of workspace `id` in place: a new one (`create`) or a rename. */
	function beginGroup(id:String, group:WorkspaceGroup, create:Bool):Void {
		var known = clientOf(id), catalog = known == null ? null : known.terminalCatalog();
		if (known == null || catalog == null || !known.canEditGroups() || pending || agentPending) return;
		cancelAgentRename();
		draft = group; draftWorkspace = id; creating = create; draftName = group.name;
		draftOwner = catalog.instance; draftError = null;
		inlineEditor = new WorkbenchNameEditor(group.id, draftName, function(value) draftName = value, saveGroup, cancelGroup);
		refreshModel = true;
		revealNode(WorkbenchRowKey.group(id, group.id));
		requestFrame();
	}

	/** Selects row `key` once it is there (a catalog delivery may follow its creation), for a few seconds at most. */
	public function revealNode(key:String):Void {
		pendingReveal = key;
		pendingRevealUntil = Sys.time() + 10;
		requestFrame();
	}

	/** Keeps the tree's selection on the active session's or terminal's row, `key`, once it is there. */
	public function syncActiveSession(key:Null<String>):Void {
		if (key == null || tree.selectedKey == key) {
			pendingSessionSelection = null;
			return;
		}
		if (pendingSessionSelection == key) return;
		pendingSessionSelection = key;
		requestFrame();
	}

	/** The window now shows another workspace: a drag and a delayed tab-to-row selection are over. */
	public function focusChanged():Void {
		tree.cancelDrag();
		pendingSessionSelection = null;
		var scrolled = WorkbenchRowKey.parse(scrollTarget);
		if (scrolled != null && scrolled.kind != WorkbenchRowKind.Group) scrollTarget = null;
	}

	function applyPendingSessionSelection():Void {
		var key = pendingSessionSelection, row = WorkbenchRowKey.parse(key), rows = model.rowsOf(key);
		if (key == null || row == null || rows == null || rows.groupOfRow(key) == null) return;
		var group = WorkbenchRowKey.groupOf(model, key);
		if (!expandAncestors(row.workspace, group == null ? null : group.id)) return;
		if (tree.selectedKey != key) {
			tree.select(key);
			scrollTarget = key;
			scrollPasses = 2;
		}
		pendingSessionSelection = null;
	}

	/** Expands workspace `id`'s row, then `groupId` and every group above it so a row inside shows; false when the chain is broken. */
	function expandAncestors(id:String, groupId:Null<String>):Bool {
		var nesting = workspaceRow(id), rows = model.rows(id);
		if (nesting != null) tree.setExpanded(nesting, true);
		if (rows == null) return false;
		var ancestors:Array<String> = [];
		var visited:Map<String, Bool> = [];
		var parent = groupId;
		while (parent != null && !visited.exists(parent)) {
			visited.set(parent, true);
			ancestors.unshift(WorkbenchRowKey.group(id, parent));
			var ancestor = rows.groups.get(parent);
			if (ancestor == null) return false;
			parent = ancestor.parent;
		}
		for (ancestor in ancestors) tree.setExpanded(ancestor, true);
		return true;
	}

	function applyPendingReveal():Void {
		var key = pendingReveal, row = WorkbenchRowKey.parse(key), rows = model.rowsOf(key);
		if (key == null || row == null) return;
		if (Sys.time() > pendingRevealUntil) { pendingReveal = null; return; }
		if (rows == null || rows.groupOfRow(key) == null) return;
		var group = WorkbenchRowKey.groupOf(model, key);
		var parent = row.kind == WorkbenchRowKind.Group ? (group == null ? null : group.parent) : (group == null ? null : group.id);
		if (!expandAncestors(row.workspace, parent)) return;
		tree.select(key);
		scrollTarget = key;
		scrollPasses = 2;
		pendingReveal = null;
	}

	function canRenameNative(known:WorkspaceWorkbenchClient, id:String):Bool {
		var catalog = known.agentService().agents();
		if (catalog == null || catalog.nativeRenameProviders == null) return false;
		for (record in catalog.records) if (record.id == id) return record.thread != "" && catalog.nativeRenameProviders.indexOf(record.provider == null ? "codex" : record.provider) >= 0;
		return false;
	}

	/** Names session row `key` in place: its own (native) name, or its Workbench label. */
	function beginAgentRename(key:String, nativeName:Bool = false, inspected:Bool = false):Void {
		var row = WorkbenchRowKey.parse(key), known = row == null ? null : clientOf(row.workspace);
		if (row == null || known == null) return;
		var service = known.agentService(), catalog = service.agents(), id = row.id;
		if (catalog == null || draft != null || pending || agentPending || !service.canControlAgents() || service.agentBusy()) return;
		if (catalog.canRename != true) {
			reportError("This workspace service cannot rename agent sessions.");
			return;
		}
		var record:Null<AgentRecord> = null;
		for (candidate in catalog.records) if (candidate.id == id) record = candidate;
		if (record == null) return;
		if (nativeName && !canRenameNative(known, id)) { reportError("Native renaming is no longer available. Reopen the session menu."); return; }
		if (nativeName && !inspected) {
			var owner = catalog.instance, root = catalog.root;
			service.agentAction(id, "inspect-name", "", null, null, null, function() {
				var current = service.agents();
				if (current != null && current.instance == owner && current.root == root) beginAgentRename(key, true, true);
			});
			requestFrame(); return;
		}
		if (nativeName && record.nameMetadata == null) { reportError("Refresh the native session name before renaming."); return; }
		agentDraft = record; agentDraftWorkspace = row.workspace; agentDraftOwner = catalog.instance; agentRenameNative = nativeName;
		var naming = record.nameMetadata;
		agentDraftName = nativeName && naming != null && naming.nativeName != null ? naming.nativeName : record.name;
		agentEditor = new WorkbenchNameEditor(id, agentDraftName, function(value) agentDraftName = value,
			saveAgentName, cancelAgentRename, "agent", nativeName ? "Session name" : "Workbench label");
		agentEditor.onBlur = function() finishAgentRename(false);
		refreshModel = true; revealNode(key); requestFrame();
	}

	function cancelAgentRename():Void finishAgentRename(true);

	function finishAgentRename(restoreRowFocus:Bool):Void {
		if (agentPending || agentDraft == null) return;
		var editor = agentEditor;
		var restore = editor == null ? null : editor.restoreFocus;
		if (restoreRowFocus && restore != null) restore();
		agentDraft = null; agentEditor = null; refreshModel = true; requestFrame();
	}

	function saveAgentName():Void {
		var base = agentDraft, known = clientOf(agentDraftWorkspace);
		if (base == null || known == null) return;
		var service = known.agentService(), catalog = service.agents();
		if (agentPending || service.agentBusy() || !service.canControlAgents()) return;
		var name = workspace.service.AgentNames.normalize(agentDraftName);
		if (name == null) { reportError("Enter a session name of 1–256 characters without line breaks or control characters."); return; }
		if (catalog == null || catalog.instance != agentDraftOwner || catalog.root != base.workspaceRoot) {
			reportError("The workspace changed. Cancel and try again."); return;
		}
		if (name == base.name && !agentRenameNative) { cancelAgentRename(); return; }
		agentPending = true;
		var metadata = base.nameMetadata;
		service.agentAction(base.id, agentRenameNative ? "rename-native" : "rename", name, base.name, null, null, function() {
			if (agentDraft != base) return;
			agentPending = false; cancelAgentRename();
		}, agentRenameNative && metadata != null ? metadata.nativeName : null);
		requestFrame();
	}

	function cancelGroup():Void {
		if (pending) return;
		draft = null; inlineEditor = null; draftError = null;
		refreshModel = true; requestFrame();
	}

	function saveGroup():Void {
		var base = draft, known = clientOf(draftWorkspace);
		if (base == null || known == null || pending || known.terminalCatalogBusy()) return;
		var name = StringTools.trim(draftName);
		if (name == "") { draftError = "Enter a group name."; requestFrame(); return; }
		var catalog = known.terminalCatalog();
		if (catalog == null || catalog.instance != draftOwner) {
			draftError = "The workspace changed. Cancel and try again."; requestFrame(); return;
		}
		draftName = name; draftError = null; pending = true; pendingSince = Sys.time();
		known.changeGroup(draftOwner, base, name, base.parent, base.cwd, WorkspaceProtocol.order(base.order), creating);
		requestFrame();
	}

	function toolbarButton(label:String, icon:IconName, action:Void->Void, key:String):Button {
		var style = new LayoutStyle(); style.width = LayoutAxis.fixed(24); style.height = LayoutAxis.fixed(24);
		style.padding = new Insets(4, 4, 4, 4);
		var button = new Button("", style, action, key);
		button.accessibilityLabel = label; button.leadingIcon = icon; button.variant = ButtonVariant.Navigation;
		button.classes.push("chrome-action");
		return button;
	}

	function syncState():Void {
		var drafted = draft == null ? null : clientOf(draftWorkspace);
		if (pending && (drafted == null || !drafted.terminalCatalogBusy())) {
			var saved = false;
			var base = draft, catalog = drafted == null ? null : drafted.terminalCatalog();
			if (catalog != null && catalog.instance == draftOwner && base != null)
				for (group in catalog.groups) if (group.id == base.id && group.name == draftName && group.revision > base.revision) saved = true;
			var failure = drafted == null ? "The workspace is no longer connected." : drafted.terminalCatalogError();
			if (saved) { pending = false; cancelGroup(); if (base != null) revealNode(WorkbenchRowKey.group(draftWorkspace, base.id)); }
			else if (failure != null || Sys.time() - pendingSince > 10) {
				pending = false;
				draftError = failure == null ? "Could not confirm the save. Refresh before retrying." : failure;
			}
		}
		if (inlineEditor != null) inlineEditor.enabled = !pending;
		var renamed = agentDraft == null ? null : clientOf(agentDraftWorkspace);
		if (agentPending && (renamed == null || !renamed.agentService().agentBusy())) agentPending = false;
		if (agentEditor != null) agentEditor.enabled = !agentPending;
		var view = actions == null ? WorkbenchActions.NO_MACHINE : actions.view();
		// A row the tree expanded by itself (the workspace the window started on, or one just made) is followed like one
		// the chevron expanded: its rows stay shown after the window moves on.
		var state = view.machine;
		if (state != null)
			for (entry in state.workspaces) {
				var key = WorkbenchRowKey.machineWorkspace(entry.id);
				if (!expandedWorkspaces.exists(key) && tree.isExpanded(key)) { expandedWorkspaces.set(key, true); expandRevision++; }
			}
		model.openFailure = connectionFailure == null ? null : connectionFailure();
		var sources = view.rows == null ? new Map<String, WorkbenchRowSource>() : view.rows;
		// The open workspace's rows follow at once; the other workspaces' changes alone can wait a moment.
		var open = view.openWorkspace == null ? null : sources.get(view.openWorkspace);
		var nextStructure = view.revision + "\n" + view.openWorkspace + "\n" + expandRevision + "\n" + model.openFailure
			+ "\n" + (open == null ? "" : open.revision + ":" + (open.terminals != null) + ":" + (open.snapshot == null ? -1 : open.snapshot.revision));
		var nextMachineKey = nextStructure + "\n" + view.watchRevision;
		var now = Sys.time();
		var due = throttle.due(nextStructure, nextMachineKey, now);
		if (throttle.waiting) requestFrame();
		if (refreshModel || due) {
			refreshModel = false; throttle.took(nextStructure, nextMachineKey, now);
			model.expandedRows = expandedWorkspaces;
			model.update(view, sources, creating ? draft : null, draftWorkspace);
			followOpenWorkspace();
		}
		applyPendingReveal();
		applyPendingSessionSelection();
		applyPendingEnterSelection();
		runBatch();
	}

	/**
		A workspace just made from New Workspace… or Add Workspace from Folder… takes the selection from that row, so the keyboard and the header
		buttons act on the new workspace. Expanding stays the user's (the chevron): opening a workspace does not.
	**/
	function followOpenWorkspace():Void {
		var open = model.openRow;
		if (open == observedOpenRow) return;
		observedOpenRow = open;
		var selected = tree.selectedKey;
		if (open != null && (selected == WorkbenchRowKey.NEW_WORKSPACE || selected == WorkbenchRowKey.FOLDER_WORKSPACE)) selectAfterEnter(open);
	}

	public function headerActions(availableWidth:Float = 260):View return new WorkbenchHeaderActions(this, availableWidth);

	/** The header's buttons act in the selected row's workspace, else in the one the window shows. */
	public function buildHeaderActions(context:BuildContext, availableWidth:Float):RenderNode {
		syncState();
		var selectedKey = tree.selectedKey, workspace = model.workspaceOfRow(selectedKey);
		if (workspace == null) workspace = model.openWorkspace;
		var id = workspace, here = workspace == model.openWorkspace, known = clientOf(workspace);
		var selected = groupFor(selectedKey), into = createTarget(selectedKey);
		var terminal = toolbarButton("New terminal", IconName.Terminal, function() make(id, into, true), "workbench-new-terminal");
		terminal.enabled = known == null ? !here && id != null : known.canCreateGroupedTerminals() && !known.terminalCatalogBusy();
		var provider = defaultProvider(), agentLabel = "New " + WorkbenchActions.providerLabel(provider) + " session";
		var agent = toolbarButton(agentLabel, IconName.Plus, function() make(id, into, false, provider), "workbench-new-agent");
		agent.enabled = here ? canCreateAgent() : id != null;
		var selectedAgentId = WorkbenchRowKey.idOf(selectedKey, WorkbenchRowKind.Agent), rows = liveRows(workspace);
		var selectedAgent = selectedAgentId == null || rows == null ? null : rows.agents.get(selectedAgentId);
		var selection = tree.selectedKeys();
		var multiple = selection.length > 1;
		var removable = multiple ? removableKeys(selection) : [];
		var removeSelected = function() {
			if (multiple) startBatch(removable, null);
			else if (selectedAgent != null && selectedKey != null) removeAgent(selectedKey);
		};
		var deleteAgent = toolbarButton("Remove selected leaf from Workbench", IconName.Trash, removeSelected, "workbench-delete-codex");
		deleteAgent.enabled = multiple ? removable.length > 0 && batchIdle()
			: known != null && agentCanBeRemoved(selectedAgent) && known.agentService().canControlAgents() && !known.agentService().agentBusy();
		var overflow:Array<MenuItem> = [];
		if (availableWidth < 260 && (selectedAgent != null || multiple))
			overflow.push(new MenuItem("delete-selected-agent", multiple ? closeSelectionLabel(selection, removable) : "Remove from Workbench",
				removeSelected, deleteAgent.enabled));
		var more = toolbarButton("Workbench actions", IconName.ChevronDown, null, "workbench-actions");
		more.onClickEvent = function(event) {
			if (liveRows(id) != null) menu(id, selected, event, null, overflow);
		};
		var toolbarStyle = new LayoutStyle(); toolbarStyle.childAlignY = haxeon.ui.LayoutAlignmentY.Center; toolbarStyle.childGap = 2;
		toolbarStyle.padding = new Insets(2, 0, 4, 0);
		var delay = tooltipDelay();
		var visibleTooltip = context.resourceState(context.id("workbench-tooltip-visible"),
			function():Null<String> return null, function(_) {});
		var hover = context.resourceState(context.id("workbench-tooltip-hover"),
			function() return new TooltipHoverGroup(context.animations, function(key) visibleTooltip.update(key), delay),
			function(value) value.dispose()).value;
		hover.delaySeconds = delay;
		function tip(key:String, anchor:View, label:String):View return new TabTooltip(key, anchor, new Text(label),
			function() return new Rect(0, 0, context.viewportWidth, context.viewportHeight), delay, Below, hover, visibleTooltip.value == key);
		var actions:Array<KeyedView> = [];
		if (availableWidth >= 170) actions.push(new KeyedView("terminal", tip("new-terminal-tip", terminal, known == null ? "New terminal"
				: !known.canReadTerminals() ? "Connect to a workspace with terminal read permission"
				: !known.canControlTerminals() ? "Terminal creation requires terminal control permission"
				: !known.canCreateGroupedTerminals() ? "This workspace does not support grouped terminals" : "New terminal")));
		if (availableWidth >= 210) actions.push(new KeyedView("agent", tip("new-agent-tip", agent, agentLabel)));
		if (availableWidth >= 260) actions.push(new KeyedView("delete-agent", tip("delete-agent-tip", deleteAgent, "Remove from Workbench")));
		actions.push(new KeyedView("more", tip("workbench-actions-tip", more, "Actions")));
		return new Row("workbench-header-actions", actions, toolbarStyle).build(context);
	}

	/** Whether the open workspace's row says it has nothing yet (a test seam for the automation snapshot). */
	public function showsEmptyState():Bool {
		var open = model.openRow, id = model.openWorkspace;
		return open != null && id != null && model.childCount(open) == 1 && model.childKeyAt(open, 0) == WorkbenchRowKey.note(WorkbenchRowKey.NOTE_EMPTY, id);
	}

	public function build(context:BuildContext):RenderNode {
		syncState();
		var rows:Array<KeyedView> = [];
		rows.push(new KeyedView("tree", tree));
		var error = draftError == null ? client.terminalCatalogError() : draftError;
		if (error == null) error = client.agentService().agentError();
		if (error != lastReportedError) {
			lastReportedError = error;
			if (error != null) reportError(error);
		}
		var creation = client.agentService().agentCreation();
		var progress = creation != null ? "Starting " + creation.name + " session…"
			: client.agentService().agentBusy() || client.terminalCatalogBusy() ? "Session operation in progress…" : null;
		if (progress != null) rows.push(new KeyedView("operation-pending", new Text(progress, null, null,
			haxeon.ui.core.TextStyleOverride.text(12))));

		var style = new LayoutStyle(); style.width = LayoutAxis.stretch(); style.height = LayoutAxis.grow();
		var node = new Column("workbench", rows, style).build(context);
		node.onResolved(function(_) {
			model.layoutChanged(node);
			var target = scrollTarget;
			if (target != null && scrollPasses > 0) {
				// A second layout uses the expanded tree's updated scroll extent.
				tree.scrollTo(target);
				scrollPasses--;
				if (scrollPasses == 0) scrollTarget = null;
				requestFrame();
			}
		});
		// The tree owns the drag; these only watch it from the capture phase to place rows between their siblings.
		node.on(haxeon.ui.core.UiEventKind.PointerDown, function(event) {
			if (event.button != 0) return;
			pressX = event.x; pressY = event.y; pointerY = event.y; dragMoved = false;
			// The row under the press is the one a drag would carry; hover queries of the tree must not decide that.
			var pressed = model.rowAt(event.y);
			dragSource = pressed != null && canDragRow(pressed.key) ? pressed.key : null;
		}, "capture");
		node.on(haxeon.ui.core.UiEventKind.PointerMove, function(event) {
			pointerY = event.y;
			if (dragSource == null) return;
			if (!dragMoved) {
				var dx = event.x - pressX, dy = event.y - pressY;
				if (dx * dx + dy * dy < 36) return;
				dragMoved = true;
			}
			// Outside the panel nothing would be placed, so no line is shown there.
			if (overPanel(node, event.x, event.y)) dragMovedTo(event.y);
			else if (model.insertion != null) { model.setInsertion(null); requestFrame(); }
		}, "capture");
		node.on(haxeon.ui.core.UiEventKind.PointerUp, function(event) {
			pointerY = event.y;
			var source = dragSource, moved = dragMoved;
			if (event.button != 0 || source == null) return;
			var placement = moved && overPanel(node, event.x, event.y) ? placementAt(source, event.y) : null;
			endDrag();
			if (placement == null) return;
			// The rows go between siblings, not into a row, so the tree sees no valid drop and leaves the rest to us.
			var refusal = placement.refusal;
			if (refusal != null) { reportError(refusal); requestFrame(); return; }
			reportSkipped(placement.skipped);
			var workspace = model.workspaceOfRow(source);
			if (workspace != null) startPlan(workspace, placement.steps);
			requestFrame();
		}, "capture");
		node.on(haxeon.ui.core.UiEventKind.PointerCancel, function(_) endDrag(), "capture");
		node.on(haxeon.ui.core.UiEventKind.KeyDown, function(event) {
			if (event.key == haxeon.ui.core.UiKey.Escape && dragSource != null) {
				// The tree's own drag ends too, so a release after Escape cannot still move a row into a group.
				endDrag(); tree.cancelDrag(); event.cancelPointerCapture();
			}
			else if ((event.key == haxeon.ui.core.UiKey.Up || event.key == haxeon.ui.core.UiKey.Down) && (event.modifiers & haxeon.ui.core.UiModifier.Alt) != 0
				&& draft == null && agentDraft == null && nudge(event.key == haxeon.ui.core.UiKey.Up ? -1 : 1)) {
				event.preventDefault(); event.stopPropagation();
			}
		}, "capture");
		node.on(haxeon.ui.core.UiEventKind.KeyDown, function(event) {
			if (event.key == haxeon.ui.core.UiKey.F2 && draft == null && agentDraft == null) {
				var key = tree.selectedKey, row = WorkbenchRowKey.parse(key);
				var workspaceId = WorkbenchRowKey.workspaceId(key), act = actions;
				var renamed = workspaceId == null ? null : model.workspaces.get(workspaceId);
				var known = row == null || liveRows(row.workspace) == null ? null : clientOf(row.workspace);
				if (renamed != null && act != null) {
					event.preventDefault(); event.stopPropagation();
					act.rename(renamed);
				} else if (key != null && row != null && known != null && row.kind == WorkbenchRowKind.Agent) {
					event.preventDefault(); event.stopPropagation(); beginAgentRename(key, canRenameNative(known, row.id));
				} else if (row != null && known != null && row.kind == WorkbenchRowKind.Group && known.canEditGroups()) {
					var group = groupFor(key);
					if (group != null) { event.preventDefault(); event.stopPropagation(); beginGroup(row.workspace, group, false); }
				}
			}
		}, "capture");
		node.on(haxeon.ui.core.UiEventKind.PointerDown, function(event) {
			if (event.button == 1 && !event.defaultPrevented) {
				var open = model.openWorkspace;
				event.preventDefault(); event.stopPropagation();
				if (open != null && liveRows(open) != null) menu(open, null, event);
			}
		});
		return node;
	}
}

/** Stable parent handles commit/cancel while the text field patches its own state. */
private class WorkbenchNameEditor implements View {
    final id:String;
    var value:String;
    public var enabled = true;
	public var restoreFocus:Null<Void->Void>;
	public var onBlur:Null<Void->Void>;
    final change:String->Void;
    final save:Void->Void;
    final cancel:Void->Void;
    var focusRequested = false;
	final kind:String;
	final label:String;
	var selection:haxeon.ui.widgets.text.TextSelection;
    public function new(id:String, value:String, change:String->Void, save:Void->Void, cancel:Void->Void, kind:String = "group", ?label:String) {
        this.id = id; this.value = value; this.change = change; this.save = save; this.cancel = cancel;
		this.kind = kind; this.label=label==null ? "Group name" : label; selection = new haxeon.ui.widgets.text.TextSelection(0, new haxeon.editor.TextDocument(value).codepointCount);
    }
    public function build(context:BuildContext):RenderNode {
        var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.height = LayoutAxis.fixed(28);
        style.padding = new Insets(4, 2, 4, 2);
        var field = new haxeon.ui.widgets.text.TextField(kind + "-name-" + id, value, function(next) { value = next; change(next); }, style, label);
        field.placeholder = kind == "agent" ? "Session name" : "New group";
		field.selectionProvider = function() return selection;
		field.onSelectionChange = function(value) selection = value;
        field.enabled = enabled;
        var input = field.build(context);
		var blur = function(_:UiEvent) {
			var handler = onBlur;
			if (handler != null) handler();
		};
		input.on(haxeon.ui.core.UiEventKind.Blur, blur);
		input.on(haxeon.ui.core.UiEventKind.FocusLost, blur);
        input.onResolved(function(_) { if (!focusRequested) focusRequested = context.requestFocus(input.id); });
        var containerStyle = new LayoutStyle(); containerStyle.width = LayoutAxis.grow(); containerStyle.height = LayoutAxis.fixed(28);
        var node = new RenderNode(context.id(kind + "-name-editor"), haxeon.ui.LayoutVisualKind.Box, containerStyle);
        node.add(input);
		restoreFocus = function() {
			var row = node.parent;
			while (row != null && !row.focusable) row = row.parent;
			if (row != null) context.requestFocusAfterLayout(row.id);
		};
		node.on(haxeon.ui.core.UiEventKind.Click, function(event) event.stopPropagation());
        node.on(haxeon.ui.core.UiEventKind.KeyDown, function(event) {
            if (event.key == haxeon.ui.core.UiKey.Enter || event.key == haxeon.ui.core.UiKey.Escape) {
                event.preventDefault(); event.stopImmediatePropagation();
                if (event.key == haxeon.ui.core.UiKey.Enter) save(); else cancel();
            }
        }, "capture");
        return node;
    }
}

/** Header actions share the panel selection and current service capabilities. */
private class WorkbenchHeaderActions implements View {
	final panel:WorkbenchPanel;
	final width:Float;
	public function new(panel:WorkbenchPanel, width:Float) { this.panel = panel; this.width = width; }
	public function build(context:BuildContext):RenderNode return panel.buildHeaderActions(context, width);
}
