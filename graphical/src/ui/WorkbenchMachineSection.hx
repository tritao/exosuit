package ui;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.overlays.MenuItem;
import haxeon.ui.widgets.text.Text;
import suit.MachineCatalog.MachineWorkspace;
import workspace.client.MachineClient;

/** What the Workbench's machine section does; ExosuitApp supplies it. */
typedef WorkbenchMachineActions = {
	/** The id of the machine workspace open in this window, or null. */
	var openWorkspace:Void->Null<String>;
	var open:MachineWorkspace->Void;
	/** Asks for a folder and creates a workspace for it, then opens it. */
	var create:Void->Void;
	var rename:MachineWorkspace->Void;
	var addFolder:MachineWorkspace->Void;
	var remove:MachineWorkspace->Void;
	var showMenu:(Array<MenuItem>, UiEvent, Void->Bool)->Void;
}

/**
	The top of the Workbench: this machine and its workspaces (docs/architecture/0005-machines-and-workspaces.md).
	Selecting a workspace opens its folders; the group tree below shows its work. A machine may have no workspaces;
	New workspace is always here.
**/
class WorkbenchMachineSection implements View {
	final machine:MachineClient;
	final actions:WorkbenchMachineActions;

	public function new(machine:MachineClient, actions:WorkbenchMachineActions) {
		this.machine = machine;
		this.actions = actions;
	}

	public function build(context:BuildContext):RenderNode {
		var state = machine.machine;
		var tokens = context.theme.tokens;
		var rows:Array<KeyedView> = [];
		var title = state == null ? "This machine" : state.name + " · this machine";
		rows.push(new KeyedView("machine", new Text(title, null, tokens.textSecondary, TextStyleOverride.text(12))));
		var open = actions.openWorkspace();
		if (state != null) {
			for (workspace in state.workspaces) {
				var target = workspace;
				var button = new Button(workspace.name, null, function() actions.open(target), "machine-workspace-" + workspace.id);
				button.leadingIcon = IconName.FolderClosed;
				button.variant = ButtonVariant.Navigation;
				button.selected = workspace.id == open;
				button.ellipsizeLabel = true;
				button.accessibilityLabel = workspace.name + ": " + workspace.folders.join(", ");
				rows.push(new KeyedView("workspace-" + workspace.id, new MachineMenuTarget(button, function(event) actions.showMenu([
					new MenuItem("machine-workspace-open", "Open", function() actions.open(target)),
					new MenuItem("machine-workspace-rename", "Rename…", function() actions.rename(target), !machine.busy(), null, true),
					new MenuItem("machine-workspace-add-folder", "Add Folder…", function() actions.addFolder(target), !machine.busy()),
					new MenuItem("machine-workspace-remove", "Remove from This Machine", function() actions.remove(target), !machine.busy(), null, true)
				], event, function() return machine.machine != null && Lambda.exists(machine.machine.workspaces, function(w) return w.id == target.id)))));
			}
			if (state.workspaces.length == 0)
				rows.push(new KeyedView("empty", new Text("No workspaces yet. A workspace is one or more folders; its groups, sessions and terminals appear below.",
					null, tokens.textSecondary, TextStyleOverride.text(12))));
		} else if (machine.error == null)
			rows.push(new KeyedView("loading", new Text("Looking for this machine's workspaces…", null, tokens.textSecondary, TextStyleOverride.text(12))));
		var create = new Button("New Workspace…", null, actions.create, "machine-new-workspace");
		create.leadingIcon = IconName.Plus;
		create.variant = state != null && state.workspaces.length == 0 ? ButtonVariant.Primary : ButtonVariant.Secondary;
		create.enabled = !machine.busy();
		rows.push(new KeyedView("new", create));
		if (machine.error != null)
			rows.push(new KeyedView("error", new Text(machine.error, null, tokens.textSecondary, TextStyleOverride.text(12))));
		var style = new LayoutStyle();
		style.width = LayoutAxis.stretch();
		style.childGap = 2;
		style.padding = new Insets(8, 6, 8, 8);
		return new Column("workbench-machine", rows, style).build(context);
	}
}

private class MachineMenuTarget implements View {
	final child:View;
	final request:UiEvent->Void;

	public function new(child:View, request:UiEvent->Void) {
		this.child = child;
		this.request = request;
	}

	public function build(context:BuildContext):RenderNode {
		var node = child.build(context);
		var open = function(event:UiEvent) {
			request(event);
			event.preventDefault();
			event.stopPropagation();
		};
		node.on(UiEventKind.PointerDown, function(event) { if (event.button == 1) open(event); });
		node.on(UiEventKind.KeyDown, function(event) { if (UiKey.isContextMenuRequest(event.key, event.modifiers)) open(event); });
		return node;
	}
}
