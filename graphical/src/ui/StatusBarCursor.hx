package ui;

import editor.BufferSelection;
import editor.TextBuffer;

/** The status bar's caret summary: "Ln 4, Col 9", "(12 selected)" for a selection, "3 selections" for multiple carets. */
class StatusBarCursor {
	public static function label(buffer:TextBuffer, selection:BufferSelection):String {
		var ranges = selection.allRanges();
		var selected = 0;
		for (range in ranges) if (!range.isCollapsed())
			selected += buffer.offsetOf(range.end()) - buffer.offsetOf(range.start());
		var head = ranges.length > 1 ? ranges.length + " selections"
			: "Ln " + (selection.cursor.line + 1) + ", Col " + (selection.cursor.column + 1);
		return selected > 0 ? head + " (" + selected + " selected)" : head;
	}
}
