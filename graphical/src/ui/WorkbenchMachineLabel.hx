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
import ui.WorkbenchMachineView.WorkbenchWorkspaceState;

/** The Workbench tree's machine rows: a workspace, a status line, New Workspace…. */
class WorkbenchMachineLabel implements View {
	/** The marker of a workspace or group another editor window has focused, and its tooltip. */
	public static inline final OTHER_WINDOW = "another window";
	public static inline final OTHER_WINDOW_TIP = "Open in another window";

	final icon:Null<IconName>;
	final text:String;
	/** A workspace's folder, shown short beside its name as a group row shows its folder. */
	final directory:Null<String>;
	final detail:Null<String>;
	final description:String;
	final muted:Bool;
	final warning:Bool;

	function new(icon:Null<IconName>, text:String, detail:Null<String>, description:String, muted:Bool, warning:Bool, ?directory:String) {
		this.icon = icon; this.text = text; this.detail = detail; this.description = description; this.directory = directory;
		this.muted = muted; this.warning = warning;
	}

	/**
		A workspace row: its name, its folder (`folder`), and what it is doing. The open workspace says so; its
		accessibility label names its folders, or that it has none.
	**/
	public static function workspace(entry:MachineWorkspace, open:Bool, ?state:WorkbenchWorkspaceState, anotherWindow:Bool = false):WorkbenchMachineLabel {
		var folders = entry.folders.length == 0 ? "no folders attached" : entry.folders.join(", ");
		var marker = open ? "this window" : stateMarker(state);
		var catalog = state == null ? null : state.catalog;
		// A stopped workspace shows the attention it had when its service last ran, which is no longer true.
		var attention = catalog == null || open || state == null || !state.running ? 0 : catalog.attention;
		var shown = attention > 0 && marker != null ? marker + " · " + attention : marker;
		if (anotherWindow) shown = shown == null ? OTHER_WINDOW : shown + " · " + OTHER_WINDOW;
		var said = open ? ", open in this window" : marker == null ? "" : ", " + marker + (attention > 0 ? ", " + attention + " need attention" : "");
		if (anotherWindow) said += ", " + OTHER_WINDOW_TIP.toLowerCase();
		var directory = folder(entry);
		var description = "Workspace " + entry.name + said + " · " + folders;
		if (entry.folders.length == 0 && directory != null) description += " · " + directory;
		return new WorkbenchMachineLabel(open ? IconName.FolderOpen : IconName.FolderClosed, entry.name, shown, description, false, false, directory);
	}

	/** The folder a workspace row shows: its first attached folder, else its scratch folder (the one its work runs in). */
	public static function folder(entry:MachineWorkspace):Null<String>
		return entry.folders.length > 0 ? entry.folders[0] : entry.scratch;

	/** What a workspace this window is not attached to is doing: idle (its service is not running), starting, running, or reconnecting. */
	public static function stateMarker(state:Null<WorkbenchWorkspaceState>):Null<String> {
		if (state == null) return null;
		if (state.starting) return "starting…";
		if (!state.running) return "idle";
		return state.live ? "running" : "reconnecting";
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
		var folder = directory;
		if (folder != null)
			children.push(new KeyedView("directory", new Muted(new MiddleEllipsisText("machine-row-directory",
				WorkbenchGroupLabel.shortDirectory(folder, null), true, new TextStyleOverride(null, 12)))));
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
