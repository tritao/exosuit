package ui;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.collections.TreeView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.text.Text;
import workspace.client.WorkspaceWorkbenchClient;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalProtocol;

class WorkbenchPanel implements View {
	final client:WorkspaceWorkbenchClient;
	final open:TerminalRecord->Bool;
	final createTerminal:String->Void;
	final openAgent:String->Void;
	var agentKey = -1;
	var attachThread = "";
	final edit:(WorkspaceGroup, Bool) -> Void;
	final openFolder:String->Void;
	final manage:Void->Void;
	final requestFrame:Void->Void;

	public final model = new WorkbenchTreeModel();
	public final tree:TreeView;

	var catalogRevision:Int = -1;

	public function new(client:WorkspaceWorkbenchClient, open:TerminalRecord->Bool, createTerminal:String->Void, edit:(WorkspaceGroup, Bool) -> Void,
			openFolder:String->Void, manage:Void->Void, requestFrame:Void->Void, openAgent:String->Void) {
		this.client = client;
		this.openAgent = openAgent;
		this.open = open;
		this.createTerminal = createTerminal;
		this.edit = edit;
		this.openFolder = openFolder;
		this.manage = manage;
		this.requestFrame = requestFrame;
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.grow();
		tree = new TreeView("workbench-tree", model, style);
		tree.expandOnSingleClick = true;
		tree.onSelectionChanged = function(_) requestFrame();
		tree.onItemClicked = function(key, _) {
			if (StringTools.startsWith(key, "a:")) {
				client.agentService().agentAction(key.substring(2), "read", "", null);
				openAgent(key.substring(2));
			}
			if (StringTools.startsWith(key, "t:")) {
				var t = model.terminals.get(key.substring(2));
				if (t != null)
					open(t);
			}
		};
		tree.onExpandedChanged = function(_, _) requestFrame();
	}

	function selectedGroup():Null<WorkspaceGroup> {
		var key = tree.selectedKey;
		if (key != null && StringTools.startsWith(key, "g:"))
			return model.groups.get(key.substring(2));
		if (key != null && StringTools.startsWith(key, "t:")) {
			var t = model.terminals.get(key.substring(2));
			if (t != null)
				return model.groups.get(t.group);
		}
		if (key != null && StringTools.startsWith(key, "a:")) {
			var a = model.agents.get(key.substring(2));
			if (a != null)
				return model.groups.get(a.group);
		}
		return model.groups.get("work");
	}

	public function build(context:BuildContext):RenderNode {
		var agents = client.agentService().agents(),
			nextAgentKey = client.agentService().agentRevision();
		if (catalogRevision != client.terminalCatalogRevision() || nextAgentKey != agentKey) {
			agentKey = nextAgentKey;
			catalogRevision = client.terminalCatalogRevision();
			model.update(client.terminalCatalog(), agents);
		}
		var selected = selectedGroup();
		var newGroup = new Button("New group", null, function() {
			edit({
				id: workspace.client.WorkspaceIds.create("group"),
				name: "New group",
				cwd: null,
				revision: 0,
				parent: selected == null ? null : selected.id,
				order: model.nextOrder(selected == null ? null : selected.id)
			}, true);
		}, "workbench-new-group");
		var newTerminal = new Button("New terminal", null, function() {
			if (selected != null)
				createTerminal(selected.id);
		}, "workbench-new-terminal");
		newGroup.enabled = client.canEditGroups() && !client.terminalCatalogBusy();
		newTerminal.enabled = selected != null && !client.terminalCatalogBusy();
		var editButton = new Button("Edit group", null, function() {
			if (selected != null)
				edit(selected, false);
		}, "workbench-edit-group");
		editButton.enabled = selected != null && client.canEditGroups() && !client.terminalCatalogBusy();
		var folder = new Button("Open folder", null, function() {
			if (selected != null) {
				var cwd = model.directory(selected);
				if (cwd != null)
					openFolder(cwd);
			}
		}, "workbench-open-folder");
		folder.enabled = selected != null && model.directory(selected) != null;
		var actionStyle = new LayoutStyle();
		actionStyle.width = LayoutAxis.grow();
		actionStyle.wrapMode = haxeon.ui.LayoutWrapMode.Wrap;
		actionStyle.rowGap = 4;
		var rows:Array<KeyedView> = [
			new KeyedView("create", new Row("workbench-create", [new KeyedView("group", newGroup), new KeyedView("terminal", newTerminal)], actionStyle)),
			new KeyedView("edit", new Row("workbench-edit", [new KeyedView("group", editButton), new KeyedView("folder", folder)], actionStyle))
		];
		var agentButton = new Button("New Codex", null, function() {
			if (selected != null)
				client.agentService().createAgent(selected.id, null, openAgent);
		}, "workbench-new-codex");
		agentButton.enabled = selected != null && client.agentService().canControlAgents() && !client.agentService().agentBusy();
		rows.push(new KeyedView("new-codex", agentButton));
		var threadField = new haxeon.ui.widgets.text.TextField("workbench-attach-thread", attachThread, function(v) {
			attachThread = v;
			requestFrame();
		});
		threadField.label = "Existing Codex thread id";
		rows.push(new KeyedView("thread-id", threadField));
		rows.push(new KeyedView("attach-codex", new Button("Attach Codex thread", null, function() {
			if (selected != null && attachThread != "")
				client.agentService().createAgent(selected.id, attachThread, openAgent);
		}, "workbench-attach-codex")));
		rows.push(new KeyedView("discover-codex", new Button("Find Codex threads", null, function() {
			if (selected != null)
				client.agentService().discoverAgents(selected.id, null);
		}, "workbench-find-codex")));
		var found = client.agentService().discoveredAgents();
		if (found != null) {
			for (thread in found.threads) {
				var t = thread;
				rows.push(new KeyedView("thread-" + t.id, new Button(t.title == "" ? t.id : t.title, null, function() {
					if (selected != null)
						client.agentService().createAgent(selected.id, t.id, openAgent);
				})));
			}
			if (found.next != null)
				rows.push(new KeyedView("more-threads", new Button("More threads", null, function() {
					if (selected != null)
						client.agentService().discoverAgents(selected.id, found.next);
				})));
		}
		if (agents != null)
			rows.push(new KeyedView("provider", new Text(agents.status)));
		if (client.agentService().agentError() != null)
			rows.push(new KeyedView("agent-error", new Text(client.agentService().agentError())));

		var error = client.terminalCatalogError();
		if (error != null)
			rows.push(new KeyedView("error", new Text(error)));
		rows.push(new KeyedView("tree", tree));
		rows.push(new KeyedView("manage", new Button("Manage terminals…", null, manage, "workbench-manage")));
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.grow();
		return new Column("workbench", rows, style).build(context);
	}
}
