package editor;

import nativekit.editorkit.TextDocument;

class TextBuffer {
	final lines:Array<String>;
	final changeListeners:Map<Int, BufferChangeListener> = [];
	var nextListenerId:Int = 1;
	public var stateId(default, null):Int = 0;
	var nextStateId:Int = 1;
	final undoStack:Array<BufferTransaction> = [];
	final redoStack:Array<BufferTransaction> = [];
	var historyGroupOpen:Bool = false;
	final transactionEdits:Array<BufferEdit> = [];
	var inTransaction:Bool = false;
	public var text(get, never):String;
	/**
	 * The single EditorKit document backing this buffer, shared with
	 * `TextArea.withDocument` so the UIKit editor renders and edits the exact
	 * same text. Every mutation applied through this buffer's own API (insert,
	 * replace, undo, redo, ...) mirrors into this document from the single
	 * `replaceRaw` choke point. A mutation that arrives the other way, as a
	 * widget-originated `EditTransaction` from `applyEditTransaction`, has
	 * already been applied to this document by the widget itself, so mirroring
	 * is suppressed for that one call to avoid a feedback loop.
	 */
	public var document(default, null):TextDocument;
	var mirrorDocumentEdits:Bool = true;

	public function new(?text:String) {
		var initial = text == null ? "" : text;
		lines = splitLines(initial);
		document = new TextDocument(initial);
	}

	function get_text():String
		return lines.join("\n");

	public function lineCount():Int
		return lines.length;

	public function line(index:Int):String
		return index < 0 || index >= lines.length ? "" : lines[index];

	/** Registers a listener and returns its idempotent owned subscription. */
	public function subscribe(listener:BufferChangeListener):BufferSubscription {
		var id = nextListenerId++;
		changeListeners.set(id, listener);
		return new BufferSubscription(this, id);
	}

	@:allow(editor.BufferSubscription)
	function releaseSubscription(id:Int):Void
		changeListeners.remove(id);

	public function insert(selection:BufferSelection, value:String, typing:Bool = false):Bool {
		if (value.length == 0 && !selection.hasSelection()) return false;
		return replace(selection, selection.start(), selection.end(), value, typing ? "typing" : "");
	}

	public function replaceRange(selection:BufferSelection, from:BufferPosition, to:BufferPosition, value:String):Bool
		return replace(selection, from, to, value);

	public function replaceAllText(value:String, ?selection:BufferSelection):Bool {
		var owner = selection == null ? new BufferSelection() : selection;
		return replace(owner, new BufferPosition(0, 0), endPosition(), value);
	}

	/** Applies non-overlapping replacements from the end of the document as one undo unit. */
	public function applyReplacements(selection:BufferSelection, replacements:Array<BufferReplacement>, ?cursorAfter:BufferPosition,
			?anchorAfter:BufferPosition, ?finalSelection:SelectionSnapshot):Bool {
		if (inTransaction || replacements.length == 0) return false;
		var selectionBefore = selection.snapshot();
		var ordered:Array<BufferReplacement> = [];
		for (replacement in replacements) {
			var from = positionAt(replacement.from.line, replacement.from.column), to = positionAt(replacement.to.line, replacement.to.column);
			if (to.before(from)) {
				var swap = from;
				from = to;
				to = swap;
			}
			ordered.push(new BufferReplacement(from, to, replacement.text));
		}
		ordered.sort(function(left, right) {
			var leftStart = positionAt(left.from.line, left.from.column), rightStart = positionAt(right.from.line, right.from.column);
			if (leftStart.line != rightStart.line) return rightStart.line - leftStart.line;
			return rightStart.column - leftStart.column;
		});
		for (index in 0...ordered.length - 1) {
			var higherStart = positionAt(ordered[index].from.line, ordered[index].from.column),
				lowerEnd = positionAt(ordered[index + 1].to.line, ordered[index + 1].to.column);
			if (higherStart.before(lowerEnd)) return false;
		}
		breakHistoryGroup();
		transactionEdits.resize(0);
		inTransaction = true;
		for (replacement in ordered)
			replace(selection, replacement.from, replacement.to, replacement.text);
		inTransaction = false;
		var completed = transactionEdits.copy();
		transactionEdits.resize(0);
		if (completed.length == 0) return false;
		var transaction = new BufferTransaction(completed[0], "", selectionBefore, selection.snapshot());
		for (index in 1...completed.length) transaction.edits.push(completed[index]);
		if (finalSelection != null) {
			selection.restoreSnapshot(this, finalSelection, false);
			transaction.setSelectionAfter(selection.snapshot());
		} else if (cursorAfter != null && anchorAfter != null) {
			selection.restore(this, cursorAfter, anchorAfter, false);
			transaction.setFinalSelection(selection.cursor, selection.anchor);
			transaction.setSelectionAfter(selection.snapshot());
		}
		undoStack.push(transaction);
		redoStack.resize(0);
		return true;
	}

