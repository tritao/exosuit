package editor;

import haxeon.ui.ResolvedLayoutItem;

/** Align source text with the fixed rail through their resolved transforms. */
class GutterGeometry {
	public static function sourceOriginY(source:ResolvedLayoutItem, rail:ResolvedLayoutItem):Float {
		var x = source.transform.transformedX(source.x, source.y);
		var y = source.transform.transformedY(source.x, source.y);
		return rail.viewportToLocalY(x, y);
	}
}
