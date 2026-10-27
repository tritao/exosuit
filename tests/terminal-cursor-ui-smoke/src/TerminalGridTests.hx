import haxeon.ui.FontCollection;
import haxeon.ui.TextLayout.TextPosition;
import terminalsession.TerminalSession;
import TerminalCursorSmoke.QuietBackend;

/** Terminal columns are independent of fallback font advances and cluster length. */
@:access(ui.TerminalPane)
class TerminalGridTests {
	public static function run(fonts:FontCollection):Void {
		var emulator = terminalkit.Emulator.open(80, 24);
		var pane = new ui.TerminalPane(new TerminalSession(new QuietBackend(), emulator),
			function() {}, new ui.TerminalPalette(true), fonts);
		emulator.feedString("\x1b[?25lA⣿ B e\u0301 C中D");
		pane.poll();
		var row = pane.renderedRows[0];
		if (!StringTools.startsWith(row.text, "A⣿ B e\u0301 C中D") || row.layout.text != row.text || !row.grid)
			throw "Terminal grid lost original Unicode clusters";
		var columns = [0, 1, 2, 3, 4, 5, 5, 6, 7, 8, 10, 11];
		for (offset in 0...columns.length) {
			if (offset == 6) continue; // No caret inside the combining cluster.
			if (Math.abs(row.layout.caret(new TextPosition(offset, 0)).x - columns[offset] * pane.cellWidth) > 0.1)
				throw "Fallback or combining glyphs shifted a terminal column";
		}
		var rejected = false;
		try row.layout.setGridPositions([0.0]) catch (_:Dynamic) rejected = true;
		if (!rejected || Math.abs(row.layout.caret(new TextPosition(10, 0)).x - 10 * pane.cellWidth) > 0.1)
			throw "Invalid grid mapping replaced the active terminal geometry";
		var retained = row.layout;
		emulator.feedString("\rA⠿");
		pane.poll();
		if (pane.renderedRows[0].layout != retained)
			throw "Updating a Unicode cell recreated its retained layout";
		emulator.feedString("\r\x1b[2Kplain");
		pane.poll();
		if (pane.renderedRows[0].grid)
			throw "Replacing Unicode left stale cell glyphs";
		pane.close();
	}
}
