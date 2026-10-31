package ui;

import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.Rect;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;

/** A row with an accent line on its upper or lower edge: where a dragged row would land between its siblings. */
class WorkbenchInsertionLine implements View {
	public static inline final THICKNESS:Float = 2;
	final row:View;
	final after:Bool;

	public function new(row:View, after:Bool) {
		this.row = row; this.after = after;
	}

	public function build(context:BuildContext):RenderNode {
		var style = new LayoutStyle();
		style.width = LayoutAxis.stretch(); style.height = LayoutAxis.fixed(WorkbenchSessionLabel.ROW_HEIGHT);
		style.childAlignY = LayoutAlignmentY.Center;
		var node = new RenderNode(context.id("workbench-insertion-line"), LayoutVisualKind.Custom, style);
		node.setStyleIdentity("workbench-insertion-line", "workbench-insertion-line");
		var color = context.theme.tokens.accent, below = after;
		node.onPaint(function(canvas, geometry) {
			canvas.fillRectIfPositive(new Rect(0, below ? geometry.height - THICKNESS : 0, geometry.width, THICKNESS), color);
		}, "workbench-insertion-line:" + (below ? "after:" : "before:") + color.red + ":" + color.green + ":" + color.blue + ":" + color.alpha);
		node.add(row.build(context));
		return node;
	}
}
