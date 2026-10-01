package editor;

import style.Theme;

/** Caches caret-dependent marks once per document/selection/palette change. */
class CaretPresentation {
	var previous:Array<Int> = [];
	var marks:Array<DecorationRange> = [];

	public function new() {}

	public function update(document:Document, selection:BufferSelection, theme:Theme):Bool {
		var cursor = document.buffer.positionAt(selection.cursor.line, selection.cursor.column);
		var current = [document.id, document.buffer.stateId, cursor.line, cursor.column,
			selection.hasSelection() ? 1 : 0, theme.currentLine, theme.bracketMatch];
		var changed = previous.length != current.length;
		if (!changed)
			for (index in 0...current.length)
				if (previous[index] != current[index]) changed = true;
		if (!changed) return false;
		previous = current;
		var paragraph = document.buffer.document.paragraphRangeAtIndex(cursor.line);
		marks = [new DecorationRange(paragraph.start, paragraph.end, theme.currentLine, WholeLineBackground)];
		if (!selection.hasSelection()) {
			var pair = document.matchingBrackets(cursor);
			if (pair != null) {
				var first = EditorCoordinates.codepoint(document, pair.first);
				var second = EditorCoordinates.codepoint(document, pair.second);
				marks.push(new DecorationRange(first, first + 1, theme.bracketMatch, Background));
				marks.push(new DecorationRange(second, second + 1, theme.bracketMatch, Background));
			}
		}
		return true;
	}

	public function ranges(start:Int, end:Int):Array<DecorationRange> {
		return [for (mark in marks)
			if (mark.start == mark.end ? mark.start >= start && mark.start <= end : mark.start < end && mark.end > start)
				mark];
	}
}
