package app;

/**
	Synthetic output shaped like Claude Code's terminal UI, which redraws constantly: synchronized updates, a hidden
	cursor, lines erased upward and drawn again, 24-bit foreground and background colours on almost every cell,
	bold, dim, italic and inverse text, box drawing, wide characters and emoji. No real session text.
**/
class ClaudeScreen {
	static final words = ["Reading", "file", "terminal", "snapshot", "replay", "cursor", "screen", "service", "editor",
		"attach", "history", "trimmed", "message", "limit", "pages", "viewer"];

	static function rgb(kind:Int, seed:Int):String
		return '\x1b[$kind;2;${(seed * 37) % 256};${(seed * 91) % 256};${(seed * 53) % 256}m';

	static function line(columns:Int, seed:Int):String {
		var text = new StringBuf();
		var used = 0;
		var bullet = ["⏺ ", "  ⎿  ", "✻ ", "· ", "※ ", "  "][seed % 6];
		text.add(rgb(38, seed) + bullet + "\x1b[39m");
		used += bullet.length;
		var i = 0;
		while (used < columns - 12) {
			var word = words[(seed + i) % words.length];
			var style = switch ((seed + i) % 7) {
				case 0: "\x1b[1m";
				case 1: "\x1b[2m";
				case 2: "\x1b[3m";
				case 3: rgb(48, seed + i);
				case 4: "\x1b[7m";
				default: rgb(38, seed + i * 3);
			};
			text.add(style + word + "\x1b[0m ");
			used += word.length + 1;
			if (i % 5 == 4 && used < columns - 16) { text.add("日本語 👍 "); used += 11; }
			i++;
		}
		return text.toString();
	}

	/** One full redraw of a `columns` x `rows` screen, as the UI writes it every frame. */
	public static function frame(columns:Int, rows:Int, generation:Int):String {
		var out = new StringBuf();
		out.add("\x1b[?2026h\x1b[?25l");
		out.add('\x1b[${rows - 1}A\r');
		for (row in 0...rows - 5) out.add("\x1b[2K" + line(columns, generation * 131 + row) + "\r\n");
		var bar = [for (_ in 0...columns - 2) "─"].join("");
		out.add("\x1b[2K" + rgb(38, 7) + "╭" + bar + "╮\x1b[0m\r\n");
		out.add("\x1b[2K" + rgb(38, 7) + "│\x1b[0m" + rgb(48, 3) + " > " + [for (_ in 0...columns - 5) " "].join("") + "\x1b[0m"
			+ rgb(38, 7) + "│\x1b[0m\r\n");
		out.add("\x1b[2K" + rgb(38, 7) + "╰" + bar + "╯\x1b[0m\r\n");
		out.add("\x1b[2K\x1b[2m  ⏵⏵ accept edits on (shift+tab to cycle)\x1b[0m\r\n");
		out.add("\x1b[2K\x1b]0;✳ Claude Code\x07");
		out.add("\x1b[?2026l");
		return out.toString();
	}

	/** Scrolling transcript followed by many redraws: far more output than a bounded replay keeps. */
	public static function history(frames:Int):String {
		var out = new StringBuf();
		for (seed in 0...600) out.add(line(200, seed) + "\r\n");
		for (generation in 0...frames) out.add(frame(277, 65, generation + 10));
		return out.toString();
	}
}
