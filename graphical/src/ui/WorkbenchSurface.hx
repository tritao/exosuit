package ui;

import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.Rect;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;

/** A quiet framed workspace, with room around the dock for a contact shadow. */
class WorkbenchSurface implements View {
	public static inline final INSET:Float = 5;
	final child:View;
	public function new(child:View) this.child = child;
	public function build(context:BuildContext):RenderNode {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow(); style.height = LayoutAxis.grow();
		style.padding = new Insets(INSET, INSET, INSET, INSET);
		var node = new RenderNode(context.id("workbench-surface"), LayoutVisualKind.Custom, style);
		node.hitTestSelf = false;
		var background = context.theme.tokens.surfaceRaised;
		var edge = WorkbenchBoundary.color(context);
		var dark = background.red + background.green + background.blue < 1.5;
		var shadow = Color.rgba(0, 0, 0, dark ? 0.36 : 0.14);
		node.onPaint(function(canvas, geometry) {
			canvas.fillRectIfPositive(new Rect(0, 0, geometry.width, geometry.height), background);
			var rect = new Rect(INSET, INSET, Math.max(0, geometry.width - 2 * INSET), Math.max(0, geometry.height - 2 * INSET));
			canvas.drawBoxShadow(rect, 0, 1, 5, 0, [4.0, 4.0, 4.0, 4.0], shadow);
			canvas.fillRectIfPositive(new Rect(rect.x - 1, rect.y - 1, rect.width + 2, rect.height + 2), edge);
		}, "workbench-surface:" + background.red + ":" + background.green + ":" + background.blue + ":" + background.alpha
			+ ":" + edge.red + ":" + edge.green + ":" + edge.blue + ":" + edge.alpha + ":" + dark);
		node.add(child.build(context));
		return node;
	}
}
