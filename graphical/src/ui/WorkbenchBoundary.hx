package ui;

import haxeon.ui.Color;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Rect;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;

/** Paint a structural edge without changing layout or intercepting input. */
class WorkbenchBoundary implements View {
	final child:View;
	public function new(child:View) this.child = child;
	public function build(context:BuildContext):RenderNode {
		var node = child.build(context);
		bottom(context, node);
		return node;
	}
	public static function color(context:BuildContext):Color {
		var background = context.theme.tokens.surface;
		var dark = background.red + background.green + background.blue < 1.5;
		return ExosuitPalette.hex(dark ? style.WorkbenchColors.darkDivider : style.WorkbenchColors.lightDivider);
	}
	public static function top(context:BuildContext, node:RenderNode):Void add(context, node, 0);
	public static function bottom(context:BuildContext, node:RenderNode):Void add(context, node, 1);
	public static function right(context:BuildContext, node:RenderNode):Void add(context, node, 2);
	static function add(context:BuildContext, node:RenderNode, edge:Int):Void {
		var layout = new LayoutStyle();
		layout.positioning = haxeon.ui.LayoutPositioning.Absolute;
		layout.width = LayoutAxis.stretch();
		layout.height = LayoutAxis.stretch();
		layout.zIndex = 1;
		var line = new RenderNode(context.id("workbench-boundary-" + edge), haxeon.ui.LayoutVisualKind.Custom, layout);
		line.hitTestSelf = false;
		line.cachePolicy = haxeon.ui.core.CachePolicy.None;
		var ink = color(context);
		line.onPaint(function(canvas, geometry) {
			var density = context.environment.pixelDensity;
			var transform = geometry.transform;
			var scale = (edge == 2 ? transform.a : transform.d) * density;
			if (scale == 0) return;
			var thickness = 1.0 / Math.abs(scale);
			var start = edge == 2 ? Math.max(0, geometry.width - thickness) :
				edge == 1 ? Math.max(0, geometry.height - thickness) : 0;
			var device = (edge == 2 ? transform.transformedX(geometry.x + start, geometry.y) :
				transform.transformedY(geometry.x, geometry.y + start)) * density;
			start += (Math.round(device) - device) / scale;
			var epsilon = thickness * 0.001;
			var rect = edge == 2 ? new Rect(start - epsilon, 0, thickness + 2 * epsilon, geometry.height) :
				new Rect(0, start - epsilon, geometry.width, thickness + 2 * epsilon);
			canvas.drawRectBorder(rect, 0, ink);
		});
		node.add(line);
	}
}
