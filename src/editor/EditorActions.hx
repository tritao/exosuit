package editor;

import syntax.SyntaxDefinition;

class EditorActions {
	/** Tab inserts at collapsed carets; a selection indents whole affected lines. */
	public static function tab(buffer:TextBuffer, selection:BufferSelection, tabWidth:Int, insertSpaces:Bool, indentSize:Int = 0):Bool {
		for (range in selection.allRanges()) if (!range.isCollapsed()) return indent(buffer, selection, tabWidth, insertSpaces, indentSize);
		var values:Array<String> = [], width = tabWidth > 0 ? tabWidth : 1;
		for (range in selection.documentRanges()) {
			var column = visualColumn(buffer.line(range.cursor.line), range.cursor.column, width);
			var step = indentSize > 0 ? indentSize : width, target = column + step - column % step;
			var value = "", at = column;
			while (at < target) { var next = at + width - at % width; if (!insertSpaces && next <= target) { value += "\t"; at = next; } else { value += " "; at++; } }
			values.push(value);
		}
		return buffer.replaceSelections(selection, values);
	}

	/** Only leading whitespace uses indentation stops; text uses grapheme deletion. */
	public static function backspace(buffer:TextBuffer, selection:BufferSelection, tabWidth:Int,
			?boundary:(BufferPosition, Int)->BufferPosition, indentSize:Int = 0):Bool {
		var width = tabWidth > 0 ? tabWidth : 1;
		return buffer.deleteSelections(selection, true, function(position, direction) {
			var line = buffer.line(position.line);
			if (position.column > 0 && position.column <= leadingWhitespace(line)) {
				var step = indentSize > 0 ? indentSize : width;
				var column = visualColumn(line, position.column, width), target = column - (column % step == 0 ? step : column % step);
				var offset = position.column;
				while (offset > 0 && visualColumn(line, offset, width) > target) offset--;
				return new BufferPosition(position.line, offset);
			}
			return boundary == null ? buffer.graphemeOffset(position, direction) : boundary(position, direction);
		});
	}

	public static function visualColumn(line:String, end:Int, tabWidth:Int):Int {
		var width = tabWidth > 0 ? tabWidth : 1, column = 0, index = 0;
		while (index < end) {
			var code = line.charCodeAt(index++);
			if (code == 9) column += width - column % width;
			else {
				column++;
				if (code >= 0xD800 && code <= 0xDBFF && index < end && line.charCodeAt(index) >= 0xDC00 && line.charCodeAt(index) <= 0xDFFF) index++;
			}
		}
		return column;
	}

	public static function indent(buffer:TextBuffer, selection:BufferSelection, tabWidth:Int, insertSpaces:Bool, indentSize:Int = 0):Bool {
		var replacements:Array<BufferReplacement> = [], changes:Map<Int, LineColumnChange> = [];
		for (line in selectedLineNumbers(selection)) {
			var text = buffer.line(line), count = leadingWhitespace(text);
			var columns = visualColumn(text, count, tabWidth), step = indentSize > 0 ? indentSize : tabWidth;
			var prefix = Indentation.prefix(columns + step, tabWidth, insertSpaces);
			replacements.push(new BufferReplacement(new BufferPosition(line, 0), new BufferPosition(line, count), prefix));
			changes.set(line, new LineColumnChange(0, prefix.length - count));
		}
		return apply(buffer, selection, replacements, changes, true);
	}

	public static function unindent(buffer:TextBuffer, selection:BufferSelection, tabWidth:Int, indentSize:Int = 0):Bool {
		var replacements:Array<BufferReplacement> = [], changes:Map<Int, LineColumnChange> = [];
		var block = false;
		for (range in selection.allRanges()) if (!range.isCollapsed()) block = true;
		for (line in selectedLineNumbers(selection)) {
			var text = buffer.line(line), whitespace = leadingWhitespace(text), width = tabWidth > 0 ? tabWidth : 1;
			var step = indentSize > 0 ? indentSize : width;
			var columns = visualColumn(text, whitespace, width), target = columns - (block || columns % step == 0 ? step : columns % step);
			if (target < 0) target = 0;
			var keep = 0, keptColumns = 0;
			while (keep < whitespace) {
				var next = text.charCodeAt(keep) == 9 ? keptColumns + width - keptColumns % width : keptColumns + 1;
				if (next > target) break;
				keep++; keptColumns = next;
			}
			var replacement = text.substring(0, keep) + indentationUnit(target - keptColumns, true);
			if (whitespace > 0) {
				replacements.push(new BufferReplacement(new BufferPosition(line, 0), new BufferPosition(line, whitespace), replacement));
				changes.set(line, new LineColumnChange(keep, replacement.length - whitespace));
			}
		}
		return apply(buffer, selection, replacements, changes);
	}