	public function replaceSelections(selection:BufferSelection, values:Array<String>):Bool {
		var ranges = selection.allRanges();
		return replaceSelectionRanges(selection, ranges, values);
	}

	public function deleteSelections(selection:BufferSelection, backwards:Bool):Bool {
		var ranges:Array<BufferRange> = [];
		for (range in selection.allRanges()) {
			if (!range.isCollapsed()) ranges.push(range);
			else {
				var other = positionOffset(range.cursor, backwards ? -1 : 1);
				ranges.push(backwards ? new BufferRange(range.cursor, other) : new BufferRange(other, range.cursor));
			}
		}
		return replaceSelectionRanges(selection, ranges, [""]);
	}

	function replaceSelectionRanges(selection:BufferSelection, ranges:Array<BufferRange>, values:Array<String>):Bool {
		if (values.length != 1 && values.length != ranges.length) return false;
		var pending:Array<PendingSelectionEdit> = [];
		for (index in 0...ranges.length)
			pending.push(new PendingSelectionEdit(ranges[index], values.length == 1 ? values[0] : "", index == 0));
		pending.sort(function(left, right) {
			var leftStart = left.range.start(), rightStart = right.range.start();
			if (leftStart.line != rightStart.line) return leftStart.line - rightStart.line;
			return leftStart.column - rightStart.column;
		});
		if (values.length > 1) for (index in 0...pending.length) pending[index].value = values[index];
		var replacements:Array<BufferReplacement> = [], finalRanges:Array<BufferRange> = [], primary = 0;
		for (index in 0...pending.length) {
			var item = pending[index], position = advance(item.range.start(), item.value), lower = index;
			while (lower > 0) {
				lower--;
				var prior = pending[lower], change = new BufferChange(prior.range.start(), textRange(prior.range.start(), prior.range.end()),
					prior.value, prior.range.end().line - prior.range.start().line, prior.value.split("\n").length - 1, 0, 0);
				position = change.transform(position);
			}
			if (item.primary) primary = finalRanges.length;
			finalRanges.push(new BufferRange(position, position));
			replacements.push(new BufferReplacement(item.range.start(), item.range.end(), item.value));
		}
		return applyReplacements(selection, replacements, null, null, new SelectionSnapshot(finalRanges, primary));
	}

	public function deleteBackward(selection:BufferSelection):Bool {
		if (selection.hasSelection()) return replace(selection, selection.start(), selection.end(), "");
		var start = positionOffset(selection.cursor, -1);
		return start.equals(selection.cursor) ? false : replace(selection, start, selection.cursor, "");
	}

	public function deleteForward(selection:BufferSelection):Bool {
		if (selection.hasSelection()) return replace(selection, selection.start(), selection.end(), "");
		var end = positionOffset(selection.cursor, 1);
		return end.equals(selection.cursor) ? false : replace(selection, selection.cursor, end, "");
	}

	public function undo(selection:BufferSelection):Bool {
		if (undoStack.length == 0) return false;
		var transaction = undoStack.pop();
		if (transaction == null) return false;
		var index = transaction.edits.length;
		while (index > 0) {
			index--;
			var edit = transaction.edits[index];
			replaceRaw(edit.start, advance(edit.start, edit.inserted), edit.removed, edit.stateAfter, edit.stateBefore);
		}
		selection.restoreSnapshot(this, transaction.selectionBefore, false);
		stateId = transaction.stateBefore;
		redoStack.push(transaction);
		historyGroupOpen = false;
		return true;
	}

	public function redo(selection:BufferSelection):Bool {
		if (redoStack.length == 0) return false;
		var transaction = redoStack.pop();
		if (transaction == null) return false;
		for (edit in transaction.edits)
			replaceRaw(edit.start, advance(edit.start, edit.removed), edit.inserted, edit.stateBefore, edit.stateAfter);
		selection.restoreSnapshot(this, transaction.getSelectionAfter(), false);
		stateId = transaction.stateAfter;
		undoStack.push(transaction);
		historyGroupOpen = false;
		return true;
	}

	public function breakHistoryGroup():Void
		historyGroupOpen = false;

	public function positionAt(line:Int, column:Int):BufferPosition
		return sanitize(new BufferPosition(line, column));

