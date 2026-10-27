package ui;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Rect;
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

/** Fixed-height session row: the name gets remaining space; status keeps its own slot. */
class WorkbenchSessionLabel implements View {
	public static inline final ROW_HEIGHT:Float = 30;
	final name:String;
	final state:String;
	final status:String;
	public function new(name:String, state:String, status:String) {
		this.name = name; this.state = state; this.status = status;
	}
	public function build(context:BuildContext):RenderNode {
		var icon = switch (state) {
			case "running", "working": IconName.Play;
			case "completed": IconName.Check;
			case "exited", "lost": IconName.Stop;
			case "starting", "creating", "reconnecting": IconName.Reset;
			case "idle": IconName.Pause;
			default: IconName.AlertTriangle;
		};
		var color = switch (state) {
			case "running", "working", "starting", "creating", "reconnecting": context.theme.tokens.accent;
			case "completed": context.theme.tokens.success;
			case "failed", "reconnect-failed": context.theme.tokens.danger;
			case "needs-attention", "uncertain", "disconnected": context.theme.tokens.warning;
			default: context.theme.tokens.textSecondary;
		};
		var style = new LayoutStyle(); style.width = LayoutAxis.stretch(); style.height = LayoutAxis.fixed(ROW_HEIGHT);
		style.childAlignY = haxeon.ui.LayoutAlignmentY.Center; style.childGap = 6;
		var row = new Row("workbench-session-label", [
			new KeyedView("name", new MiddleEllipsisText("session-name", name, false, TextStyleOverride.text(ExosuitPalette.WORKBENCH_TEXT_SIZE))),
			new KeyedView("status", new Icon("session-status", icon, 14, color))
		], style);
		var description = name + " · " + status;
		var tooltip = new TabTooltip("session-details", row, new Text(description),
			function() return new Rect(0, 0, context.viewportWidth, context.viewportHeight));
		tooltip.fillAnchor = true; tooltip.requirePointerMovement = true;
		var node = tooltip.build(context);
		node.semantics = new Semantics(AccessibilityRole.Text, description);
		return node;
	}
}
