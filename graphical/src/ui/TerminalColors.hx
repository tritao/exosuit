package ui;

import Color;

/** Decodes the compact colors emitted by terminalkit/libtsm. */
class TerminalColors {
	public static function decode(packed:Int, fallback:Color, palette:TerminalPalette,
			background:Bool):Color {
		var mode = packed & 3;
		if (mode == 0) return fallback;
		if (mode == 3) return Color.rgba(((packed >>> 8) & 255) / 255.0,
			((packed >>> 16) & 255) / 255.0, ((packed >>> 24) & 255) / 255.0, 1.0);
		var index = (packed >>> 8) & 255;
		var rgb:Array<Int>;
		if (index < 16) {
			return background ? palette.ansiBackground[index] : palette.ansi[index];
		} else if (index < 232) {
			var cube = [0, 95, 135, 175, 215, 255];
			var n = index - 16;
			rgb = [cube[Std.int(n / 36)], cube[Std.int(n / 6) % 6], cube[n % 6]];
		} else {
			var gray = 8 + (index - 232) * 10;
			rgb = [gray, gray, gray];
		}
		return Color.rgba(rgb[0] / 255.0, rgb[1] / 255.0, rgb[2] / 255.0, 1.0);
	}
}