	public function positionOffset(position:BufferPosition, offset:Int):BufferPosition {
		var result = sanitize(position), remaining = offset;
		while (remaining < 0) {
			if (result.column > 0) {
				var column = result.column - 1;
				if (column > 0 && isLowSurrogate(lines[result.line].charCodeAt(column))
					&& isHighSurrogate(lines[result.line].charCodeAt(column - 1))) column--;
				result = new BufferPosition(result.line, column);
				remaining++;
			} else if (result.line > 0) {
				result = new BufferPosition(result.line - 1, lines[result.line - 1].length);
				remaining++;
			} else break;
		}
		while (remaining > 0) {
			var value = lines[result.line];
			if (result.column < value.length) {
				var column = result.column + 1;
				if (column < value.length && isHighSurrogate(value.charCodeAt(result.column))
					&& isLowSurrogate(value.charCodeAt(column))) column++;
				result = new BufferPosition(result.line, column);
				remaining--;
			} else if (result.line + 1 < lines.length) {
				result = new BufferPosition(result.line + 1, 0);
				remaining--;
			} else break;
		}
		return result;
	}

	public function characterCodeAt(position:BufferPosition):Int {
		var value = sanitize(position);
		if (value.column < lines[value.line].length) return lines[value.line].charCodeAt(value.column);
		return value.line + 1 < lines.length ? 10 : -1;
	}

	public function wordStartAt(position:BufferPosition):BufferPosition {
		var result = sanitize(position);
		if (!isWordCode(characterCodeAt(result))) return result;
		while (result.line != 0 || result.column != 0) {
			var previous = positionOffset(result, -1);
			if (!isWordCode(characterCodeAt(previous))) break;
			result = previous;
		}
		return result;
	}

	public function wordEndAt(position:BufferPosition):BufferPosition {
		var result = sanitize(position), end = endPosition();
		if (!isWordCode(characterCodeAt(result))) return positionOffset(result, 1);
		while (!result.equals(end) && isWordCode(characterCodeAt(result))) result = positionOffset(result, 1);
		return result;
	}

	public function textRange(from:BufferPosition, to:BufferPosition):String {
		var start = sanitize(from), end = sanitize(to);
		if (end.before(start)) {
			var swap = start;
			start = end;
			end = swap;
		}
		if (start.line == end.line) return lines[start.line].substring(start.column, end.column);
		var parts = [lines[start.line].substring(start.column)];
		for (lineIndex in start.line + 1...end.line) parts.push(lines[lineIndex]);
		parts.push(lines[end.line].substring(0, end.column));
		return parts.join("\n");
	}

	public function offsetOf(position:BufferPosition):Int {
		var value = sanitize(position), offset = value.column;
		for (lineIndex in 0...value.line) offset += lines[lineIndex].length + 1;
		return offset;
	}

	public function positionFromOffset(offset:Int):BufferPosition {
		var remaining = offset < 0 ? 0 : offset;
		for (lineIndex in 0...lines.length) {
			if (remaining <= lines[lineIndex].length) return sanitize(new BufferPosition(lineIndex, remaining));
			remaining -= lines[lineIndex].length + 1;
		}
		return endPosition();
	}

	function replace(selection:BufferSelection, from:BufferPosition, to:BufferPosition, value:String, group:String = ""):Bool {
		var start = sanitize(from), end = sanitize(to);
		if (end.before(start)) {
			var swap = start;
			start = end;
			end = swap;
		}
		var removed = textRange(start, end), beforeCursor = selection.cursor, beforeAnchor = selection.anchor, beforeState = stateId,
			selectionBefore = selection.snapshot();
		if (removed == value) return false;
		var afterState = nextStateId++;
		replaceRaw(start, end, value, beforeState, afterState);
		selection.collapse(this, advance(start, value), false);
		stateId = afterState;
		var edit = new BufferEdit(start, removed, value, beforeCursor, beforeAnchor, selection.cursor, selection.anchor, beforeState, stateId);
		if (inTransaction) transactionEdits.push(edit);
		else {
			var previous = undoStack.length == 0 ? null : undoStack[undoStack.length - 1];
			if (historyGroupOpen && previous != null && previous.canAppend(edit, group)) {
				previous.edits.push(edit);
				previous.setSelectionAfter(selection.snapshot());
			} else undoStack.push(new BufferTransaction(edit, group, selectionBefore, selection.snapshot()));
		}
		historyGroupOpen = group.length > 0;
		if (!inTransaction) redoStack.resize(0);
		return true;
	}

