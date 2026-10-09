package ui;

import haxeon.ui.Color;
import style.WorkbenchColors;

/** Terminal defaults and the first 16 ANSI colors for each workbench scheme. */
class TerminalPalette {
	public var fontSize:Float = 14.0;
	public var foreground:Color;
	public var background:Color;
	public var cursor:Color;
	public var ansi:Array<Color>;
	public var ansiBackground:Array<Color>;

	public function new(dark:Bool) {
		setDark(dark);
	}

	public function setDark(dark:Bool):Void {
		foreground = ExosuitPalette.hex(dark ? WorkbenchColors.darkForeground : WorkbenchColors.lightForeground);
		background = ExosuitPalette.hex(dark ? WorkbenchColors.darkSurfaceSunken : WorkbenchColors.lightSurfaceSunken);
		cursor = ExosuitPalette.hex(dark ? WorkbenchColors.darkAccentHover : WorkbenchColors.lightAccent);
		var values = dark ? [
			0x788596, 0xe8858c, 0x77d49a, 0xe9c46a,
			0x80b4ff, 0xc9a3ef, 0x72cbd4, 0xdce3ec,
			0x8995a6, 0xffa0a6, 0x9ae6b4, 0xf4d990,
			0xa7caff, 0xdfbaf8, 0x9de3e9, 0xffffff
		] : [
			0x202a36, 0xa83242, 0x217a3b, 0x8a5a00,
			0x2459aa, 0x8042a0, 0x146f78, 0x536174,
			0x536174, 0xbd4652, 0x2e8348, 0x9d690a,
			0x386db9, 0x945bb1, 0x26808a, 0x202a36
		];
		ansi = [for (value in values) ExosuitPalette.hex(value)];
		ansiBackground = ansi.copy();
		if (dark) ansiBackground[0] = ExosuitPalette.hex(WorkbenchColors.darkSurface);
		else {
			ansiBackground[7] = ExosuitPalette.hex(0xe9eef5);
			ansiBackground[15] = ExosuitPalette.hex(0xffffff);
		}
	}
}
