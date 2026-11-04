package app;

import ui.TerminalGlyphs;

/** Symbols no Android font has are replaced by single-character stand-ins that keep the cell grid. */
class TerminalGlyphTests {
	static function require(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	public static function run():Void {
		var replaced = TerminalGlyphs.replaced();
		require(replaced.length == 8, "stand-in table size: " + replaced.length);
		for (code in replaced) {
			var target = TerminalGlyphs.standIn(code);
			require(target != code, "no stand-in for " + StringTools.hex(code, 4));
			require(target < 0x10000, "stand-in is not a BMP character: " + StringTools.hex(target, 4));
			require(replaced.indexOf(target) < 0, "stand-in is itself replaced: " + StringTools.hex(target, 4));
		}
		// What Claude Code's mode line and result marker print.
		var line = "⏵⏵ auto mode on ⏸ plan ⎿ Wrote 1 line ✻ ● ❯ ↓ ...";
		var shown = TerminalGlyphs.substitute(line);
		require(shown.length == line.length, "length changed");
		require(shown == "▶▶ auto mode on ∥ plan ╰ Wrote 1 line ✻ ● ❯ ↓ ...", "unexpected text: " + shown);
		require(TerminalGlyphs.substitute("plain text") == "plain text", "plain text changed");
	}
}