	function replaceRaw(from:BufferPosition, to:BufferPosition, value:String, stateBefore:Int, stateAfter:Int):Void {
		var removed = textRange(from, to);
		var startCodepoint = mirrorDocumentEdits ? codepointOffset(from) : 0;
		var endCodepoint = mirrorDocumentEdits ? codepointOffset(to) : 0;
		var replacement = splitLines(value), prefix = lines[from.line].substring(0, from.column), suffix = lines[to.line].substring(to.column);
		replacement[0] = prefix + replacement[0];
		replacement[replacement.length - 1] += suffix;
		lines.splice(from.line, to.line - from.line + 1);
		for (index in 0...replacement.length) lines.insert(from.line + index, replacement[index]);
		if (mirrorDocumentEdits) document.replace(startCodepoint, endCodepoint, value);
		var change = new BufferChange(from, removed, value, to.line - from.line, replacement.length - 1, stateBefore, stateAfter);
		var listeners = [for (listener in changeListeners) listener];
		for (listener in listeners) listener(change);
	}

	/**
	 * Replays one UIKit `TextArea.withDocument` edit transaction onto this
	 * buffer as a normal `BufferChange`/undo entry, notifying every buffer
	 * subscriber (plugins, LSP, search, recovery). The widget's shared
	 * `document` already holds the post-edit text, so this call does not
	 * mirror back into it.
	 */
	public function applyEditTransaction(selection:BufferSelection,
			transaction:nativekit.ui.widgets.text.EditTransaction):Bool {
		var from = positionFromCodepointOffset(transaction.replacementStart);
		var to = positionFromCodepointOffset(transaction.replacementEnd);
		var value = transaction.replacementText == null ? "" : transaction.replacementText;
		mirrorDocumentEdits = false;
		var applied = replace(selection, from, to, value, "typing");
		mirrorDocumentEdits = true;
		return applied;
	}

	/** Converts a line/column position to a codepoint offset into `document`. */
	function codepointOffset(position:BufferPosition):Int {
		var offset = 0;
		for (index in 0...position.line) offset += codepointCountOf(lines[index]) + 1;
		return offset + codepointCountOf(lines[position.line].substring(0, position.column));
	}

	/** Converts a codepoint offset into `document` back to a line/column position. */
	function positionFromCodepointOffset(offset:Int):BufferPosition {
		var remaining = offset < 0 ? 0 : offset;
		for (lineIndex in 0...lines.length) {
			var count = codepointCountOf(lines[lineIndex]);
			if (remaining <= count) return sanitize(new BufferPosition(lineIndex, codepointIndexToColumn(lines[lineIndex], remaining)));
			remaining -= count + 1;
		}
		return endPosition();
	}

	static function codepointCountOf(value:String):Int {
		var count = 0, index = 0;
		while (index < value.length) {
			var code = value.charCodeAt(index);
			index += isHighSurrogate(code) && index + 1 < value.length && isLowSurrogate(value.charCodeAt(index + 1)) ? 2 : 1;
			count++;
		}
		return count;
	}

	static function codepointIndexToColumn(value:String, codepointIndex:Int):Int {
		var column = 0, count = 0;
		while (count < codepointIndex && column < value.length) {
			var code = value.charCodeAt(column);
			column += isHighSurrogate(code) && column + 1 < value.length && isLowSurrogate(value.charCodeAt(column + 1)) ? 2 : 1;
			count++;
		}
		return column;
	}

	function advance(start:BufferPosition, value:String):BufferPosition {
		var inserted = splitLines(value);
		return inserted.length == 1 ? new BufferPosition(start.line, start.column + inserted[0].length) :
			new BufferPosition(start.line + inserted.length - 1, inserted[inserted.length - 1].length);
	}

	function sanitize(position:BufferPosition):BufferPosition {
		var line = position.line < 0 ? 0 : position.line >= lines.length ? lines.length - 1 : position.line,
			column = position.column < 0 ? 0 : position.column > lines[line].length ? lines[line].length : position.column;
		if (column > 0 && column < lines[line].length && isLowSurrogate(lines[line].charCodeAt(column))
			&& isHighSurrogate(lines[line].charCodeAt(column - 1))) column--;
		return new BufferPosition(line, column);
	}

	public function endPosition():BufferPosition
		return new BufferPosition(lines.length - 1, lines[lines.length - 1].length);

	static function splitLines(value:String):Array<String> {
		var result = value.split("\n");
		return result.length == 0 ? [""] : result;
	}

	static function isHighSurrogate(code:Int):Bool
		return code >= 0xD800 && code <= 0xDBFF;

	static function isLowSurrogate(code:Int):Bool
		return code >= 0xDC00 && code <= 0xDFFF;

	static function isWordCode(code:Int):Bool
		return code >= 48 && code <= 57 || code >= 65 && code <= 90 || code >= 97 && code <= 122 || code == 95 || code >= 128;
}

typedef BufferChangeListener = BufferChange -> Void;

private class PendingSelectionEdit {
	public final range:BufferRange;
	public var value:String;
	public final primary:Bool;
	public function new(range:BufferRange, value:String, primary:Bool) {
		this.range = range;
		this.value = value;
		this.primary = primary;
	}
}
