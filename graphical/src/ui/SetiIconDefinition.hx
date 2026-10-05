package ui;

import haxeon.ui.Color;

class SetiIconDefinition {
	public final glyph:String;
	public final color:Color;

	public function new(glyph:String, rgb:Int) {
		this.glyph = glyph;
		color = Color.fromBytes((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255);
	}
}
