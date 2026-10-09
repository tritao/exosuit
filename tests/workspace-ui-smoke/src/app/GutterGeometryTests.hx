package app;

import editor.GutterGeometry;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.Rect;
import haxeon.ui.Transform2D;

class GutterGeometryTests {
	static function item(x:Float, y:Float, transform:Transform2D):ResolvedLayoutItem {
		return new ResolvedLayoutItem(1, 1, x, y, 100, 800,
			new Rect(0, 0, 2000, 2000), new Rect(0, 0, 100, 800), transform, 0);
	}
	public static function run() {
		for (zoom in [0.7, 1.0, 1.25, 2.0]) {
			var parent = Transform2D.translation(50, 30).multiply(Transform2D.scale(zoom, zoom));
			var rail = item(10, 80, parent);
			for (scroll in [0.0, 21.0, 1134.0, 42000.0]) {
				var source = item(70, 84, parent.multiply(Transform2D.translation(-320, -scroll)));
				var origin = GutterGeometry.sourceOriginY(source, rail);
				if (Math.abs(origin - (4 - scroll)) > 0.00001)
					throw 'Wrong gutter origin at zoom $zoom, scroll $scroll: $origin';
			}
		}
		trace("PASS: gutter follows long-document scrolling with horizontal scroll and fractional zoom");
	}
}
