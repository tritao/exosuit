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
import ui.WorkbenchMachineView.WorkbenchWorkspaceState;
import ui.WorkbenchOrder;
import ui.WorkbenchRowKey.ForeignRow;
import workspace.client.WorkspaceWorkbenchClient;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalProtocol;

/** Groups and sessions own the sidebar; secondary actions live in contextual surfaces. */
class WorkbenchPanel implements View {
	final client:WorkspaceWorkbenchClient;
	final open:TerminalRecord->Bool;
	final createTerminal:String->Void;
	final openAgent:String->Void;
	/** A group action; null is the workspace root, for the actions that create in it ("new-agent", "new-terminal"). */
	final edit:(Null<WorkspaceGroup>, String)->Void;
	final openFolder:WorkspaceGroup->Void;
	final terminalActions:TerminalRecord->Array<MenuItem>;
	final requestFrame:Void->Void;
	final showMenu:(Array<MenuItem>, UiEvent, Void->Bool)->Void;
	final attach:WorkspaceGroup->Void;
	final closeAgentTab:(String, String)->Void;
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
	public var closeTerminal:Null<TerminalRecord->Void>;
	/** Asks which group (or the workspace root) a session moves to: its Move to Group…. */
	public var moveAgent:Null<WorkspaceAgentProtocol.AgentRecord->Void>;
	/** This machine and its workspaces, the tree's top level; null when suit is off, and the tree is the groups alone. */
	public var machine:Null<WorkbenchMachineActions>;
	/** Opens a folder picker; with `hasFolder` and no machine, the empty Workbench offers it when no folder is open. */
	public var chooseFolder:Null<Void->Void>;
	public var hasFolder:Null<Void->Bool>;
	var lastReportedError:Null<String>;
	// Selection actions run one step at a time: the service drops a mutation while another is in flight.
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
	var agentDraftOwner = "";
	var agentDraftName = "";
	var agentRenameNative = false;
	var agentPending = false;
	var agentEditor:Null<WorkbenchNameEditor>;
	var catalogRevision = -1;
	var agentKey = -1;
	var retainedAgents:Null<workspace.service.WorkspaceAgentProtocol.AgentCatalog>;
    var draft:Null<WorkspaceGroup>;
    var draftName = "";
    var draftOwner = "";
    var creating = false;
    var pending = false;
    var pendingSince = 0.0;
    var draftError:Null<String>;
    var inlineEditor:Null<WorkbenchNameEditor>;
    var refreshModel = false;
    var pendingReveal:Null<String>;
    var revealRoot:Null<String>;
    var scrollTarget:Null<String>;
    var scrollPasses = 0;
    var pendingSessionSelection:Null<{var key:String; var workspaceRoot:String;}>;
    var observedWorkspaceRoot:Null<String>;
    var observedWorkspaceInstance:Null<String>;
    // The machine rows' inputs at the last projection, and the last catalog, kept through transport recovery.
    final throttle = new CatalogThrottle();
	/** The workspace rows the tree has open, which are the ones whose catalogs the model projects. */
	final expandedWorkspaces:Map<String, Bool> = [];
	var expandRevision = 0;
    /** An item of another workspace the user clicked: opened once the window is attached to that workspace. */
    var pendingForeign:Null<{workspace:String, kind:WorkbenchRowKind, id:String, from:Null<String>, until:Float}>;
    var retainedCatalog:Null<TerminalCatalog>;
    var observedOpenRow:Null<String>;

	public function new(client:WorkspaceWorkbenchClient, open:TerminalRecord->Bool, createTerminal:String->Void,
		edit:(WorkspaceGroup, String)->Void, openFolder:WorkspaceGroup->Void, terminalActions:TerminalRecord->Array<MenuItem>, requestFrame:Void->Void,
		openAgent:String->Void, showMenu:(Array<MenuItem>, UiEvent, Void->Bool)->Void, attach:WorkspaceGroup->Void,
		closeAgentTab:(String, String)->Void, createProvider:(String, String)->Void, canCreateAgent:Void->Bool, ?tooltipDelay:Void->Float) {
		this.client = client; this.open = open; this.createTerminal = createTerminal; this.edit = edit;
		this.openFolder = openFolder; this.terminalActions = terminalActions; this.requestFrame = requestFrame;
		this.openAgent = openAgent; this.showMenu = showMenu; this.attach = attach; this.closeAgentTab = closeAgentTab;
		this.createProvider = createProvider;
		this.canCreateAgent = canCreateAgent;
		this.tooltipDelay = tooltipDelay == null ? function() return config.Settings.DEFAULT_TOOLTIP_DELAY : tooltipDelay;
		var style = new LayoutStyle(); style.width = LayoutAxis.stretch(); style.height = LayoutAxis.grow();
		tree = new TreeView("workbench-tree", model, style);
		tree.expandOnSingleClick = true;
		tree.multiSelect = true;
		tree.canDragItem = canDragNode;
		tree.canDropItem = canDropNode;
		tree.onItemDrop = dropNode;
		tree.onSelectionChanged = function(_) requestFrame();
		tree.onExpandedChanged = function(key, expanded) {
			if (WorkbenchRowKey.workspaceId(key) != null) {
				if (expanded) expandedWorkspaces.set(key, true);
				else expandedWorkspaces.remove(key);
				if (!expanded) cancelStart(WorkbenchRowKey.workspaceId(key));
				expandRevision++;
			}
			requestFrame();
		};
		tree.onItemContextMenu = function(key, event) {
            event.preventDefault(); event.stopPropagation();
            if (WorkbenchRowKey.isForeign(key)) foreignMenu(key, event);
            else if (WorkbenchRowKey.isMachineRow(key)) machineMenu(key, event);
            else menu(groupFor(key), event, key);
        };
		// Every workspace row can expand. One with a running service just expands, showing its groups, sessions and terminals
		// from its catalog; an idle one starts its service (a kept catalog shows meanwhile), and its catalog then updates.
		// Without catalog connections, expanding a workspace that is not open opens it here, as before Phase 6.
		tree.hasChildrenHint = model.expandable;
		tree.onExpansionRequested = function(key, expanded, _) {
			var id = WorkbenchRowKey.workspaceId(key);
			if (id == null || !expanded || key == model.openRow) return true;
			var watching = watched(), state = watching == null ? null : watching.get(id);
			if (watching == null) {
				openWorkspace(id);
				return false;
			}
			if (state != null && !state.running && !state.starting) startWorkspace(id);
			return true;
		};
		// Enter, Space or a double click. A workspace row is a branch the tree would only toggle, so open it here; another
		// workspace's terminal or session opens too. Groups, and the row of the open workspace, keep the default toggle.
		tree.onActivate = function(key, _) {
			var id = WorkbenchRowKey.workspaceId(key);
			if (id != null) {
				if (key == model.openRow) { enterRow(key); return true; }
				openWorkspace(id);
				return true;
			}
			var foreign = WorkbenchRowKey.parseForeign(key);
			if (foreign != null && foreign.kind != WorkbenchRowKind.Group) { openForeign(foreign); return true; }
			if (enterRow(key)) return true;
			return false;
		};
		tree.onItemActivatedWithEvent = function(key, event) {
			// A click already ran New Workspace… on its first press.
			if (key == WorkbenchRowKey.NEW_WORKSPACE && event.kind != haxeon.ui.core.UiEventKind.Click) createWorkspace();
		};
        model.groupEditor = function(id) return draft != null && draft.id == id ? inlineEditor : null;
		model.agentEditor = function(id) return agentDraft != null && agentDraft.id == id ? agentEditor : null;
		tree.onItemClicked = function(key, count) {
			if (agentDraft != null || draft != null) return;
			if (key == WorkbenchRowKey.NEW_WORKSPACE && count == 1) { createWorkspace(); return; }
			// A single click on another workspace's item only selects it; Enter or a double click opens it (see onItemActivatedWithEvent).
			if (WorkbenchRowKey.isForeign(key)) return;
			// The row of a group or of the open workspace enters it; the chevron expands it. Other rows keep expanding on a click.
			tree.expandOnSingleClick = !enterRow(key);
			var row = WorkbenchRowKey.parse(key);
			if (row != null) openItem(row.kind, row.id);
		};
	}