	public static function insertNewline(buffer:TextBuffer, selection:BufferSelection, tabWidth:Int = 4, insertSpaces:Bool = true,
			?highlighter:syntax.Highlighter, indentSize:Int = 0, ?cache:Indentation.IndentationCache):Bool {
		var values:Array<String> = [], carets:Array<Int> = [];
		for (range in selection.documentRanges()) {
			var result = Indentation.newline(buffer, range.start(), range.end(), tabWidth, insertSpaces, highlighter, indentSize, cache);
			values.push(result.text); carets.push(result.caret);
		}
		return buffer.replaceSelections(selection, values, carets);
	}

	public static function reindent(buffer:TextBuffer, selection:BufferSelection, highlighter:syntax.Highlighter,
			tabWidth:Int, insertSpaces:Bool, indentSize:Int, wholeDocument:Bool):Bool {
		if (highlighter.syntax.name != "Haxe") return false;
		var desired = Indentation.lineIndents(buffer, highlighter, tabWidth, indentSize);
		var lines = wholeDocument ? [for (i in 0...buffer.lineCount()) i] : selectedLineNumbers(selection);
		var replacements:Array<BufferReplacement> = [], changes:Map<Int, LineColumnChange> = [];
		for (line in lines) {
			var columns = desired[line];
			if (columns == null) continue;
			var text = buffer.line(line), count = leadingWhitespace(text);
			var replacement = Indentation.prefix(columns, tabWidth, insertSpaces);
			if (replacement == text.substring(0, count)) continue;
			replacements.push(new BufferReplacement(new BufferPosition(line, 0), new BufferPosition(line, count), replacement));
			changes.set(line, new LineColumnChange(0, replacement.length - count));
		}
		return apply(buffer, selection, replacements, changes, true);
	}

	public static function duplicateLines(buffer:TextBuffer, selection:BufferSelection):Bool {
		var spans = selectedLineSpans(selection), replacements:Array<BufferReplacement> = [];
		for (span in spans) {
			var at:BufferPosition, text:String, block = lineBlock(buffer, span.first, span.last);
			if (span.last + 1 < buffer.lineCount()) {
				at = new BufferPosition(span.last + 1, 0);
				text = block + "\n";
			} else {
				at = buffer.endPosition();
				text = "\n" + block;
			}
			replacements.push(new BufferReplacement(at, at, text));
		}
		var ranges:Array<BufferRange> = [];
		for (range in selection.allRanges())
			ranges.push(new BufferRange(duplicatePosition(range.cursor, spans), duplicatePosition(range.anchor, spans)));
		return buffer.applyReplacements(selection, replacements, null, null, new SelectionSnapshot(ranges, 0));
	}

	public static function deleteLines(buffer:TextBuffer, selection:BufferSelection):Bool {
		var spans = selectedLineSpans(selection), replacements:Array<BufferReplacement> = [], results:Array<BufferPosition> = [];
		for (span in spans) {
			var from:BufferPosition, to:BufferPosition, result:BufferPosition;
			if (span.last + 1 < buffer.lineCount()) {
				from = new BufferPosition(span.first, 0); to = new BufferPosition(span.last + 1, 0); result = from;
			} else if (span.first > 0) {
				from = new BufferPosition(span.first - 1, buffer.line(span.first - 1).length); to = buffer.endPosition(); result = from;
			} else {
				from = new BufferPosition(0, 0); to = buffer.endPosition(); result = from;
			}
			replacements.push(new BufferReplacement(from, to, ""));
			results.push(result);
		}
		var ranges:Array<BufferRange> = [];
		for (range in selection.allRanges()) {
			var spanIndex = containingSpan(range.start().line, spans), result = results[spanIndex], index = spanIndex;
			while (index > 0) {
				index--;
				var replacement = replacements[index], change = new BufferChange(replacement.from,
					buffer.textRange(replacement.from, replacement.to), "", replacement.to.line - replacement.from.line, 0, 0, 0);
				result = change.transform(result);
			}
			ranges.push(new BufferRange(result, result));
		}
		return buffer.applyReplacements(selection, replacements, null, null, new SelectionSnapshot(ranges, 0));
	}

