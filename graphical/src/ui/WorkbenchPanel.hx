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
	final edit:(WorkspaceGroup, String)->Void;
	final openFolder:String->Void;
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
	/** Closes a catalog terminal and its views; selection actions use it. */
	public var closeTerminal:Null<TerminalRecord->Void>;
	/** This machine and its workspaces, above the groups; null when suit is off. */
	public var machineSection:Null<View>;
	/** Opens a folder picker; with `hasFolder` and no machine section, the empty Workbench offers it when no folder is open. */
	public var chooseFolder:Null<Void->Void>;
	public var hasFolder:Null<Void->Bool>;
	var lastReportedError:Null<String>;
	// Selection actions run one step at a time: the service drops a mutation while another is in flight.
	var batchKeys:Array<String> = [];
	var batchTarget:Null<String>;
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

	public function new(client:WorkspaceWorkbenchClient, open:TerminalRecord->Bool, createTerminal:String->Void,
		edit:(WorkspaceGroup, String)->Void, openFolder:String->Void, terminalActions:TerminalRecord->Array<MenuItem>, requestFrame:Void->Void,
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
		tree.onExpandedChanged = function(_, _) requestFrame();
		tree.onItemContextMenu = function(key, event) {
            event.preventDefault(); event.stopPropagation();
            menu(groupFor(key), event, key);
        };
        model.groupEditor = function(id) return draft != null && draft.id == id ? inlineEditor : null;
		model.agentEditor = function(id) return agentDraft != null && agentDraft.id == id ? agentEditor : null;
		tree.onItemClicked = function(key, _) {
			if (agentDraft != null || draft != null) return;
			var row = WorkbenchRowKey.parse(key);
			if (row == null) return;
			if (row.kind == WorkbenchRowKind.Agent) {
				client.agentService().agentAction(row.id, "read", "", null);
				openAgent(row.id);
			} else if (row.kind == WorkbenchRowKind.Terminal) {
				var terminal = model.terminals.get(row.id);
				if (terminal != null) open(terminal);
			}
		};
	}

	function canDragNode(key:String):Bool {
		if (draft != null || agentDraft != null || pending || client.terminalCatalogBusy()) return false;
		var row = WorkbenchRowKey.parse(key);
		if (row == null) return false;
		return switch row.kind {
			case WorkbenchRowKind.Group: client.canEditGroups() && model.groups.exists(row.id);
			case WorkbenchRowKind.Terminal: client.canControlTerminals() && model.terminals.exists(row.id);
			case WorkbenchRowKind.Agent: client.agentService().canControlAgents() && !client.agentService().agentBusy() && model.agents.exists(row.id);
		};
	}

	function canDropNode(source:String, target:String):Bool {
		var catalog = client.terminalCatalog();
		if (catalog == null || catalog.instance != observedWorkspaceInstance || catalog.workspaceRoot != observedWorkspaceRoot
			|| !canDragNode(source)) return false;
		return WorkbenchDropRules.canDrop(source, target, catalog, client.agentService().agents());
	}

	function dropNode(source:String, target:String):Void {
		var keys = tree.isSelected(source) ? outermost(tree.selectedKeys()).filter(function(key) return key != target) : [source];
		if (keys.length > 1) startBatch(keys, target);
		else moveNode(source, target);
		tree.setExpanded(target, true);
		requestFrame();
	}

	function moveNode(source:String, target:String):Void {
		// Recheck the live catalog at release, including permissions and mutation state.
		if (!canDropNode(source, target)) return;
		var catalog = client.terminalCatalog();
		if (catalog == null) return;
		var targetId = WorkbenchRowKey.idOf(target, WorkbenchRowKind.Group), row = WorkbenchRowKey.parse(source);
		if (targetId == null || row == null) return;
		var id = row.id;
		switch row.kind {
			case WorkbenchRowKind.Group:
				for (group in catalog.groups) if (group.id == id)
					client.changeGroup(catalog.instance, group, group.name, targetId, group.cwd, model.nextOrder(targetId), false);
			case WorkbenchRowKind.Terminal:
				for (terminal in catalog.terminals) if (terminal.id == id) client.renameTerminal(terminal, terminal.name, targetId);
			case WorkbenchRowKind.Agent:
				var agents = client.agentService().agents();
				if (agents == null) return;
				for (agent in agents.records) if (agent.id == id)
					client.agentService().agentAction(id, "move", targetId, agent.group);
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
		return batchKeys.length == 0 && !client.terminalCatalogBusy() && !client.agentService().agentBusy();

	/** Removes (null target) or moves rows in order, each against the catalog current at its turn. */
	function startBatch(keys:Array<String>, target:Null<String>):Void {
		var catalog = client.terminalCatalog();
		if (catalog == null || keys.length == 0 || batchKeys.length > 0) return;
		batchKeys = keys.copy(); batchTarget = target; batchOwner = catalog.instance;
		batchTerminalError = client.terminalCatalogError(); batchAgentError = client.agentService().agentError();
		runBatch();
	}

	function runBatch():Void {
		if (batchKeys.length == 0) return;
		var catalog = client.terminalCatalog(), service = client.agentService();
		if (catalog == null || catalog.instance != batchOwner) { batchKeys = []; return; }
		if (client.terminalCatalogBusy() || service.agentBusy()) return;
		// A failed step stops the rest; the panel already reports its error.
		var terminalError = client.terminalCatalogError(), agentError = service.agentError();
		if ((terminalError != null && terminalError != batchTerminalError) || (agentError != null && agentError != batchAgentError)) {
			batchKeys = []; return;
		}
		batchTerminalError = terminalError; batchAgentError = agentError;
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

	/** The selected row's group; without one, the default "work" group. */
	function groupFor(key:Null<String>):Null<WorkspaceGroup> {
		var group = WorkbenchRowKey.groupOf(model, key);
		return group != null ? group : model.groups.get("work");
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
			if (client.agentService().canControlAgents() && agentCanBeRemoved(agent))
				items.push(new MenuItem("delete-codex-leaf", "Remove from Workbench", function() removeAgent(agent.id), !client.agentService().agentBusy()));
			showMenu(items, event, valid);
			return;
		}
		if (group != null) {
			if (canCreateAgent()) items.push(new MenuItem("new-agent", "New Agent Session…", function() edit(group, "new-agent")));
			if (client.canCreateGroupedTerminals()) items.push(new MenuItem("new-terminal", "New terminal", function() createTerminal(groupId), !client.terminalCatalogBusy()));
		}
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
		if (cwd != null) items.push(new MenuItem("open-folder", "Open folder", function() openFolder(cwd), true, null, group != null));
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
        model.update(catalog, client.agentService().agents(), creating ? draft : null);
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
		// Keep the last projection during transport recovery so TreeView does not
		// discard its selection, expansion and scroll state for an empty catalog.
		if (catalog != null && (refreshModel || catalogRevision != client.terminalCatalogRevision() || nextAgentKey != agentKey)) {
            refreshModel = false;
			catalogRevision = client.terminalCatalogRevision(); agentKey = nextAgentKey;
			if (retainedAgents != null && (retainedAgents.root != catalog.workspaceRoot
				|| (client.canReadTerminals() && !client.agentService().canReadAgents()))) retainedAgents = null;
			if (agents != null) retainedAgents = agents;
			model.update(catalog, retainedAgents, creating ? draft : null);
		}
        applyPendingReveal();
		applyPendingSessionSelection();
		runBatch();
    }

	public function headerActions(availableWidth:Float = 260):View return new WorkbenchHeaderActions(this, availableWidth);

	public function buildHeaderActions(context:BuildContext, availableWidth:Float):RenderNode {
		syncState();
		var selected = groupFor(tree.selectedKey);
		var terminal = toolbarButton("New terminal", IconName.Terminal, function() {
			if (selected != null) createTerminal(selected.id);
		}, "workbench-new-terminal");
		terminal.enabled = selected != null && client.canCreateGroupedTerminals()
			&& !client.terminalCatalogBusy();
		var agent = toolbarButton("New Codex", IconName.Plus, function() {
			if (selected != null) createProvider("codex", selected.id);
		}, "workbench-new-codex");
		agent.enabled = selected != null && canCreateAgent();
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
			if (selected != null) createProvider("codex", selected.id);
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

	/** What to do first when the Workbench has nothing: open a folder, or make the first group. */
	function emptyState():Null<View> {
		var catalog = client.terminalCatalog();
		var choose = chooseFolder, folder = hasFolder;
		var style = new LayoutStyle(); style.width = LayoutAxis.stretch(); style.childGap = 8; style.padding = new Insets(12, 8, 12, 8);
		var hint = haxeon.ui.core.TextStyleOverride.text(12);
		if (catalog == null && machineSection == null && choose != null && folder != null && !folder()) {
			var button = new Button("Open Folder…", null, function() choose(), "workbench-open-folder");
			button.variant = ButtonVariant.Primary;
			return new Column("workbench-empty", [
				new KeyedView("text", new Text("Open a folder to start. Its groups, sessions and terminals appear here.", null, null, hint)),
				new KeyedView("open", button)
			], style);
		}
		if (catalog != null && catalog.groups.length == 0 && draft == null && client.canEditGroups()) {
			var button = new Button("New group", null, function() beginGroup({id: workspace.client.WorkspaceIds.create("group"),
				name: "", cwd: null, revision: 0, parent: null, order: model.nextOrder(null)}, true), "workbench-first-group");
			button.variant = ButtonVariant.Primary;
			button.enabled = !pending;
			return new Column("workbench-empty", [
				new KeyedView("text", new Text("No groups yet. A group holds agent sessions and terminals for a folder.", null, null, hint)),
				new KeyedView("new", button)
			], style);
		}
		return null;
	}

	public function build(context:BuildContext):RenderNode {
		syncState();
		var selected = groupFor(tree.selectedKey);
		var rows:Array<KeyedView> = [];
		var section = machineSection;
		if (section != null) rows.push(new KeyedView("machine", section));
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
            var target = scrollTarget;
            if (target != null && scrollPasses > 0) {
                // A second layout uses the expanded tree's updated scroll extent.
                tree.scrollTo(target);
                scrollPasses--;
                if (scrollPasses == 0) scrollTarget = null;
                requestFrame();
            }
        });
        node.on(haxeon.ui.core.UiEventKind.KeyDown, function(event) {
            if (event.key == haxeon.ui.core.UiKey.F2 && draft == null && agentDraft == null) {
				var key = tree.selectedKey, agentId = WorkbenchRowKey.idOf(key, WorkbenchRowKind.Agent);
				if (agentId != null) {
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
