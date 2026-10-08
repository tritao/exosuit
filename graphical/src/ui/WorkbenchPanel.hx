package ui;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Insets;
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
	final edit:(WorkspaceGroup, Bool)->Void;
	final openFolder:String->Void;
	final manage:Void->Void;
	final requestFrame:Void->Void;
	final showMenu:(Array<MenuItem>, UiEvent, Void->Bool)->Void;
	final attach:WorkspaceGroup->Void;
	final closeAgentTab:(String, String)->Void;
	public final model = new WorkbenchTreeModel();
	public final tree:TreeView;
	var catalogRevision = -1;
	var agentKey = -1;
    var draft:Null<WorkspaceGroup>;
    var draftName = "";
    var draftOwner = "";
    var creating = false;
    var pending = false;
    var pendingSince = 0.0;
    var draftError:Null<String>;
    var inlineEditor:Null<WorkbenchGroupNameEditor>;
    var refreshModel = false;
    var pendingReveal:Null<String>;
    var revealRoot:Null<String>;
    var scrollTarget:Null<String>;
    var scrollPasses = 0;
    var pendingAgentSelection:Null<{var key:String; var workspaceRoot:String;}>;
    var observedWorkspaceRoot:Null<String>;

	public function new(client:WorkspaceWorkbenchClient, open:TerminalRecord->Bool, createTerminal:String->Void,
		edit:(WorkspaceGroup, Bool)->Void, openFolder:String->Void, manage:Void->Void, requestFrame:Void->Void,
		openAgent:String->Void, showMenu:(Array<MenuItem>, UiEvent, Void->Bool)->Void, attach:WorkspaceGroup->Void,
		closeAgentTab:(String, String)->Void) {
		this.client = client; this.open = open; this.createTerminal = createTerminal; this.edit = edit;
		this.openFolder = openFolder; this.manage = manage; this.requestFrame = requestFrame;
		this.openAgent = openAgent; this.showMenu = showMenu; this.attach = attach; this.closeAgentTab = closeAgentTab;
		var style = new LayoutStyle(); style.width = LayoutAxis.stretch(); style.height = LayoutAxis.grow();
		tree = new TreeView("workbench-tree", model, style);
		tree.expandOnSingleClick = true;
		tree.onSelectionChanged = function(_) requestFrame();
		tree.onExpandedChanged = function(_, _) requestFrame();
		tree.onItemContextMenu = function(key, event) {
            event.preventDefault(); event.stopPropagation();
            menu(groupFor(key), event, key);
        };
        model.groupEditor = function(id) return draft != null && draft.id == id ? inlineEditor : null;
		tree.onItemClicked = function(key, _) {
			if (StringTools.startsWith(key, "a:")) {
				client.agentService().agentAction(key.substring(2), "read", "", null);
				openAgent(key.substring(2));
			} else if (StringTools.startsWith(key, "t:")) {
				var terminal = model.terminals.get(key.substring(2));
				if (terminal != null) open(terminal);
			}
		};
	}

	public function selectedGroupId():Null<String> {
		var group = groupFor(tree.selectedKey);
		return group == null ? null : group.id;
	}

	function groupFor(key:Null<String>):Null<WorkspaceGroup> {
		if (key != null) {
			if (StringTools.startsWith(key, "g:")) return model.groups.get(key.substring(2));
			if (StringTools.startsWith(key, "t:")) {
				var terminal = model.terminals.get(key.substring(2));
				if (terminal != null) return model.groups.get(terminal.group);
			}
			if (StringTools.startsWith(key, "a:")) {
				var agent = model.agents.get(key.substring(2));
				if (agent != null) return model.groups.get(agent.group);
			}
		}
		return model.groups.get("work");
	}

	function agentCanBeRemoved(agent:Null<WorkspaceAgentProtocol.AgentRecord>):Bool {
		if (agent == null) return false;
		return agent.state != "creating" && agent.state != "reconnecting"
			&& agent.state != "working" && agent.state != "needs-attention";
	}

	function menu(group:Null<WorkspaceGroup>, event:UiEvent, ?key:String):Void {
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
        if (key != null && StringTools.startsWith(key, "t:")) {
            var terminal = model.terminals.get(key.substring(2));
            if (terminal != null) items.push(new MenuItem("open-terminal", "Open terminal", function() open(terminal), terminal.available));
        }
		if (key != null && StringTools.startsWith(key, "a:")) {
			var agent = model.agents.get(key.substring(2));
			if (agent != null) {
				items.push(new MenuItem("open-codex", "Open Codex session", function() openAgent(agent.id)));
				items.push(new MenuItem("delete-codex-leaf", "Remove from Workbench", function() removeAgent(agent.id),
					client.agentService().canControlAgents() && !client.agentService().agentBusy() && agentCanBeRemoved(agent)));
			}
		}
        items.push(new MenuItem("new-codex", "New Codex session", function() client.agentService().createAgent(groupId, null, openAgent),
            group != null && client.agentService().canControlAgents() && !client.agentService().agentBusy()));
        items.push(new MenuItem("new-terminal", "New terminal", function() createTerminal(groupId), group != null && client.canCreateGroupedTerminals() && !client.terminalCatalogBusy()));
        items.push(new MenuItem("new-group", "New group", function() beginGroup({id: workspace.client.WorkspaceIds.create("group"),
            name: "", cwd: null, revision: 0, parent: group == null ? null : group.id,
            order: model.nextOrder(group == null ? null : group.id)}, true), editable && !pending));
        items.push(new MenuItem("rename-group", "Rename group", function() beginGroup(group, false), group != null && editable && !pending));
        items.push(new MenuItem("edit-group", "Group settings…", function() edit(group, false), group != null && editable));
        items.push(new MenuItem("open-folder", "Open folder", function() openFolder(cwd), cwd != null));
        items.push(new MenuItem("attach-codex", "Attach existing Codex thread…", function() attach(group), group != null && client.agentService().canControlAgents()));
        items.push(new MenuItem("manage-terminals", "Manage terminals…", manage));
        items.push(new MenuItem("refresh-agents", "Refresh agent status", function() client.agentService().refreshAgents(), client.agentService().canReadAgents()));
		showMenu(items, event, valid);
	}

	function removeAgent(id:String):Void {
		var agent = model.agents.get(id);
		if (agent == null || !agentCanBeRemoved(agent) || !client.agentService().canControlAgents() || client.agentService().agentBusy()) return;
		tree.select("a:" + id);
		var group = agent.group;
		client.agentService().deleteAgent(id, function() {
			closeAgentTab(id, agent.workspaceRoot);
			if (model.groups.exists(group)) tree.select("g:" + group);
			requestFrame();
		});
		requestFrame();
	}

    function beginGroup(group:WorkspaceGroup, create:Bool):Void {
        var catalog = client.terminalCatalog();
        if (catalog == null || !client.canEditGroups() || pending) return;
        draft = group; creating = create; draftName = group.name;
        draftOwner = catalog.instance; draftError = null;
        inlineEditor = new WorkbenchGroupNameEditor(group.id, draftName, function(value) draftName = value, saveGroup, cancelGroup);
        model.update(catalog, client.agentService().agents(), creating ? draft : null);
        revealNode("g:" + group.id);
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

    /** Keep the tree projection aligned with the active Codex editor tab. */
    public function syncActiveAgent(resource:Null<String>, workspaceRoot:Null<String>):Void {
        if (resource == null || workspaceRoot == null) {
            pendingAgentSelection = null;
            return;
        }
        var key = "a:" + resource;
        if (tree.selectedKey == key) {
            pendingAgentSelection = null;
            return;
        }
        if (pendingAgentSelection != null && pendingAgentSelection.key == key
            && pendingAgentSelection.workspaceRoot == workspaceRoot) return;
        pendingAgentSelection = {key: key, workspaceRoot: workspaceRoot};
        requestFrame();
    }

    /** Discard a delayed tab-to-tree sync when the workspace attachment changes. */
    public function workspaceAttachmentChanged():Void {
        pendingAgentSelection = null;
        if (scrollTarget != null && StringTools.startsWith(scrollTarget, "a:")) scrollTarget = null;
    }

    function applyPendingAgentSelection():Void {
        var target = pendingAgentSelection;
        if (target == null) return;
        var terminalCatalog = client.terminalCatalog();
        var agentCatalog = client.agentService().agents();
        if (terminalCatalog == null || terminalCatalog.workspaceRoot != target.workspaceRoot
            || agentCatalog == null || agentCatalog.root != target.workspaceRoot
            || !model.agents.exists(target.key.substring(2))) return;
        var agent = model.agents.get(target.key.substring(2));
        var group = agent == null ? null : model.groups.get(agent.group);
        if (group == null) return;
        var ancestors:Array<String> = [];
        var visited:Map<String, Bool> = [];
        var parent:Null<String> = group.id;
        while (parent != null && !visited.exists(parent)) {
            visited.set(parent, true);
            ancestors.unshift("g:" + parent);
            var ancestor = model.groups.get(parent);
            if (ancestor == null) return;
            parent = ancestor.parent;
        }
        for (ancestor in ancestors) tree.setExpanded(ancestor, true);
        if (tree.selectedKey != target.key) {
            tree.select(target.key);
            scrollTarget = target.key;
            scrollPasses = 2;
        }
        pendingAgentSelection = null;
    }

    function applyPendingReveal():Void {
        var key = pendingReveal;
        if (key == null) return;
        var catalog = client.terminalCatalog();
        if (catalog == null) return;
        if (catalog.workspaceRoot != revealRoot) { pendingReveal = null; return; }
        var group:Null<WorkspaceGroup> = null;
        if (StringTools.startsWith(key, "g:")) group = model.groups.get(key.substring(2));
        else if (StringTools.startsWith(key, "t:")) {
            var terminal = model.terminals.get(key.substring(2));
            if (terminal != null) group = model.groups.get(terminal.group);
        } else if (StringTools.startsWith(key, "a:")) {
            var agent = model.agents.get(key.substring(2));
            if (agent != null) group = model.groups.get(agent.group);
        }
        if (group == null) return;
        var ancestors:Array<String> = [];
        var visited:Map<String, Bool> = [];
        var parent = StringTools.startsWith(key, "g:") ? group.parent : group.id;
        while (parent != null && !visited.exists(parent)) {
            visited.set(parent, true);
            ancestors.unshift("g:" + parent);
            var ancestor = model.groups.get(parent);
            if (ancestor == null) return;
            parent = ancestor.parent;
        }
        for (ancestor in ancestors) tree.setExpanded(ancestor, true);
        tree.select(key);
        scrollTarget = key;
        scrollPasses = 2;
        pendingReveal = null;
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
		var style = new LayoutStyle(); style.width = LayoutAxis.fixed(32); style.height = LayoutAxis.fixed(32);
		style.padding = new Insets(8, 8, 8, 8);
		var button = new Button("", style, action, key);
		button.accessibilityLabel = label; button.leadingIcon = icon; button.variant = ButtonVariant.Navigation;
		return button;
	}

    public function build(context:BuildContext):RenderNode {
        var catalog = client.terminalCatalog();
        var currentRoot = catalog == null ? null : catalog.workspaceRoot;
        if (currentRoot != null) {
            if (observedWorkspaceRoot != null && observedWorkspaceRoot != currentRoot) workspaceAttachmentChanged();
            observedWorkspaceRoot = currentRoot;
        }
        if (pending && !client.terminalCatalogBusy()) {
            var saved = false;
            var base = draft;
            if (catalog != null && catalog.instance == draftOwner && base != null)
                for (group in catalog.groups) if (group.id == base.id && group.name == draftName && group.revision > base.revision) saved = true;
            if (saved) { pending = false; cancelGroup(); if (base != null) revealNode("g:" + base.id); }
            else if (client.terminalCatalogError() != null || Sys.time() - pendingSince > 10) {
                pending = false;
                draftError = client.terminalCatalogError() == null ? "Could not confirm the save. Refresh before retrying." : client.terminalCatalogError();
            }
        }
        if (inlineEditor != null) inlineEditor.enabled = !pending;
		var agents = client.agentService().agents();
		var terminalCatalog = client.terminalCatalog();
		if (agents != null && (terminalCatalog == null || agents.root != terminalCatalog.workspaceRoot)) agents = null;
		var nextAgentKey = client.agentService().agentRevision();
		if (refreshModel || catalogRevision != client.terminalCatalogRevision() || nextAgentKey != agentKey) {
            refreshModel = false;
			catalogRevision = client.terminalCatalogRevision(); agentKey = nextAgentKey;
			model.update(terminalCatalog, agents, creating ? draft : null);
        }
        applyPendingReveal();
		applyPendingAgentSelection();
		var selected = groupFor(tree.selectedKey);
		var terminal = toolbarButton("New terminal", IconName.Terminal, function() {
			if (selected != null) createTerminal(selected.id);
		}, "workbench-new-terminal");
		terminal.enabled = selected != null && client.canCreateGroupedTerminals()
			&& !client.terminalCatalogBusy();
		var agent = toolbarButton("New Codex", IconName.Plus, function() {
			if (selected != null) client.agentService().createAgent(selected.id, null, openAgent);
		}, "workbench-new-codex");
		agent.enabled = selected != null && client.agentService().canControlAgents() && !client.agentService().agentBusy();
		var selectedAgent = tree.selectedKey != null && StringTools.startsWith(tree.selectedKey, "a:")
			? model.agents.get(tree.selectedKey.substring(2)) : null;
		var deleteAgent = toolbarButton("Remove selected leaf from Workbench", IconName.Trash, function() {
			if (selectedAgent != null) removeAgent(selectedAgent.id);
		}, "workbench-delete-codex");
		deleteAgent.enabled = agentCanBeRemoved(selectedAgent) && client.agentService().canControlAgents() && !client.agentService().agentBusy();
		var more = toolbarButton("Workbench actions", IconName.ChevronDown, null, "workbench-actions");
		more.onClickEvent = function(event) menu(selected, event);
		var toolbarStyle = new LayoutStyle(); toolbarStyle.width = LayoutAxis.stretch(); toolbarStyle.childGap = 2;
		toolbarStyle.padding = new Insets(4, 2, 4, 2);
		var rows:Array<KeyedView> = [new KeyedView("toolbar", new Row("workbench-toolbar", [
			new KeyedView("terminal", new haxeon.ui.widgets.overlays.Tooltip("new-terminal-tip", terminal, new Text(!client.canReadTerminals() ? "Connect to a workspace with terminal read permission"
				: !client.canControlTerminals() ? "Terminal creation requires terminal control permission"
				: !client.canCreateGroupedTerminals() ? "This workspace does not support grouped terminals" : "New terminal"), 0, 36)),
			new KeyedView("agent", new haxeon.ui.widgets.overlays.Tooltip("new-agent-tip", agent, new Text("New Codex"), -32, 36)),
			new KeyedView("delete-agent", new haxeon.ui.widgets.overlays.Tooltip("delete-agent-tip", deleteAgent, new Text("Remove from Workbench"), -64, 36)),
			new KeyedView("more", new haxeon.ui.widgets.overlays.Tooltip("workbench-actions-tip", more, new Text("Actions"), -96, 36))
		], toolbarStyle)), new KeyedView("tree", tree)];
		var error = draftError == null ? client.terminalCatalogError() : draftError;
		if (error == null) error = client.agentService().agentError();
		if (error != null) rows.push(new KeyedView("error", new Text(error)));
		if (agents != null) {
			var statusStyle = new LayoutStyle(); statusStyle.width = LayoutAxis.stretch();
			statusStyle.padding = new Insets(6, 4, 6, 4);
			rows.push(new KeyedView("status", new Text(agents.status == "Codex is not connected" ? "Codex · on demand" : agents.status, statusStyle, context.theme.tokens.textSecondary,
				null, haxeon.ui.theme.TextRole.Caption)));
		}
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
            if (event.key == haxeon.ui.core.UiKey.F2 && draft == null && selected != null && client.canEditGroups()) {
                event.preventDefault(); event.stopPropagation(); beginGroup(selected, false);
            }
        }, "capture");
        node.on(haxeon.ui.core.UiEventKind.PointerDown, function(event) {
            if (event.button == 1 && !event.defaultPrevented) {
                event.preventDefault(); event.stopPropagation(); menu(model.groups.get("work"), event);
            }
        });
        return node;
	}
}

