package ui;

import haxeon.ui.Color;
import haxeon.ui.Rect;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;

/** Small workbench-region glyphs, using the same crisp border primitive as chrome. */
class LayoutControlIcon implements View {
	final region:String;
	final color:Color;
	public function new(region:String, color:Color) { this.region = region; this.color = color; }
	public function build(context:BuildContext):RenderNode {
		var style = new LayoutStyle(); style.width = LayoutAxis.fixed(18); style.height = LayoutAxis.fixed(18);
		var node = new RenderNode(context.id("layout-icon-" + region), LayoutVisualKind.Custom, style);
		node.hitTestSelf = false;
		node.onPaint(function(canvas, _) {
			canvas.drawRectBorder(new Rect(2, 3, 14, 12), 0, color);
			var pane = region == "left" ? new Rect(3, 4, 4, 10) : region == "right" ? new Rect(11, 4, 4, 10) : new Rect(3, 11, 12, 3);
			canvas.drawRectBorder(pane, 1, color);
		}, "layout-icon:" + region + ":" + color.red + ":" + color.green + ":" + color.blue);
		return node;
	}
}
