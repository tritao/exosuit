package ui;

import haxeon.ui.Color;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.Rect;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;

/** Fits an image without upscaling, with a checkerboard for transparent pixels. */
class ImagePreviewView implements View {
	final tab:UiImageTab;
	final activate:Void->Void;
	final resolved:Null<(Rect, haxeon.ui.core.WidgetId)->Void>;

	public function new(tab:UiImageTab, activate:Void->Void, ?resolved:(Rect, haxeon.ui.core.WidgetId)->Void) {
		this.tab = tab;
		this.activate = activate;
		this.resolved = resolved;
	}

	public static function fittedBounds(width:Float, height:Float, availableWidth:Float, availableHeight:Float):Rect {
		var scale = Math.max(0.0, Math.min(1.0, Math.min(availableWidth / width, availableHeight / height)));
		var w = width * scale, h = height * scale;
		return new Rect((availableWidth - w) / 2, (availableHeight - h) / 2, w, h);
	}

	public function build(context:BuildContext):RenderNode {
		var surface = new LayoutStyle();
		surface.width = LayoutAxis.stretch(); surface.height = LayoutAxis.stretch();
		surface.clipHorizontal = true; surface.clipVertical = true;
		surface.background = context.theme.tokens.surface;
		var node = new RenderNode(context.id(tab.id + ":preview"), LayoutVisualKind.Custom, surface);
		node.focusable = true;
		node.semantics = new haxeon.ui.semantics.Semantics(haxeon.ui.semantics.AccessibilityRole.Image,
			tab.title + ", " + tab.image.width + " by " + tab.image.height + " pixels");
		node.on(haxeon.ui.core.UiEventKind.PointerDown, function(_) activate());
		var onResolved = resolved;
		if (onResolved != null) node.onResolved(function(_) onResolved(node.globalBounds(), node.id));
		node.onPaint(function(canvas, geometry) {
			if (tab.image.isDisposed()) return;
			var fitted = fittedBounds(tab.image.width, tab.image.height,
				Math.max(0.0, geometry.width - 32), Math.max(0.0, geometry.height - 32));
			var bounds = new Rect(fitted.x + 16, fitted.y + 16, fitted.width, fitted.height);
			if (bounds.width <= 0 || bounds.height <= 0) return;
			var light = Color.fromBytes(220, 220, 220), dark = Color.fromBytes(180, 180, 180);
			var columns = Std.int(Math.ceil(bounds.width / 12)), rows = Std.int(Math.ceil(bounds.height / 12));
			for (y in 0...rows) for (x in 0...columns)
				canvas.fillRect(new Rect(bounds.x + x * 12, bounds.y + y * 12,
					Math.min(12, bounds.width - x * 12), Math.min(12, bounds.height - y * 12)),
					(x + y) % 2 == 0 ? light : dark);
			canvas.drawImage(tab.image, bounds);
		}, tab.id + ":" + tab.image.identity);
		return node;
	}
}