	/** A group row or the open workspace's row: makes it the window's context. False for any other row. */
	function enterRow(key:String):Bool {
		if (key == model.openRow && WorkbenchRowKey.workspaceId(key) != null) {
			if (focusRoot != null) focusRoot();
			return true;
		}
		var group = WorkbenchRowKey.idOf(key, WorkbenchRowKind.Group);
		if (group == null || WorkbenchRowKey.isForeign(key)) return false;
		if (focusGroup != null) focusGroup(group);
		return true;
	}

	function openItem(kind:WorkbenchRowKind, id:String):Void {
		if (kind == WorkbenchRowKind.Agent) {
			client.agentService().agentAction(id, "read", "", null);
			openAgent(id);
		} else if (kind == WorkbenchRowKind.Terminal) {
			var terminal = model.terminals.get(id);
			if (terminal != null) open(terminal);
		}
	}

	/**
		A session or terminal of another workspace opens in a tab. That needs the window attached to its workspace, so
		the window switches to it first and opens the item once the workspace's tree is attached (Phase 7 makes the
		switch instant).
	**/
	function openForeign(row:ForeignRow):Void {
		if (row.kind == WorkbenchRowKind.Group) return;
		pendingForeign = {workspace: row.workspace, kind: row.kind, id: row.id, from: model.openRow, until: Sys.time() + 60};
		openWorkspace(row.workspace);
	}

	/**
		Opens the item a click on another workspace asked for, once this window is attached to that workspace. The wish
		ends, with a short message when the user is owed one, if the window attaches somewhere else, the attach fails or
		takes too long, or the item is gone by the time the workspace is attached.
	**/
	function resolveForeign():Void {
		var wanted = pendingForeign;
		if (wanted == null) return;
		var target = WorkbenchRowKey.machineWorkspace(wanted.workspace);
		var owner = model.workspaces.get(wanted.workspace);
		var where = owner == null ? "that workspace" : owner.name;
		var what = wanted.kind == WorkbenchRowKind.Agent ? "session" : "terminal";
		var open = model.openRow;
		if (open != target) {
			// The window moved on to another workspace (or this one left the machine): the click no longer applies.
			if (open != wanted.from || owner == null) pendingForeign = null;
			else if (Sys.time() > wanted.until) {
				pendingForeign = null;
				reportError("Could not switch to " + where + " to open the " + what);
			}
			return;
		}
		if (model.groupParent != open) {
			var failure = client.terminalCatalogError();
			if (failure != null) {
				pendingForeign = null;
				reportError("Could not open " + where + ": " + failure);
			} else if (Sys.time() > wanted.until) {
				pendingForeign = null;
				reportError("Opening " + where + " took too long");
			}
			return;
		}
		var loaded = wanted.kind == WorkbenchRowKind.Agent ? client.agentService().agents() != null : true;
		var present = wanted.kind == WorkbenchRowKind.Agent ? model.agents.exists(wanted.id) : model.terminals.exists(wanted.id);
		if (!present && !loaded && Sys.time() <= wanted.until) return;
		pendingForeign = null;
		if (present) openItem(wanted.kind, wanted.id);
		else reportError("That " + what + " is no longer in " + where);
	}

	function watched():Null<Map<String, WorkbenchWorkspaceState>> {
		var actions = machine;
		return actions == null ? null : actions.view().watched;
	}

	/** Collapsing a workspace drops its start if it is still waiting for a slot. */
	function cancelStart(id:Null<String>):Void {
		var actions = machine, entry = id == null ? null : model.workspaces.get(id);
		var cancel = actions == null ? null : actions.cancelStart;
		if (cancel != null && entry != null) cancel(entry);
	}

	function startWorkspace(id:String):Void {
		var actions = machine, entry = model.workspaces.get(id);
		if (actions != null && entry != null) actions.start(entry);
	}

	/** The menu of a row of another workspace: open the workspace here, which is what opening its items does too. */
	function foreignMenu(key:String, event:UiEvent):Void {
		var row = WorkbenchRowKey.parseForeign(key);
		var actions = machine;
		if (row == null || actions == null) return;
		var entry = model.workspaces.get(row.workspace);
		if (entry == null) return;
		var target = entry;
		var items = [new MenuItem("machine-workspace-open", "Open Workspace", function() actions.open(target), true)];
		var newWindow = actions.openInNewWindow;
		if (newWindow != null) items.push(new MenuItem("machine-workspace-new-window", row.kind == WorkbenchRowKind.Group ? "Open Group in New Window" : "Open in New Window", function() newWindow(target, row.kind == WorkbenchRowKind.Group ? row.id : null), true));
		var owner = row.workspace;
		showMenu(items, event, function() return model.workspaces.exists(owner));
	}