/** Stable parent handles commit/cancel while the text field patches its own state. */
private class WorkbenchGroupNameEditor implements View {
    final id:String;
    var value:String;
    public var enabled = true;
    final change:String->Void;
    final save:Void->Void;
    final cancel:Void->Void;
    var focusRequested = false;
    public function new(id:String, value:String, change:String->Void, save:Void->Void, cancel:Void->Void) {
        this.id = id; this.value = value; this.change = change; this.save = save; this.cancel = cancel;
    }
    public function build(context:BuildContext):RenderNode {
        var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.height = LayoutAxis.fixed(28);
        style.padding = new Insets(4, 2, 4, 2);
        var field = new haxeon.ui.widgets.text.TextField("group-name-" + id, value, function(next) { value = next; change(next); }, style, "Group name");
        field.placeholder = "New group";
        field.enabled = enabled;
        var input = field.build(context);
        input.onResolved(function(_) { if (!focusRequested) focusRequested = context.requestFocus(input.id); });
        var containerStyle = new LayoutStyle(); containerStyle.width = LayoutAxis.grow(); containerStyle.height = LayoutAxis.fixed(28);
        var node = new RenderNode(context.id("group-name-editor"), haxeon.ui.LayoutVisualKind.Box, containerStyle);
        node.add(input);
        node.on(haxeon.ui.core.UiEventKind.KeyDown, function(event) {
            if (event.key == haxeon.ui.core.UiKey.Enter || event.key == haxeon.ui.core.UiKey.Escape) {
                event.preventDefault(); event.stopImmediatePropagation();
                if (event.key == haxeon.ui.core.UiKey.Enter) save(); else cancel();
            }
        }, "capture");
        return node;
    }
}
