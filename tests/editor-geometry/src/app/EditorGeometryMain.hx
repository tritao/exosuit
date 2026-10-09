package app;

class EditorGeometryMain {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }
	static function main():Int {
		var geometry = new editor.EditorViewportGeometry();
		geometry.configure(false, true); geometry.setViewport(700, 400); geometry.resolveSource(2000, 6000, 20);
		require(geometry.contentWidth == 2100 && geometry.contentHeight == 6100, "intrinsic dimensions lost");
		require(geometry.usableWidth() == 612 && geometry.maxScrollY() == 5700, "viewport bounds disagree");
		var retained = geometry.contentHeight;
		geometry.configure(false, true); geometry.setViewport(700, 400);
		require(geometry.contentHeight == retained, "rebuild discarded shaped document height");
		var target = geometry.reveal(1900, 5960, 5980, 0, 0);
		require(target.x > 0 && target.y > 0 && target.x <= geometry.maxScrollX() && target.y <= geometry.maxScrollY(), "caret reveal is out of bounds");
		require(1900 - target.x <= geometry.usableWidth() - 12, "caret revealed under minimap");
		for (zoom in [0.5, 1.0, 1.5, 2.0, 3.0]) {
			var density = editor.MinimapDensity.resolve(zoom);
			require(Math.abs(density.rowPitch * zoom - 1) < 0.000001 && density.markHeight == 1, "zoom changed screen density");
			var mapping = geometry.minimapGeometry(400, zoom);
			for (fraction in [0.0, 0.2, 0.5, 1.0]) {
				var offset = fraction * geometry.maxScrollY();
				require(Math.abs(mapping.scrollAt(mapping.thumbTop(offset)) - offset) < 0.000001, "minimap navigation differs from viewport");
			}
		}
		geometry.configure(true, true); geometry.resolveSource(600, 12000, 20);
		require(geometry.contentWidth == 700 && geometry.maxScrollX() == 0 && geometry.rightPadding() == 88, "wrap retained horizontal scrolling");
		require(geometry.reveal(500, 5000, 5020, 50, 0).x == 0, "wrap caret retained horizontal offset");
		geometry.setViewport(400, 300);
		require(geometry.minimapWidth == 0 && geometry.usableWidth() == 400, "narrow viewport retained minimap space");
		geometry.resolveSource(0, 20, 20);
		require(geometry.contentHeight == 300 && geometry.maxScrollY() == 0, "short document has phantom scroll range");
		trace("PASS: retained editor extents, caret reveal, wrap, resize and minimap zoom mapping");
		return 0;
	}
}