	/** The workspace a recent open asked for and when: Enter and a double click can both activate one row. */
	var lastOpenId:Null<String>;
	var lastOpenAt:Float = 0;
	static inline final OPEN_REPEAT_SECONDS = 2.0;

	/** Opens the workspace here, once: a repeat of the same request within a moment (a double activation) is dropped. */
	function openWorkspace(id:String):Void {
		var actions = machine, entry = model.workspaces.get(id);
		if (actions == null || entry == null) return;
		var now = Sys.time();
		if (lastOpenId == id && now - lastOpenAt < OPEN_REPEAT_SECONDS) return;
		lastOpenId = id; lastOpenAt = now;
		actions.open(entry);
	}

	function createWorkspace():Void {
		var actions = machine;
		if (actions != null && !actions.busy()) actions.create();
	}

	/** The menu of a machine row: a workspace's own actions, then New Workspace…. */
	function machineMenu(key:String, event:UiEvent):Void {
		var actions = machine;
		if (actions == null) return;
		var id = WorkbenchRowKey.workspaceId(key);
		var entry = id == null ? null : model.workspaces.get(id);
		var idle = !actions.busy();
		var items:Array<MenuItem> = [];
		if (entry != null) {
			var target = entry;
			items.push(new MenuItem("machine-workspace-open", "Open", function() actions.open(target), key != model.openRow));
			var newWindow = actions.openInNewWindow;
			if (newWindow != null) items.push(new MenuItem("machine-workspace-new-window", "Open in New Window", function() newWindow(target, null), true));
			var watching = watched(), state = watching == null ? null : watching.get(target.id);
			if (state != null && !state.running && !state.starting && key != model.openRow)
				items.push(new MenuItem("machine-workspace-start", "Start Service", function() actions.start(target), idle));
			if (key == model.groupParent) {
				// Sessions and terminals made here sit in the workspace root, in no group.
				if (canCreateAgent())
					items.push(new MenuItem("new-agent", "New Agent Session…", function() { edit(null, "new-agent"); }, true, null, true));
				if (client.canCreateGroupedTerminals())
					items.push(new MenuItem("new-terminal", "New Terminal…", function() { edit(null, "new-terminal"); }, !client.terminalCatalogBusy()));
			}
			items.push(new MenuItem("machine-workspace-rename", "Rename…", function() actions.rename(target), idle, "F2", true));
			items.push(new MenuItem("machine-workspace-attach-folder", "Attach Folder…", function() actions.attachFolder(target), idle));
			items.push(new MenuItem("machine-workspace-detach-folder", "Detach Folder…", function() actions.detachFolder(target), idle && target.folders.length > 0));
			items.push(new MenuItem("machine-workspace-remove", "Remove from This Machine", function() actions.remove(target), idle, null, true));
		}
		items.push(new MenuItem("machine-new-workspace", "New Workspace…", function() actions.create(), idle, null, entry != null));
		showMenu(items, event, function() {
			if (id == null) return true;
			var state = actions.view().machine;
			return state != null && Lambda.exists(state.workspaces, function(candidate) return candidate.id == id);
		});
	}

	/** Asked on every hover, so it only answers. */
	function canDragNode(key:String):Bool
		return canDragRow(key);

	function canDragRow(key:String):Bool {
		if (draft != null || agentDraft != null || pending || client.terminalCatalogBusy()) return false;
		var row = WorkbenchRowKey.parse(key);
		if (row == null) return false;
		return switch row.kind {
			case WorkbenchRowKind.Group: client.canEditGroups() && model.groups.exists(row.id);
			case WorkbenchRowKind.Terminal: client.canControlTerminals() && model.terminals.exists(row.id);
			case WorkbenchRowKind.Agent: client.agentService().canControlAgents() && !client.agentService().agentBusy() && model.agents.exists(row.id);
		};
	}

	/** Whether the pointer is over the middle of `target` now; only that moves a row into it, the edges place it between rows. */
	function canDropNode(source:String, target:String):Bool
		return rowZone(target) == WorkbenchDropZone.Into && canMoveInto(source, target);

	/** Whether `source` may move into `target` by the live catalog, permissions and mutation state; says nothing of the pointer. */
	function canMoveInto(source:String, target:String):Bool {
		var catalog = client.terminalCatalog();
		if (catalog == null || catalog.instance != observedWorkspaceInstance || catalog.workspaceRoot != observedWorkspaceRoot
			|| !canDragRow(source)) return false;
		return WorkbenchDropRules.canDrop(source, target, catalog, client.agentService().agents(), model.groupParent);
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
		var catalog = client.terminalCatalog(), hit = model.rowAt(y);
		if (!client.canReorder() || catalog == null || hit == null || catalog.instance != observedWorkspaceInstance || catalog.workspaceRoot != observedWorkspaceRoot
			|| !canDragRow(source)) return null;
		var row = WorkbenchRowKey.parse(hit.key);
		if (row == null) return null;
		var zone = WorkbenchDropRules.zone(y - hit.centre, WorkbenchSessionLabel.ROW_HEIGHT, row.kind == WorkbenchRowKind.Group);
		if (zone == WorkbenchDropZone.Into) return null;
		var anchor = hit.key, after = zone == WorkbenchDropZone.After;
		if (after && row.kind == WorkbenchRowKind.Group && tree.isExpanded(hit.key)) {
			// The lower edge of an open group is the upper edge of its first row.
			var inside = model.siblings(row.id);
			if (inside.length > 0) { anchor = inside[0]; after = false; }
		}
		return WorkbenchOrder.plan(model, catalog, client.agentService().agents(), dragKeys(source), anchor, after, canWriteRow);
	}

	/** Whether this client can write `key`'s group or position now; a write it cannot make is dropped silently by the client. */
	function canWriteRow(key:String):Bool {
		var catalog = client.terminalCatalog(), row = WorkbenchRowKey.parse(key);
		if (catalog == null || row == null) return false;
		return switch row.kind {
			case WorkbenchRowKind.Group: client.canEditGroups() && model.groups.exists(row.id);
			case WorkbenchRowKind.Terminal:
				var terminal = model.terminals.get(row.id);
				client.canControlTerminals() && terminal != null && terminal.workspaceRoot == catalog.workspaceRoot;
			case WorkbenchRowKind.Agent:
				var service = client.agentService(), agents = service.agents();
				service.canControlAgents() && agents != null && agents.canMove == true && agents.instance == catalog.instance
					&& agents.root == catalog.workspaceRoot && model.agents.exists(row.id);
		};
	}

