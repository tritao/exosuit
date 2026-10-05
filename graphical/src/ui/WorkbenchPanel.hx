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
import workspace.client.WorkspaceTerminalCatalogClient;
import workspace.service.WorkspaceProtocol;
import workspace.service.WorkspaceTerminalProtocol;

class WorkbenchPanel implements View {
	final client:WorkspaceTerminalCatalogClient;
	final open:TerminalRecord->Bool;
	final createTerminal:String->Void;
	final edit:(WorkspaceGroup, Bool) -> Void;
	final openFolder:String->Void;
	final manage:Void->Void;
	final requestFrame:Void->Void;

	public final model = new WorkbenchTreeModel();
	public final tree:TreeView;

	var catalogRevision:Int = -1;

	public function new(client:WorkspaceTerminalCatalogClient, open:TerminalRecord->Bool, createTerminal:String->Void, edit:(WorkspaceGroup, Bool) -> Void,
			openFolder:String->Void, manage:Void->Void, requestFrame:Void->Void) {
		this.client = client;
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
		return model.groups.get("work");
	}

	public function build(context:BuildContext):RenderNode {
		if (catalogRevision != client.terminalCatalogRevision()) {
			catalogRevision = client.terminalCatalogRevision();
			model.update(client.terminalCatalog());
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
		var rows:Array<KeyedView> = [
			new KeyedView("create", new Row("workbench-create", [new KeyedView("group", newGroup), new KeyedView("terminal", newTerminal)])),
			new KeyedView("edit", new Row("workbench-edit", [new KeyedView("group", editButton), new KeyedView("folder", folder)]))
		];
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
