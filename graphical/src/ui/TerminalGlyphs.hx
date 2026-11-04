package ui;

/**
 * Stand-ins for terminal symbols that no Android system font has.
 *
 * Android's fonts lack the media controls U+23F4..U+23FA (outside a bitmap emoji font the rasterizer cannot draw)
 * and the bracket piece U+23BE/U+23BF, so Claude Code's mode line (⏵⏵ auto mode, ⏸ plan) and its result marker (⎿)
 * drew as empty boxes. Each stand-in is a single BMP character from Noto Sans Symbols, so the text keeps its length
 * and the cell grid does not move. Everything not listed passes through unchanged.
 */
class TerminalGlyphs {
	static final standIns:Map<Int, Int> = [
		0x23BF => 0x2570, // ⎿ -> ╰
		0x23F4 => 0x25C0, // ⏴ -> ◀
		0x23F5 => 0x25B6, // ⏵ -> ▶
		0x23F6 => 0x25B2, // ⏶ -> ▲
		0x23F7 => 0x25BC, // ⏷ -> ▼
		0x23F8 => 0x2225, // ⏸ -> ∥
		0x23F9 => 0x25A0, // ⏹ -> ■
		0x23FA => 0x25CF, // ⏺ -> ●
	];

	/** The code points this table replaces. */
	public static function replaced():Array<Int> return [for (code in standIns.keys()) code];

	/** The stand-in for a code point, or the code point itself. */
	public static function standIn(code:Int):Int {
		var found = standIns.get(code);
		return found == null ? code : found;
	}

	/** The text with every listed character replaced; same length as the input. */
	public static function substitute(text:String):String {
		var changed = false;
		for (index in 0...text.length) {
			var code = text.charCodeAt(index);
			if (code >= 0x23BF && code <= 0x23FA && standIns.exists(code)) {
				changed = true;
				break;
			}
		}
		if (!changed) return text;
		var out = new StringBuf();
		for (index in 0...text.length) out.addChar(standIn(text.charCodeAt(index)));
		return out.toString();
	}
}
