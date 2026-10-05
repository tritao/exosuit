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
	public final model = new WorkbenchTreeModel();
	public final tree:TreeView;
	var catalogRevision = -1;
	var agentKey = -1;

	public function new(client:WorkspaceWorkbenchClient, open:TerminalRecord->Bool, createTerminal:String->Void,
		edit:(WorkspaceGroup, Bool)->Void, openFolder:String->Void, manage:Void->Void, requestFrame:Void->Void,
		openAgent:String->Void, showMenu:(Array<MenuItem>, UiEvent, Void->Bool)->Void, attach:WorkspaceGroup->Void) {
		this.client = client; this.open = open; this.createTerminal = createTerminal; this.edit = edit;
		this.openFolder = openFolder; this.manage = manage; this.requestFrame = requestFrame;
		this.openAgent = openAgent; this.showMenu = showMenu; this.attach = attach;
		var style = new LayoutStyle(); style.width = LayoutAxis.stretch(); style.height = LayoutAxis.grow();
		tree = new TreeView("workbench-tree", model, style);
		tree.expandOnSingleClick = true;
		tree.onSelectionChanged = function(_) requestFrame();
		tree.onExpandedChanged = function(_, _) requestFrame();
		tree.onItemContextMenu = function(key, event) menu(groupFor(key), event);
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

	function menu(group:Null<WorkspaceGroup>, event:UiEvent):Void {
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
		showMenu([
			new MenuItem("new-group", "New group", function() edit({id: workspace.client.WorkspaceIds.create("group"),
				name: "New group", cwd: null, revision: 0, parent: group == null ? null : group.id,
				order: model.nextOrder(group == null ? null : group.id)}, true), editable),
			new MenuItem("edit-group", "Edit group", function() edit(group, false), group != null && editable),
			new MenuItem("open-folder", "Open folder", function() openFolder(cwd), cwd != null),
			new MenuItem("attach-codex", "Attach existing Codex thread…", function() attach(group),
				group != null && client.agentService().canControlAgents()),
			new MenuItem("manage-terminals", "Manage terminals…", manage),
			new MenuItem("refresh-agents", "Refresh agent status", function() client.agentService().refreshAgents(),
				client.agentService().canReadAgents())
		], event, valid);
	}

	function toolbarButton(label:String, icon:IconName, action:Void->Void, key:String):Button {
		var style = new LayoutStyle(); style.width = LayoutAxis.fixed(32); style.height = LayoutAxis.fixed(32);
		style.padding = new Insets(8, 8, 8, 8);
		var button = new Button("", style, action, key);
		button.accessibilityLabel = label; button.leadingIcon = icon; button.variant = ButtonVariant.Navigation;
		return button;
	}

	public function build(context:BuildContext):RenderNode {
		var agents = client.agentService().agents();
		var nextAgentKey = client.agentService().agentRevision();
		if (catalogRevision != client.terminalCatalogRevision() || nextAgentKey != agentKey) {
			catalogRevision = client.terminalCatalogRevision(); agentKey = nextAgentKey;
			model.update(client.terminalCatalog(), agents);
		}
		var selected = groupFor(tree.selectedKey);
		var terminal = toolbarButton("New terminal", IconName.Terminal, function() {
			if (selected != null) createTerminal(selected.id);
		}, "workbench-new-terminal");
		terminal.enabled = selected != null && !client.terminalCatalogBusy();
		var agent = toolbarButton("New Codex", IconName.Plus, function() {
			if (selected != null) client.agentService().createAgent(selected.id, null, openAgent);
		}, "workbench-new-codex");
		agent.enabled = selected != null && client.agentService().canControlAgents() && !client.agentService().agentBusy();
		var more = toolbarButton("Workbench actions", IconName.ChevronDown, null, "workbench-actions");
		more.onClickEvent = function(event) menu(selected, event);
		var toolbarStyle = new LayoutStyle(); toolbarStyle.width = LayoutAxis.stretch(); toolbarStyle.childGap = 2;
		toolbarStyle.padding = new Insets(4, 2, 4, 2);
		var rows:Array<KeyedView> = [new KeyedView("toolbar", new Row("workbench-toolbar", [
			new KeyedView("terminal", new haxeon.ui.widgets.overlays.Tooltip("new-terminal-tip", terminal, new Text("New terminal"), 0, 36)),
			new KeyedView("agent", new haxeon.ui.widgets.overlays.Tooltip("new-agent-tip", agent, new Text("New Codex"), -32, 36)),
			new KeyedView("more", new haxeon.ui.widgets.overlays.Tooltip("workbench-actions-tip", more, new Text("Actions"), -64, 36))
		], toolbarStyle)), new KeyedView("tree", tree)];
		var error = client.terminalCatalogError();
		if (error == null) error = client.agentService().agentError();
		if (error != null) rows.push(new KeyedView("error", new Text(error)));
		if (agents != null) {
			var statusStyle = new LayoutStyle(); statusStyle.width = LayoutAxis.stretch();
			statusStyle.padding = new Insets(6, 4, 6, 4);
			rows.push(new KeyedView("status", new Text(agents.status == "Codex is not connected" ? "Codex · on demand" : agents.status, statusStyle, context.theme.tokens.textSecondary,
				null, haxeon.ui.theme.TextRole.Caption)));
		}
		var style = new LayoutStyle(); style.width = LayoutAxis.stretch(); style.height = LayoutAxis.grow();
		return new Column("workbench", rows, style).build(context);
	}
}
