package ui;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;

/** Decorative glyph; the containing tree item or tab owns the accessible filename. */
class SetiFileIcon implements View {
	final atlas:SetiIconAtlas;
	final iconId:String;
	final dark:Bool;
	final compact:Bool;

	public function new(atlas:SetiIconAtlas, filename:String, dark:Bool, compact:Bool = false) {
		this.atlas = atlas;
		this.iconId = SetiIconData.iconId(filename);
		this.dark = dark;
		this.compact = compact;
	}

	public function build(context:BuildContext):RenderNode {
		var layout = atlas.layout(iconId, dark);
		var metrics = layout.measure();
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(compact ? 16.0 : 20.0);
		style.height = LayoutAxis.fixed(compact ? 18.0 : 22.0);
		var node = new RenderNode(context.id("seti-file-icon"), LayoutVisualKind.Custom, style);
		node.setStyleIdentity("file-icon", iconId, null, null, ["seti"]);
		node.hitTestSelf = false;
		node.onPaint(function(canvas, geometry) {
			canvas.drawText(layout, (geometry.width - metrics.width) / 2.0,
				(geometry.height - metrics.height) / 2.0);
		}, "seti:" + iconId + ":" + dark);
		return node;
	}
}