	public static function moveLines(buffer:TextBuffer, selection:BufferSelection, direction:Int):Bool {
		var spans = selectedLineSpans(selection), replacements:Array<BufferReplacement> = [];
		for (span in spans) {
			var from:BufferPosition, to:BufferPosition, replacement:String;
			if (direction < 0) {
				if (span.first == 0) return false;
				from = new BufferPosition(span.first - 1, 0);
				to = span.last + 1 < buffer.lineCount() ? new BufferPosition(span.last + 1, 0) : buffer.endPosition();
				replacement = lineBlock(buffer, span.first, span.last) + "\n" + buffer.line(span.first - 1)
					+ (span.last + 1 < buffer.lineCount() ? "\n" : "");
			} else {
				if (span.last + 1 >= buffer.lineCount()) return false;
				from = new BufferPosition(span.first, 0);
				to = span.last + 2 < buffer.lineCount() ? new BufferPosition(span.last + 2, 0) : buffer.endPosition();
				replacement = buffer.line(span.last + 1) + "\n" + lineBlock(buffer, span.first, span.last)
					+ (span.last + 2 < buffer.lineCount() ? "\n" : "");
			}
			replacements.push(new BufferReplacement(from, to, replacement));
		}
		var ranges:Array<BufferRange> = [];
		for (range in selection.allRanges())
			ranges.push(new BufferRange(shiftedLine(range.cursor, direction), shiftedLine(range.anchor, direction)));
		return buffer.applyReplacements(selection, replacements, null, null, new SelectionSnapshot(ranges, 0));
	}

	public static function joinLines(buffer:TextBuffer, selection:BufferSelection):Bool {
		var joinLines:Array<Int> = [];
		for (range in selection.allRanges()) {
			var first = range.start().line, last = range.isCollapsed() ? first + 1 : range.end().line;
			if (!range.isCollapsed() && range.end().column == 0 && last > first) last--;
			if (last >= buffer.lineCount()) last = buffer.lineCount() - 1;
			for (line in first...last) if (joinLines.indexOf(line) < 0) joinLines.push(line);
		}
		joinLines.sort(function(left, right) return left - right);
		if (joinLines.length == 0) return false;
		var replacements:Array<BufferReplacement> = [];
		for (line in joinLines) {
			var left = buffer.line(line), right = buffer.line(line + 1), whitespace = leadingWhitespace(right), separator = " ";
			if (left.length == 0 || whitespace == right.length || isSpace(left.charCodeAt(left.length - 1))) separator = "";
			replacements.push(new BufferReplacement(new BufferPosition(line, left.length), new BufferPosition(line + 1, whitespace), separator));
		}
		var ranges:Array<BufferRange> = [];
		for (range in selection.allRanges()) {
			var first = range.start().line, shifted = first;
			for (line in joinLines) if (line < first) shifted--;
			var result = new BufferPosition(shifted, buffer.line(first).length + 1);
			ranges.push(new BufferRange(result, result));
		}
		return buffer.applyReplacements(selection, replacements, null, null, new SelectionSnapshot(ranges, 0));
	}

	public static function toggleLineComment(buffer:TextBuffer, selection:BufferSelection, syntax:SyntaxDefinition):Bool {
		var marker = syntax.lineComment;
		if (marker.length == 0) return false;
		var lines = selectedLineNumbers(selection), uncomment = true;
		for (line in lines) {
			var text = buffer.line(line), column = leadingWhitespace(text);
			if (text.substr(column, marker.length) != marker) uncomment = false;
		}
		var replacements:Array<BufferReplacement> = [], changes:Map<Int, LineColumnChange> = [];
		for (line in lines) {
			var text = buffer.line(line), column = leadingWhitespace(text);
			if (uncomment) {
				var count = marker.length;
				if (text.substr(column + count, 1) == " ") count++;
				replacements.push(new BufferReplacement(new BufferPosition(line, column), new BufferPosition(line, column + count), ""));
				changes.set(line, new LineColumnChange(column, -count));
			} else {
				var inserted = marker + " ";
				replacements.push(new BufferReplacement(new BufferPosition(line, column), new BufferPosition(line, column), inserted));
				changes.set(line, new LineColumnChange(column, inserted.length));
			}
		}
		return apply(buffer, selection, replacements, changes);
	}

