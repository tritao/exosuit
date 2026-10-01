package ui;

import Color;

/** Decodes the compact colors emitted by terminalkit/libtsm. */
class TerminalColors {
	public static function decode(packed:Int, fallback:Color):Color {
		var mode = packed & 3;
		if (mode == 0) return fallback;
		if (mode == 3) return Color.rgba(((packed >>> 8) & 255) / 255.0,
			((packed >>> 16) & 255) / 255.0, ((packed >>> 24) & 255) / 255.0, 1.0);
		var index = (packed >>> 8) & 255;
		var rgb:Array<Int>;
		if (index < 16) {
			var base = [0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x0000ee, 0xcd00cd,
				0x00cdcd, 0xe5e5e5, 0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00,
				0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff][index];
			rgb = [(base >>> 16) & 255, (base >>> 8) & 255, base & 255];
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
