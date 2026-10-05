package ui;

import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ComboBox;
import haxeon.ui.widgets.controls.SelectOption;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextField;
import workspace.client.WorkspaceTerminalCatalogClient;
import workspace.service.WorkspaceProtocol;

/** Draft keeps its base revision; refresh never silently overwrites another client's edit. */
class GroupEditorPanel implements View {
	final client:WorkspaceTerminalCatalogClient;
	final base:WorkspaceGroup;
	final owner:String;
	final create:Bool;
	final done:Void->Void;
	final requestFrame:Void->Void;
	var name:String;
	var parent:String;
	var cwd:String;
	var order:String;
	var pending:Bool = false;
	var error:Null<String>;

	public function new(client:WorkspaceTerminalCatalogClient, base:WorkspaceGroup, create:Bool, done:Void->Void, requestFrame:Void->Void) {
		this.client = client;
		this.base = base;
		this.create = create;
		this.done = done;
		this.requestFrame = requestFrame;
		var catalog = client.terminalCatalog();
		owner = catalog == null ? "" : catalog.instance;
		name = base.name;
		parent = base.parent == null ? "" : base.parent;
		cwd = base.cwd == null ? "" : base.cwd;
		order = Std.string(WorkspaceProtocol.order(base.order));
	}

	function save():Void {
		var parsed = Std.parseInt(order);
		if (!~/^[0-9]+$/.match(order) || parsed == null || parsed < 0 || parsed > 1000000) {
			error = "Order must be between 0 and 1000000";
			requestFrame();
			return;
		}
		error = null;
		client.changeGroup(owner, base, name, parent == "" ? null : parent, cwd == "" ? null : cwd, parsed, create);
		pending = true;
		requestFrame();
	}

	public function build(context:BuildContext):RenderNode {
		var catalog = client.terminalCatalog();
		if (pending && !client.terminalCatalogBusy() && catalog != null && catalog.instance == owner)
			for (group in catalog.groups)
				if (group.id == base.id
					&& group.revision > base.revision
					&& group.name == name
					&& group.parent == (parent == "" ? null : parent)
					&& group.cwd == (cwd == "" ? null : cwd)
					&& WorkspaceProtocol.order(group.order) == Std.parseInt(order)) {
					pending = false;
					done();
				}
		var options = [new SelectOption<String>("top", "Top level", "")];
		if (catalog != null && catalog.instance == owner)
			for (group in catalog.groups)
				if (group.id != base.id)
					options.push(new SelectOption<String>("group:" + group.id, group.name + (group.cwd == null ? "" : " · " + group.cwd), group.id));
		var nameField = new TextField("workbench-group-name", name, function(v) {
			name = v;
			requestFrame();
		});
		nameField.label = "Group name";
		var directory = new TextField("workbench-group-directory", cwd, function(v) {
			cwd = v;
			requestFrame();
		});
		directory.label = "Directory (empty inherits)";
		var ordering = new TextField("workbench-group-order", order, function(v) {
			order = v;
			requestFrame();
		});
		ordering.label = "Sibling order";
		var parentField = new ComboBox<String>("workbench-group-parent", options, parent, function(v) {
			parent = v;
			requestFrame();
		});
		var busy = client.terminalCatalogBusy();
		nameField.enabled = !busy;
		directory.enabled = !busy;
		ordering.enabled = !busy;
		parentField.enabled = !busy;
		var saveButton = new Button("Save group", null, save, "workbench-group-save");
		saveButton.enabled = !busy;
		var rows:Array<KeyedView> = [
			new KeyedView("name-label", new Text("Name")),
			new KeyedView("name", nameField),
			new KeyedView("parent-label", new Text("Parent group")),
			new KeyedView("parent", parentField),
			new KeyedView("directory-label", new Text("Directory (empty inherits)")),
			new KeyedView("directory", directory),
			new KeyedView("order-label", new Text("Sibling order")),
			new KeyedView("order", ordering)
		];
		var failure = error == null ? client.terminalCatalogError() : error;
		if (failure != null)
			rows.push(new KeyedView("error", new Text(failure)));
		rows.push(new KeyedView("save", saveButton));
		return new Column("workbench-group-editor", rows).build(context);
	}
}