	/** Alt+Up and Alt+Down move the selected row one place among its siblings. */
	function nudge(delta:Int):Bool {
		var key = tree.selectedKey, catalog = client.terminalCatalog();
		if (key == null || catalog == null || !client.canReorder() || !batchIdle() || !canDragRow(key) || tree.selectedKeys().length != 1) return false;
		var group = model.groupOfRow(key);
		if (group == null) return false;
		var siblings = model.siblings(group), at = siblings.indexOf(key), to = at + delta;
		if (at < 0 || to < 0 || to >= siblings.length) return false;
		var plan = WorkbenchOrder.plan(model, catalog, client.agentService().agents(), [key], siblings[to], delta > 0, canWriteRow);
		if (plan == null) return false;
		if (plan.refusal != null) { reportError(plan.refusal); return true; }
		startPlan(plan.steps);
		return true;
	}

	function startPlan(steps:Array<PlaceStep>):Void {
		var catalog = client.terminalCatalog();
		if (catalog == null || steps.length == 0 || batchKeys.length > 0 || batchPlan.length > 0) return;
		batchPlan = steps.copy(); batchOwner = catalog.instance;
		batchTerminalError = client.terminalCatalogError(); batchAgentError = client.agentService().agentError();
		runBatch();
	}

	/** Writes one step of a placement against the catalogs as they are now. */
	function placeNode(step:PlaceStep):Void {
		var catalog = client.terminalCatalog(), row = WorkbenchRowKey.parse(step.key);
		if (catalog == null || row == null) return;
		var id = row.id;
		switch row.kind {
			case WorkbenchRowKind.Group:
				for (group in catalog.groups) if (group.id == id)
					client.changeGroup(catalog.instance, group, group.name, WorkspaceProtocol.parentFor(step.group), group.cwd, step.order, false);
			case WorkbenchRowKind.Terminal:
				for (terminal in catalog.terminals) if (terminal.id == id) client.renameTerminal(terminal, terminal.name, step.group, step.order);
			case WorkbenchRowKind.Agent:
				var agents = client.agentService().agents();
				if (agents == null) return;
				for (agent in agents.records) if (agent.id == id)
					client.agentService().agentAction(id, "move", step.group, agent.group, null, null, null, null, null, step.order);
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
		var catalog = client.terminalCatalog();
		if (catalog == null) return;
		// A group id, or the workspace root for the open workspace's row.
		var into = WorkbenchDropRules.destination(target, model.groupParent), row = WorkbenchRowKey.parse(source);
		if (into == null || row == null) return;
		var id = row.id, parent = WorkspaceProtocol.parentFor(into);
		switch row.kind {
			case WorkbenchRowKind.Group:
				for (group in catalog.groups) if (group.id == id)
					client.changeGroup(catalog.instance, group, group.name, parent, group.cwd, model.nextOrder(parent), false);
			case WorkbenchRowKind.Terminal:
				for (terminal in catalog.terminals) if (terminal.id == id) client.renameTerminal(terminal, terminal.name, into, model.nextOrder(parent));
			case WorkbenchRowKind.Agent:
				var agents = client.agentService().agents();
				if (agents == null) return;
				for (agent in agents.records) if (agent.id == id)
					client.agentService().agentAction(id, "move", into, agent.group, null, null, null, null, null, model.nextOrder(parent));
		}
	}

	/** A moved group carries its contents, so selected rows inside a selected group stay where they are. */
	function outermost(keys:Array<String>):Array<String> {
		var selected = [for (key in keys) key => true];
		return keys.filter(function(key) {
			var visited:Map<String, Bool> = [];
			var parent = WorkbenchRowKey.parentGroupId(model, key);
			while (parent != null && !visited.exists(parent)) {
				if (selected.exists(WorkbenchRowKey.group(parent))) return false;
				visited.set(parent, true);
				var group = model.groups.get(parent);
				parent = group == null ? null : group.parent;
			}
			return true;
		});
	}

	/** Selected terminals and agent sessions that can be closed or removed now. */
	function removableKeys(keys:Array<String>):Array<String> {
		return keys.filter(function(key) {
			var row = WorkbenchRowKey.parse(key);
			if (row == null) return false;
			return switch row.kind {
				case WorkbenchRowKind.Terminal: closeTerminal != null && client.canControlTerminals() && model.terminals.exists(row.id);
				case WorkbenchRowKind.Agent: client.agentService().canControlAgents() && agentCanBeRemoved(model.agents.get(row.id));
				case WorkbenchRowKind.Group: false;
			};
		});
	}

	function removeNode(key:String):Void {
		var row = WorkbenchRowKey.parse(key);
		if (row == null || row.kind == WorkbenchRowKind.Group) return;
		if (row.kind == WorkbenchRowKind.Agent) { removeAgent(row.id, false); return; }
		var catalog = client.terminalCatalog(), close = closeTerminal;
		if (catalog == null || close == null) return;
		for (terminal in catalog.terminals) if (terminal.id == row.id) { close(terminal); return; }
	}

	function batchIdle():Bool
		return batchKeys.length == 0 && batchPlan.length == 0 && !client.terminalCatalogBusy() && !client.agentService().agentBusy();

	/** Removes (null target) or moves rows in order, each against the catalog current at its turn. */
	function startBatch(keys:Array<String>, target:Null<String>):Void {
		var catalog = client.terminalCatalog();
		if (catalog == null || keys.length == 0 || batchKeys.length > 0) return;
		batchKeys = keys.copy(); batchTarget = target; batchOwner = catalog.instance;
		batchTerminalError = client.terminalCatalogError(); batchAgentError = client.agentService().agentError();
		runBatch();
	}

	function runBatch():Void {
		if (batchKeys.length == 0 && batchPlan.length == 0) return;
		var catalog = client.terminalCatalog(), service = client.agentService();
		if (catalog == null || catalog.instance != batchOwner) { batchKeys = []; batchPlan = []; return; }
		if (client.terminalCatalogBusy() || service.agentBusy()) return;
		// A failed step stops the rest; the panel already reports its error.
		var terminalError = client.terminalCatalogError(), agentError = service.agentError();
		if ((terminalError != null && terminalError != batchTerminalError) || (agentError != null && agentError != batchAgentError)) {
			batchKeys = []; batchPlan = []; return;
		}
		batchTerminalError = terminalError; batchAgentError = agentError;
		if (batchPlan.length > 0) {
			placeNode(batchPlan.shift());
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
		var catalog = client.terminalCatalog();
		var owner = catalog == null ? "" : catalog.instance;
		var removable = removableKeys(keys);
		var items = [new MenuItem("selection-count", keys.length + " items selected", null, false)];
		if (removable.length > 0)
			items.push(new MenuItem("close-selection", closeSelectionLabel(keys, removable), function() startBatch(removable, null), batchIdle()));
		showMenu(items, event, function() {
			var current = client.terminalCatalog();
			return current != null && current.instance == owner;
		});
	}

	function reportError(message:String):Void {
		var handler = onError;
		if (handler != null) handler(message);
	}

	public function selectedGroupId():Null<String> {
		var group = groupFor(tree.selectedKey);
		return group == null ? null : group.id;
	}

	/** The selected row's group: a group row's own, a session's or terminal's; null for the workspace root or no row. */
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

	function menu(group:Null<WorkspaceGroup>, event:UiEvent, ?key:String, ?overflow:Array<MenuItem>):Void {
		if (key != null && tree.isSelected(key)) {
			var selection = tree.selectedKeys();
			if (selection.length > 1) { selectionMenu(selection, event); return; }
		}
		var catalog = client.terminalCatalog();
		var owner = catalog == null ? "" : catalog.instance;
		var valid = function() {
			var current = client.terminalCatalog();
			if (current == null || current.instance != owner) return false;
			if (group == null) return true;
			for (candidate in current.groups) if (candidate.id == group.id) return candidate.revision == group.revision;
			return false;
		};
		var editable = client.canEditGroups() && !client.terminalCatalogBusy();
		var cwd = group == null ? null : model.directory(group);
        var groupId = group == null ? "" : group.id;
        var items:Array<MenuItem> = [];
        var terminalId = WorkbenchRowKey.idOf(key, WorkbenchRowKind.Terminal);
        if (terminalId != null) {
            var terminal = model.terminals.get(terminalId);
            if (terminal != null) {
                var terminalValid = function() {
                    if (!valid()) return false;
                    var current = client.terminalCatalog();
                    if (current == null) return false;
                    for (candidate in current.terminals) if (candidate.id == terminal.id)
                        return candidate.instance == terminal.instance && haxe.Int64.compare(candidate.revision, terminal.revision) == 0;
                    return false;
                };
                showMenu(terminalActions(terminal), event, terminalValid);
                return;
            }
        }
		var agentId = WorkbenchRowKey.idOf(key, WorkbenchRowKind.Agent);
		if (agentId != null) {
			var agent = model.agents.get(agentId);
			if (agent == null) return;
			items.push(new MenuItem("open-codex", "Open agent session", function() openAgent(agent.id)));
			var nativeName = canRenameNative(agent.id);
			var canRename = client.agentService().canControlAgents() && !client.agentService().agentBusy() && !pending && !agentPending;
			items.push(new MenuItem("rename-agent", nativeName ? "Rename session…" : "Rename in Workbench…",
				function() beginAgentRename(agent.id,nativeName), canRename, "F2"));
			if(nativeName) items.push(new MenuItem("rename-agent-label", "Rename in Workbench…",
				function() beginAgentRename(agent.id,false),canRename));
			var move = moveAgent;
			if (move != null && client.agentService().canControlAgents())
				items.push(new MenuItem("move-agent", "Move to Group…", function() { move(agent); }, !client.agentService().agentBusy()));
			if (client.agentService().canControlAgents() && agentCanBeRemoved(agent))
				items.push(new MenuItem("delete-codex-leaf", "Remove from Workbench", function() removeAgent(agent.id), !client.agentService().agentBusy()));
			showMenu(items, event, valid);
			return;
		}
		// Without a group (no row selected), they create at the workspace root.
		if (canCreateAgent()) items.push(new MenuItem("new-agent", "New Agent Session…", function() { edit(group, "new-agent"); }));
		if (client.canCreateGroupedTerminals()) items.push(new MenuItem("new-terminal", "New Terminal…", function() { edit(group, "new-terminal"); }, !client.terminalCatalogBusy()));
		if (client.canEditGroups()) {
			items.push(new MenuItem("new-group", "New group", function() beginGroup({id: workspace.client.WorkspaceIds.create("group"),
				name: "", cwd: null, revision: 0, parent: group == null ? null : group.id,
				order: model.nextOrder(group == null ? null : group.id)}, true), editable && !pending));
			if (group != null) {
				items.push(new MenuItem("rename-group", "Rename group", function() beginGroup(group, false), editable && !pending, null, true));
				items.push(new MenuItem("group-directory", "Change Working Directory…", function() edit(group, "directory"), editable));
				if (GroupContextActions.canInherit(group))
					items.push(new MenuItem("group-inherit", "Use Inherited Working Directory", function() edit(group, "inherit"), editable));
				var moveSeparator = true;
				if (catalog != null && GroupContextActions.canMove(group, catalog.groups)) {
					items.push(new MenuItem("group-parent", "Move to Group…", function() edit(group, "parent"), editable, null, true));
					moveSeparator = false;
				}
				items.push(new MenuItem("group-order", "Change Sort Order…", function() edit(group, "order"), editable, null, moveSeparator));
			}
		}
		if (cwd != null && group != null) items.push(new MenuItem("open-folder", "Open folder", function() openFolder(group), true, null, true));
		var groupOwner = model.groupWorkspace(), newWindow = machine == null ? null : machine.openInNewWindow;
		if (group != null && groupOwner != null && newWindow != null)
			items.push(new MenuItem("group-new-window", "Open in New Window", function() newWindow(groupOwner, group.id), true));
		if (group != null && client.agentService().canControlAgents())
			items.push(new MenuItem("attach-codex", "Attach existing Codex thread…", function() attach(group)));
		// Shown whenever the service can remove groups; disabled, with the reason, while this one still has contents.
		var removal = group == null ? GroupRemoval.NotPermitted : GroupContextActions.removal(group, client);
		if (group != null && removal != GroupRemoval.NotPermitted)
			items.push(new MenuItem("group-remove", GroupContextActions.removeLabel(removal), function() edit(group, "remove"),
				editable && removal == GroupRemoval.Allowed, null, true));
		if (key == null) {
			items.push(new MenuItem("refresh", "Refresh Workbench", function() {
				if (client.canReadTerminals()) client.refreshTerminals(true);
				if (client.agentService().canReadAgents()) client.agentService().refreshAgents();
			}, client.canReadTerminals() || client.agentService().canReadAgents(), null, true));
		}
		if (overflow != null) for (item in overflow) items.push(item);
		showMenu(items, event, valid);
	}

	function removeAgent(id:String, select:Bool = true):Void {
		var agent = model.agents.get(id);
		if (agent == null || !agentCanBeRemoved(agent) || !client.agentService().canControlAgents() || client.agentService().agentBusy()) return;
		if (select) tree.select(WorkbenchRowKey.agent(id));
		var group = agent.group;
		client.agentService().deleteAgent(id, function() {
			closeAgentTab(id, agent.workspaceRoot);
			if (select && model.groups.exists(group)) tree.select(WorkbenchRowKey.group(group));
			requestFrame();
		});
		requestFrame();
	}

    function beginGroup(group:WorkspaceGroup, create:Bool):Void {
        var catalog = client.terminalCatalog();
        if (catalog == null || !client.canEditGroups() || pending || agentPending) return;
        cancelAgentRename();
        draft = group; creating = create; draftName = group.name;
        draftOwner = catalog.instance; draftError = null;
        inlineEditor = new WorkbenchNameEditor(group.id, draftName, function(value) draftName = value, saveGroup, cancelGroup);
        var actions = machine;
        model.update(catalog, client.agentService().agents(), creating ? draft : null, actions == null ? null : actions.view());
        revealNode(WorkbenchRowKey.group(group.id));
        applyPendingReveal();
        requestFrame();
    }

    /** Catalog delivery may follow creation; reveal only once the node exists. */
    public function revealNode(key:String):Void {
        pendingReveal = key;
        var catalog = client.terminalCatalog();
        revealRoot = catalog == null ? null : catalog.workspaceRoot;
        requestFrame();
    }

    /** Keep the tree aligned with either kind of service-owned session tab. */
    public function syncActiveSession(key:Null<String>, workspaceRoot:Null<String>):Void {
        if (key == null || workspaceRoot == null) {
            pendingSessionSelection = null;
            return;
        }
        if (tree.selectedKey == key) {
            pendingSessionSelection = null;
            return;
        }
        if (pendingSessionSelection != null && pendingSessionSelection.key == key
            && pendingSessionSelection.workspaceRoot == workspaceRoot) return;
        pendingSessionSelection = {key: key, workspaceRoot: workspaceRoot};
        requestFrame();
    }

    /** Discard a delayed tab-to-tree sync when the workspace attachment changes. */
    public function workspaceAttachmentChanged():Void {
        tree.cancelDrag();
        agentPending = false; cancelAgentRename();
        pendingSessionSelection = null;
        var scrolled = WorkbenchRowKey.parse(scrollTarget);
        if (scrolled != null && scrolled.kind != WorkbenchRowKind.Group) scrollTarget = null;
    }

    function applyPendingSessionSelection():Void {
        var target = pendingSessionSelection;
        if (target == null) return;
        var terminalCatalog = client.terminalCatalog();
        if (terminalCatalog == null || terminalCatalog.workspaceRoot != target.workspaceRoot) return;
        if (!WorkbenchRowKey.isKind(target.key, WorkbenchRowKind.Terminal)) {
            var agentCatalog=client.agentService().agents();
            if(agentCatalog == null || agentCatalog.root != target.workspaceRoot) return;
        }
        var group = WorkbenchRowKey.groupOf(model, target.key);
        if (group == null || !expandAncestors(group.id)) return;
        if (tree.selectedKey != target.key) {
            tree.select(target.key);
            scrollTarget = target.key;
            scrollPasses = 2;
        }
        pendingSessionSelection = null;
    }

    /** Expands `groupId` and every group above it so a row inside shows; false when the chain is broken. */
    function expandAncestors(groupId:Null<String>):Bool {
        // Nested under the open workspace, the groups show only while it is expanded.
        var nesting = model.groupParent;
        if (nesting != null) tree.setExpanded(nesting, true);
        var ancestors:Array<String> = [];
        var visited:Map<String, Bool> = [];
        var parent = groupId;
        while (parent != null && !visited.exists(parent)) {
            visited.set(parent, true);
            ancestors.unshift(WorkbenchRowKey.group(parent));
            var ancestor = model.groups.get(parent);
            if (ancestor == null) return false;
            parent = ancestor.parent;
        }
        for (ancestor in ancestors) tree.setExpanded(ancestor, true);
        return true;
    }

    function applyPendingReveal():Void {
        var key = pendingReveal;
        if (key == null) return;
        var catalog = client.terminalCatalog();
        if (catalog == null) return;
        if (catalog.workspaceRoot != revealRoot) { pendingReveal = null; return; }
        var group = WorkbenchRowKey.groupOf(model, key);
        if (group == null || !expandAncestors(WorkbenchRowKey.isKind(key, WorkbenchRowKind.Group) ? group.parent : group.id)) return;
        tree.select(key);
        scrollTarget = key;
        scrollPasses = 2;
        pendingReveal = null;
    }

	function canRenameNative(id:String):Bool {
		var catalog=client.agentService().agents();
		if(catalog==null || catalog.nativeRenameProviders==null) return false;
		for(record in catalog.records) if(record.id==id) return record.thread!="" && catalog.nativeRenameProviders.indexOf(record.provider==null ? "codex" : record.provider)>=0;
		return false;
	}

	function beginAgentRename(id:String,nativeName:Bool=false,inspected:Bool=false):Void {
		var service = client.agentService(), catalog = service.agents();
		if (catalog == null || draft != null || pending || agentPending || !service.canControlAgents() || service.agentBusy()) return;
		if (catalog.canRename != true) {
			reportError("Update the workspace service in Remote Access to rename agent sessions. Restarting the app does not update a service with active sessions.");
			return;
		}
		var record:Null<AgentRecord> = null;
		for (candidate in catalog.records) if (candidate.id == id) record = candidate;
		if (record == null || catalog.root != observedWorkspaceRoot || catalog.instance != observedWorkspaceInstance) return;
		if(nativeName && !canRenameNative(id)) {reportError("Native renaming is no longer available. Reopen the session menu.");return;}
		if(nativeName && !inspected) {
			var owner=catalog.instance,root=catalog.root;
			service.agentAction(id,"inspect-name","",null,null,null,function() {
				var current=service.agents();
				if(current!=null && current.instance==owner && current.root==root) beginAgentRename(id,true,true);
			});
			requestFrame();return;
		}
		if(nativeName && record.nameMetadata==null) {reportError("Refresh the native session name before renaming.");return;}
		agentDraft = record; agentDraftOwner = catalog.instance; agentRenameNative=nativeName;
		var naming=record.nameMetadata;
		agentDraftName = nativeName && naming!=null && naming.nativeName!=null ? naming.nativeName : record.name;
		agentEditor = new WorkbenchNameEditor(id, agentDraftName, function(value) agentDraftName = value,
			saveAgentName, cancelAgentRename, "agent",nativeName ? "Session name" : "Workbench label");
		agentEditor.onBlur = function() finishAgentRename(false);
		refreshModel = true; revealNode(WorkbenchRowKey.agent(id)); requestFrame();
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
		var base = agentDraft;
		var service = client.agentService(), catalog = service.agents();
		if (base == null || agentPending || service.agentBusy() || !service.canControlAgents()) return;
		var name = workspace.service.AgentNames.normalize(agentDraftName);
		if (name == null) {reportError("Enter a session name of 1–256 characters without line breaks or control characters.");return;}
		if (catalog == null || catalog.instance != agentDraftOwner || catalog.root != base.workspaceRoot) {
			reportError("The workspace changed. Cancel and try again.");return;
		}
		if (name == base.name && !agentRenameNative) {cancelAgentRename();return;}
		agentPending = true;
		var metadata=base.nameMetadata;
		service.agentAction(base.id, agentRenameNative ? "rename-native" : "rename", name, base.name, null, null, function() {
			if (agentDraft != base) return;
			agentPending = false; cancelAgentRename();
		},agentRenameNative && metadata!=null ? metadata.nativeName : null);
		requestFrame();
	}

    function cancelGroup():Void {
        if (pending) return;
        draft = null; inlineEditor = null; draftError = null;
        refreshModel = true; requestFrame();
    }

    function saveGroup():Void {
        var base = draft;
        if (base == null || pending || client.terminalCatalogBusy()) return;
        var name = StringTools.trim(draftName);
        if (name == "") { draftError = "Enter a group name."; requestFrame(); return; }
        var catalog = client.terminalCatalog();
        if (catalog == null || catalog.instance != draftOwner) {
            draftError = "The workspace changed. Cancel and try again."; requestFrame(); return;
        }
        draftName = name; draftError = null; pending = true; pendingSince = Sys.time();
        client.changeGroup(draftOwner, base, name, base.parent, base.cwd, WorkspaceProtocol.order(base.order), creating);
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
        var catalog:Null<TerminalCatalog> = client.terminalCatalog();
        var currentRoot = catalog == null ? null : catalog.workspaceRoot;
        if (currentRoot != null && catalog != null) {
            if (observedWorkspaceRoot != null && (observedWorkspaceRoot != currentRoot || observedWorkspaceInstance != catalog.instance)) workspaceAttachmentChanged();
            observedWorkspaceRoot = currentRoot;
            observedWorkspaceInstance = catalog.instance;
        }
        if (pending && !client.terminalCatalogBusy()) {
            var saved = false;
            var base = draft;
            if (catalog != null && catalog.instance == draftOwner && base != null)
                for (group in catalog.groups) if (group.id == base.id && group.name == draftName && group.revision > base.revision) saved = true;
            if (saved) { pending = false; cancelGroup(); if (base != null) revealNode(WorkbenchRowKey.group(base.id)); }
            else if (client.terminalCatalogError() != null || Sys.time() - pendingSince > 10) {
                pending = false;
                draftError = client.terminalCatalogError() == null ? "Could not confirm the save. Refresh before retrying." : client.terminalCatalogError();
            }
        }
        if (inlineEditor != null) inlineEditor.enabled = !pending;
		if (agentPending && !client.agentService().agentBusy()) agentPending = false;
		if (agentEditor != null) agentEditor.enabled = !agentPending;
		var agents = client.agentService().agents();
		if (agents != null && (catalog == null || agents.root != catalog.workspaceRoot)) agents = null;
		var nextAgentKey = client.agentService().agentRevision();
		var actions = machine;
		var view = actions == null ? null : actions.view();
		// What the machine rows depend on besides catalogs, and the catalogs' revision: a catalog change alone can wait a moment.
		var nextStructure = view == null ? "" : view.revision + "\n" + view.openWorkspace + "\n" + view.openRoots.join("\n") + "\n" + expandRevision;
		var nextMachineKey = view == null ? "" : nextStructure + "\n" + view.watchRevision;
		if (catalog != null) retainedCatalog = catalog;
		// Keep the last projection during transport recovery so TreeView does not
		// discard its selection, expansion and scroll state for an empty catalog.
		// The machine rows show without a catalog; the last one stays under its workspace meanwhile.
		var shown = catalog != null ? catalog : view != null ? retainedCatalog : null;
		var now = Sys.time();
		var machineDue = view != null && throttle.due(nextStructure, nextMachineKey, now);
		if (throttle.waiting) requestFrame();
		if ((catalog != null && (refreshModel || catalogRevision != client.terminalCatalogRevision() || nextAgentKey != agentKey))
			|| machineDue || (view == null && throttle.key != "")) {
            refreshModel = false; throttle.took(nextStructure, nextMachineKey, now);
			model.expandedRows = expandedWorkspaces;
			catalogRevision = client.terminalCatalogRevision(); agentKey = nextAgentKey;
			if (retainedAgents != null && shown != null && (retainedAgents.root != shown.workspaceRoot
				|| (client.canReadTerminals() && !client.agentService().canReadAgents()))) retainedAgents = null;
			if (agents != null) retainedAgents = agents;
			model.update(shown, retainedAgents, creating ? draft : null, view);
			followOpenWorkspace();
		}
		// Each frame, not only when the tree changed: the wish times out on its own.
		resolveForeign();
        applyPendingReveal();
		applyPendingSessionSelection();
		runBatch();
    }

	/** When this window opens another workspace, the previous one collapses and the new one expands. */
	function followOpenWorkspace():Void {
		var open = model.openRow;
		if (open == observedOpenRow) return;
		var previous = observedOpenRow;
		observedOpenRow = open;
		if (previous != null) tree.setExpanded(previous, false);
		if (open != null) tree.setExpanded(open, true);
	}

	public function headerActions(availableWidth:Float = 260):View return new WorkbenchHeaderActions(this, availableWidth);

	public function buildHeaderActions(context:BuildContext, availableWidth:Float):RenderNode {
		syncState();
		var selected = groupFor(tree.selectedKey), into = createTarget(tree.selectedKey);
		var terminal = toolbarButton("New terminal", IconName.Terminal, function() {
			createTerminal(into);
		}, "workbench-new-terminal");
		terminal.enabled = client.canCreateGroupedTerminals() && !client.terminalCatalogBusy();
		var agent = toolbarButton("New Codex", IconName.Plus, function() {
			createProvider("codex", into);
		}, "workbench-new-codex");
		agent.enabled = canCreateAgent();
		var selectedAgentId = WorkbenchRowKey.idOf(tree.selectedKey, WorkbenchRowKind.Agent);
		var selectedAgent = selectedAgentId == null ? null : model.agents.get(selectedAgentId);
		var selection = tree.selectedKeys();
		var multiple = selection.length > 1;
		var removable = multiple ? removableKeys(selection) : [];
		var removeSelected = function() {
			if (multiple) startBatch(removable, null);
			else if (selectedAgent != null) removeAgent(selectedAgent.id);
		};
		var deleteAgent = toolbarButton("Remove selected leaf from Workbench", IconName.Trash, removeSelected, "workbench-delete-codex");
		deleteAgent.enabled = multiple ? removable.length > 0 && batchIdle()
			: agentCanBeRemoved(selectedAgent) && client.agentService().canControlAgents() && !client.agentService().agentBusy();
		var overflow:Array<MenuItem> = [];
		if (availableWidth < 210) overflow.push(new MenuItem("new-codex", "New Codex", function() {
			createProvider("codex", into);
		}, agent.enabled));
		if (availableWidth < 260 && (selectedAgent != null || multiple))
			overflow.push(new MenuItem("delete-selected-agent", multiple ? closeSelectionLabel(selection, removable) : "Remove from Workbench",
				removeSelected, deleteAgent.enabled));
		var more = toolbarButton("Workbench actions", IconName.ChevronDown, null, "workbench-actions");
		more.onClickEvent = function(event) menu(selected, event, null, overflow);
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
		if (availableWidth >= 170) actions.push(new KeyedView("terminal", tip("new-terminal-tip", terminal, !client.canReadTerminals() ? "Connect to a workspace with terminal read permission"
				: !client.canControlTerminals() ? "Terminal creation requires terminal control permission"
				: !client.canCreateGroupedTerminals() ? "This workspace does not support grouped terminals" : "New terminal")));
		if (availableWidth >= 210) actions.push(new KeyedView("agent", tip("new-agent-tip", agent, "New Codex")));
		if (availableWidth >= 260) actions.push(new KeyedView("delete-agent", tip("delete-agent-tip", deleteAgent, "Remove from Workbench")));
		actions.push(new KeyedView("more", tip("workbench-actions-tip", more, "Actions")));
		return new Row("workbench-header-actions", actions, toolbarStyle).build(context);
	}

	/** No group, terminal or session anywhere in the workspace: sessions and terminals in the workspace root count too. */
	public static function workspaceIsEmpty(catalog:Null<TerminalCatalog>, agents:Null<WorkspaceAgentProtocol.AgentCatalog>):Bool {
		if (catalog == null || catalog.groups.length != 0 || catalog.terminals.length != 0) return false;
		return agents == null || agents.records.length == 0;
	}

	/** Whether the "Nothing here yet" start is on screen (a test seam for the automation snapshot). */
	public function showsEmptyState():Bool {
		var start = emptyState();
		return start != null && workspaceIsEmpty(client.terminalCatalog(), client.agentService().agents());
	}

	/** What to do first when the Workbench has nothing: open a folder, or make the first group. */
	function emptyState():Null<View> {
		var catalog = client.terminalCatalog();
		var choose = chooseFolder, folder = hasFolder;
		var style = new LayoutStyle(); style.width = LayoutAxis.stretch(); style.childGap = 8; style.padding = new Insets(12, 8, 12, 8);
		var hint = haxeon.ui.core.TextStyleOverride.text(12);
		if (catalog == null && machine == null && choose != null && folder != null && !folder()) {
			var button = new Button("Open Folder…", null, function() choose(), "workbench-open-folder");
			button.variant = ButtonVariant.Primary;
			return new Column("workbench-empty", [
				new KeyedView("text", new Text("Open a folder to start. Its groups, sessions and terminals appear here.", null, null, hint)),
				new KeyedView("open", button)
			], style);
		}
		if (workspaceIsEmpty(catalog, client.agentService().agents()) && draft == null && client.canEditGroups()) {
			var button = new Button("New group", null, function() beginGroup({id: workspace.client.WorkspaceIds.create("group"),
				name: "", cwd: null, revision: 0, parent: null, order: model.nextOrder(null)}, true), "workbench-first-group");
			button.variant = ButtonVariant.Primary;
			button.enabled = !pending;
			return new Column("workbench-empty", [
				new KeyedView("text", new Text("Nothing here yet. Sessions and terminals go in the workspace; groups sort them.", null, null, hint)),
				new KeyedView("new", button)
			], style);
		}
		return null;
	}

	public function build(context:BuildContext):RenderNode {
		syncState();
		var selected = groupFor(tree.selectedKey);
		var rows:Array<KeyedView> = [];
		var machineActions = machine;
		// With suit on, the machine is chosen above the tree; this machine is the only choice for now.
		if (machineActions != null)
			rows.push(new KeyedView("machine", new WorkbenchMachineSelector(machineActions.view(), function(_) {})));
		rows.push(new KeyedView("tree", tree));
		var start = emptyState();
		if (start != null) rows.push(new KeyedView("empty-state", start));
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
            startPlan(placement.steps);
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
				var key = tree.selectedKey, agentId = WorkbenchRowKey.idOf(key, WorkbenchRowKind.Agent);
				var workspaceId = WorkbenchRowKey.workspaceId(key), actions = machine;
				var renamed = workspaceId == null ? null : model.workspaces.get(workspaceId);
				if (renamed != null && actions != null) {
					event.preventDefault(); event.stopPropagation();
					if (!actions.busy()) actions.rename(renamed);
				} else if (agentId != null) {
					event.preventDefault(); event.stopPropagation(); beginAgentRename(agentId, canRenameNative(agentId));
				} else if (WorkbenchRowKey.isKind(key, WorkbenchRowKind.Group) && selected != null && client.canEditGroups()) {
					event.preventDefault(); event.stopPropagation(); beginGroup(selected, false);
				}
            }
        }, "capture");
        node.on(haxeon.ui.core.UiEventKind.PointerDown, function(event) {
            if (event.button == 1 && !event.defaultPrevented) {
                event.preventDefault(); event.stopPropagation(); menu(null, event);
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