	static function apply(buffer:TextBuffer, selection:BufferSelection, replacements:Array<BufferReplacement>, changes:Map<Int, LineColumnChange>, moveCollapsedAtInsertion:Bool = false):Bool {
		if (replacements.length == 0) return false;
		var ranges:Array<BufferRange> = [];
		for (range in selection.allRanges()) {
			var moveAtInsertion = moveCollapsedAtInsertion && range.isCollapsed();
			ranges.push(new BufferRange(adjust(range.cursor, changes, moveAtInsertion), adjust(range.anchor, changes, moveAtInsertion)));
		}
		return buffer.applyReplacements(selection, replacements, null, null, new SelectionSnapshot(ranges, 0));
	}

	static function adjust(position:BufferPosition, changes:Map<Int, LineColumnChange>, moveAtInsertion:Bool = false):BufferPosition {
		var change = changes.get(position.line);
		if (change == null || position.column < change.column || (position.column == change.column && !moveAtInsertion)) return position;
		var column = position.column + change.delta;
		if (column < change.column) column = change.column;
		return new BufferPosition(position.line, column);
	}

	static function selectedLines(selection:BufferSelection):EditorLineSpan {
		var first = selection.start().line, last = selection.end().line;
		if (selection.hasSelection() && selection.end().column == 0 && last > first) last--;
		return new EditorLineSpan(first, last);
	}

	static function selectedLineNumbers(selection:BufferSelection):Array<Int> {
		var lines:Array<Int> = [];
		for (range in selection.allRanges()) {
			var first = range.start().line, last = range.end().line;
			if (!range.isCollapsed() && range.end().column == 0 && last > first) last--;
			for (line in first...last + 1) if (lines.indexOf(line) < 0) lines.push(line);
		}
		lines.sort(function(left, right) return left - right);
		return lines;
	}

	static function selectedLineSpans(selection:BufferSelection):Array<EditorLineSpan> {
		var spans:Array<EditorLineSpan> = [];
		for (line in selectedLineNumbers(selection)) {
			if (spans.length == 0 || spans[spans.length - 1].last + 1 < line) spans.push(new EditorLineSpan(line, line));
			else spans[spans.length - 1] = new EditorLineSpan(spans[spans.length - 1].first, line);
		}
		return spans;
	}

	static function containingSpan(line:Int, spans:Array<EditorLineSpan>):Int {
		for (index in 0...spans.length) if (line >= spans[index].first && line <= spans[index].last) return index;
		return 0;
	}

	static function duplicatePosition(position:BufferPosition, spans:Array<EditorLineSpan>):BufferPosition {
		var shift = 0;
		for (span in spans) {
			var count = span.last - span.first + 1;
			if (position.line > span.last) shift += count;
			else if (position.line >= span.first) {
				shift += count;
				break;
			} else break;
		}
		return new BufferPosition(position.line + shift, position.column);
	}

	static function lineBlock(buffer:TextBuffer, first:Int, last:Int):String {
		var lines:Array<String> = [];
		for (line in first...last + 1) lines.push(buffer.line(line));
		return lines.join("\n");
	}

	static function leadingWhitespace(text:String):Int {
		var result = 0;
		while (result < text.length && isSpace(text.charCodeAt(result))) result++;
		return result;
	}

	static function indentationUnit(tabWidth:Int, insertSpaces:Bool):String {
		if (!insertSpaces) return "\t";
		var result = "";
		for (index in 0...tabWidth) result += " ";
		return result;
	}

	static function shiftedLine(position:BufferPosition, delta:Int):BufferPosition
		return new BufferPosition(position.line + delta, position.column);

	static function isSpace(code:Int):Bool return code == 9 || code == 32;
}

private class EditorLineSpan {
	public final first:Int;
	public final last:Int;
	public function new(first:Int, last:Int) {
		this.first = first;
		this.last = last;
	}
}

private class LineColumnChange {
	public final column:Int;
	public final delta:Int;
	public function new(column:Int, delta:Int) {
		this.column = column;
		this.delta = delta;
	}
}
