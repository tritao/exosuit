package ui;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.widgets.Icon;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.text.MiddleEllipsisText;
import haxeon.ui.widgets.text.Text;
import suit.MachineCatalog.MachineWorkspace;

/** The Workbench tree's machine rows: a workspace, a status line, New Workspace…. */
class WorkbenchMachineLabel implements View {
	final icon:Null<IconName>;
	final text:String;
	final detail:Null<String>;
	final description:String;
	final muted:Bool;
	final warning:Bool;

	function new(icon:Null<IconName>, text:String, detail:Null<String>, description:String, muted:Bool, warning:Bool) {
		this.icon = icon; this.text = text; this.detail = detail; this.description = description;
		this.muted = muted; this.warning = warning;
	}

	/** The open workspace says so; its accessibility label names its folders, or that it has none. */
	public static function workspace(entry:MachineWorkspace, open:Bool):WorkbenchMachineLabel {
		var folders = entry.folders.length == 0 ? "no folders attached" : entry.folders.join(", ");
		return new WorkbenchMachineLabel(open ? IconName.FolderOpen : IconName.FolderClosed, entry.name, open ? "this window" : null,
			"Workspace " + entry.name + (open ? ", open in this window" : "") + " · " + folders, false, false);
	}

	public static function newWorkspace():WorkbenchMachineLabel
		return new WorkbenchMachineLabel(IconName.Plus, "New Workspace…", null, "New Workspace…", false, false);

	public static function status(message:String, warning:Bool = false):WorkbenchMachineLabel
		return new WorkbenchMachineLabel(warning ? IconName.AlertTriangle : null, message, null, message, true, warning);

	public function build(context:BuildContext):RenderNode {
		var tokens = context.theme.tokens;
		var style = new LayoutStyle(); style.width = LayoutAxis.stretch(); style.height = LayoutAxis.fixed(WorkbenchSessionLabel.ROW_HEIGHT);
		style.childGap = 6; style.childAlignY = haxeon.ui.LayoutAlignmentY.Center; style.clipHorizontal = true;
		var children:Array<KeyedView> = [];
		var glyph = icon;
		if (glyph != null) children.push(new KeyedView("icon", new Icon("machine-row-icon", glyph, 14, warning ? tokens.warning : null)));
		var label = new MiddleEllipsisText("machine-row-text", text, false, TextStyleOverride.text(ExosuitPalette.WORKBENCH_TEXT_SIZE));
		children.push(new KeyedView("text", muted ? new Muted(label) : label));
		var note = detail;
		if (note != null) children.push(new KeyedView("detail", new Muted(new Text(note, null, null, TextStyleOverride.text(12)))));
		var row = new Row("workbench-machine-row", children, style);
		var tooltip = new haxeon.ui.widgets.overlays.Tooltip("machine-row-tooltip", row, new Text(description), 0, 28);
		tooltip.requirePointerMovement = true;
		tooltip.fillAnchor = true;
		var node = tooltip.build(context);
		node.semantics = new Semantics(AccessibilityRole.Text, description);
		return node;
	}
}

private class Muted implements View {
	final child:View;
	public function new(child:View) this.child = child;
	public function build(context:BuildContext):RenderNode {
		var node = child.build(context);
		node.layout.textColor = context.theme.tokens.textSecondary;
		return node;
	}
}
