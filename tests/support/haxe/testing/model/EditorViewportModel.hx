package testing.model;

import editor.Document;
import editor.BufferPosition;
import editor.BufferSelection;
import editor.BufferRange;
import editor.EditorClock;
import editor.EditorClock.SystemEditorClock;
import editor.VisualLineMap;
import editor.VisualLine;

import syntax.HighlightToken;
import style.Theme;
import search.SearchMatch;
import plugin.PluginDecorationRegistry;
import plugin.PluginDecoration;
import platform.TextInputArea;

class EditorViewportModel {
	public static inline final HEADER_HEIGHT = 42;
	public static inline final GUTTER_WIDTH = 52;
	public static inline final PADDING = 12;
	public static inline final SCROLLBAR_SIZE = 8;

	public final document:Document;
	public final metrics:testing.model.ModelTextMetrics;
	public final theme:Theme;
	public final selection:BufferSelection;
	public final visualLines:VisualLineMap;
	final clock:EditorClock;
	final decorations:Null<PluginDecorationRegistry>;
	public var x(default, null):Int = 0;
	public var y(default, null):Int = 0;
	public var width(default, null):Int;
	public var height(default, null):Int;
	public var scrollX(default, null):Int = 0;
	public var scrollY(default, null):Int = 0;
	public final searchMatches:Array<SearchMatch> = [];
	var mouseSelecting = false;
	var dragMouseX:Int = 0;
	var dragMouseY:Int = 0;
	var lastDragScroll:Float = -1.0;
	var draggingVerticalScrollbar:Bool = false;
	var draggingHorizontalScrollbar:Bool = false;
	var wordWrap:Bool = false;
	var mappedStateId:Int = -1;
	var measuredVisualRevision:Int = -1;
	var measuredMaximumWidth:Int = 0;
	var preferredVisualColumn:Int = -1;
	public var compositionText(default, null):String = "";
	var compositionStart:Int = 0;
	var compositionLength:Int = 0;

	public function new(document:Document, metrics:testing.model.ModelTextMetrics, theme:Theme, width:Int, height:Int, ?selection:BufferSelection, ?clock:EditorClock,
			?decorations:PluginDecorationRegistry) {
		this.document = document;
		this.metrics = metrics;
		this.theme = theme;
		this.selection = selection == null ? new BufferSelection() : selection;
		visualLines = new VisualLineMap(document.buffer);
		mappedStateId = document.buffer.stateId;
		this.clock = clock == null ? new SystemEditorClock() : clock;
		this.decorations = decorations;
		resize(width, height);
	}

	public function resize(width:Int, height:Int):Void {
		this.width = width;
		this.height = height;
		clampScroll();
	}

	public function setBounds(x:Int, y:Int, width:Int, height:Int):Void {
		this.x = x;
		this.y = y;
		resize(width, height);
	}

	public function moveVertical(delta:Int, extend:Bool):Void {
		syncVisualLines();
		revealSelections();
		if (selection.rangeCount() > 1) {
			var moved:Array<BufferRange> = [];
			for (range in selection.allRanges()) {
				var row = visualLines.lineAt(visualLines.rowAt(range.cursor)), target = visualLines.moveVertical(range.cursor, delta,
					range.cursor.column - row.startColumn);
				moved.push(new BufferRange(target, extend ? range.anchor : target));
			}
			selection.setRanges(document.buffer, moved);
			revealSelections();
			ensureCaretVisible();
			return;
		}
		var source = visualLines.lineAt(visualLines.rowAt(selection.cursor));
		if (preferredVisualColumn < 0) preferredVisualColumn = selection.cursor.column - source.startColumn;
		var target = visualLines.moveVertical(selection.cursor, delta, preferredVisualColumn);
		visualLines.reveal(target);
		selection.setCursor(document.buffer, target, extend);
		ensureCaretVisible();
	}

	public function movePage(delta:Int, extend:Bool):Void {
		var lines = Std.int((height - HEADER_HEIGHT - PADDING) / metrics.lineHeight);
		if (lines < 1) lines = 1;
		moveVertical(delta * lines, extend);
		ensureCaretVisible();
	}

	public function cursorChanged():Void {
		preferredVisualColumn = -1;
		syncVisualLines();
		revealSelections();
		ensureCaretVisible();
	}

	public function setWordWrap(enabled:Bool):Void {
		wordWrap = enabled;
		syncVisualLines(true);
		ensureCaretVisible();
	}

	public function toggleWordWrap():Bool {
		setWordWrap(!wordWrap);
		return wordWrap;
	}

	public function toggleCurrentFold():Bool {
		var line = selection.cursor.line, value = document.buffer.line(line), brace = value.indexOf("{", selection.cursor.column), end = -1;
		if (brace < 0) brace = value.indexOf("{");
		if (brace >= 0) {
			var pair = document.matchingBrackets(new BufferPosition(line, brace));
			if (pair != null && pair.second.line > line) end = pair.second.line;
		}
		if (end < 0) end = indentationFoldEnd(line);
		return end > line && toggleFold(line, end);
	}

	public function toggleFold(startLine:Int, endLine:Int):Bool {
		syncVisualLines();
		var collapsed = visualLines.toggleFold(startLine, endLine);
		revealSelections();
		clampScroll();
		return collapsed;
	}

	public function restoreScroll(x:Int, y:Int):Void {
		scrollX = x;
		scrollY = y;
		clampScroll();
	}

	public function setSearchMatches(matches:Array<SearchMatch>):Void {
		searchMatches.resize(0);
		for (match in matches) searchMatches.push(match);
	}

	public function setComposition(text:String, start:Int, length:Int):Void {
		compositionText = text;
		compositionStart = start < 0 ? 0 : start;
		compositionLength = length < 0 ? 0 : length;
	}

	public function clearComposition():Void {
		compositionText = "";
		compositionStart = 0;
		compositionLength = 0;
	}

	public function textInputArea():TextInputArea {
		syncVisualLines();
		var rowIndex = visualLines.rowAt(selection.cursor), row = visualLines.lineAt(rowIndex), value = document.buffer.line(row.documentLine),
			caretX = x + GUTTER_WIDTH - scrollX + metrics.textWidth(value.substring(row.startColumn, selection.cursor.column)),
			caretY = y + HEADER_HEIGHT + PADDING + rowIndex * metrics.lineHeight - scrollY;
		return new TextInputArea(caretX, caretY, 2, metrics.lineHeight);
	}

	public function wheel(verticalHundredths:Int, horizontalHundredths:Int):Void {
		scrollY -= Std.int(verticalHundredths * metrics.lineHeight * 3 / 100);
		scrollX -= Std.int(horizontalHundredths * metrics.lineHeight * 3 / 100);
		clampScroll();
	}

	public function mouseDown(button:Int, x:Int, y:Int, clicks:Int = 1):Void {
		if (button != 1) return;
		if (x >= this.x + width - SCROLLBAR_SIZE && y >= this.y + HEADER_HEIGHT + PADDING && y < this.y + height - SCROLLBAR_SIZE) {
			draggingVerticalScrollbar = true;
			updateVerticalScrollbar(y);
			return;
		}
		if (y >= this.y + height - SCROLLBAR_SIZE && x >= this.x + GUTTER_WIDTH && x < this.x + width - SCROLLBAR_SIZE) {
			draggingHorizontalScrollbar = true;
			updateHorizontalScrollbar(x);
			return;
		}
		if (!insideText(x, y)) return;
		var position = positionFromPoint(x, y), buffer = document.buffer;
		if (clicks >= 3) {
			var from = new BufferPosition(position.line, 0), to = position.line + 1 < buffer.lineCount()
				? new BufferPosition(position.line + 1, 0) : new BufferPosition(position.line, buffer.line(position.line).length);
			selection.restore(buffer, to, from);
		} else if (clicks == 2)
			selection.restore(buffer, buffer.wordEndAt(position), buffer.wordStartAt(position));
		else selection.setCursor(buffer, position);
		mouseSelecting = true;
		dragMouseX = x;
		dragMouseY = y;
		lastDragScroll = -1.0;
		ensureCaretVisible();
	}

	public function mouseMove(x:Int, y:Int):Void {
		if (draggingVerticalScrollbar) { updateVerticalScrollbar(y); return; }
		if (draggingHorizontalScrollbar) { updateHorizontalScrollbar(x); return; }
		if (!mouseSelecting)
			return;
		dragMouseX = x;
		dragMouseY = y;
		selection.setCursor(document.buffer, positionFromPoint(x, y), true);
		updateDragAutoscroll();
		ensureCaretVisible();
	}

	public function mouseUp(button:Int):Void {
		if (button == 1) {
			mouseSelecting = false;
			draggingVerticalScrollbar = false;
			draggingHorizontalScrollbar = false;
		}
	}

	static function utf16Column(value:String, characters:Int):Int {
		var column = 0, remaining = characters;
		while (column < value.length && remaining > 0) {
			var code = value.charCodeAt(column++);
			if (code >= 0xd800 && code <= 0xdbff && column < value.length) {
				var next = value.charCodeAt(column);
				if (next >= 0xdc00 && next <= 0xdfff) column++;
			}
			remaining--;
		}
		return column;
	}

	public function update():Void { updateDragAutoscroll(); syncVisualLines(); }

	function updateDragAutoscroll():Void {
		if (!mouseSelecting) return;
		var top = y + HEADER_HEIGHT + PADDING, bottom = y + height, direction = 0;
		if (dragMouseY < top) direction = -1 - Std.int((top - dragMouseY) / metrics.lineHeight);
		else if (dragMouseY >= bottom) direction = 1 + Std.int((dragMouseY - bottom) / metrics.lineHeight);
		if (direction == 0) return;
		var now = clock.now();
		if (lastDragScroll >= 0 && now - lastDragScroll < 0.05) return;
		lastDragScroll = now;
		scrollY += direction * metrics.lineHeight;
		clampScroll();
		var targetY = direction < 0 ? top : bottom - 1;
		selection.setCursor(document.buffer, positionFromPoint(dragMouseX, targetY), true);
	}

	function ensureCaretVisible():Void {
		syncVisualLines();
		revealSelections();
		var buffer = document.buffer, lineHeight = metrics.lineHeight, viewportHeight = height - HEADER_HEIGHT - PADDING - SCROLLBAR_SIZE,
			viewportWidth = width - GUTTER_WIDTH - SCROLLBAR_SIZE, row = visualLines.lineAt(visualLines.rowAt(selection.cursor)),
			caretY = visualLines.rowAt(selection.cursor) * lineHeight,
			caretX = metrics.textWidth(buffer.line(selection.cursor.line).substring(row.startColumn, selection.cursor.column)),
			context = lineHeight;
		if (caretY - context < scrollY)
			scrollY = caretY - context;
		else if (caretY + lineHeight + context > scrollY + viewportHeight)
			scrollY = caretY + lineHeight + context - viewportHeight;
		if (caretX < scrollX)
			scrollX = caretX;
		else if (caretX + PADDING > scrollX + viewportWidth)
			scrollX = caretX + PADDING - viewportWidth;
		clampScroll();
	}

	function clampScroll():Void {
		syncVisualLines();
		var maxY = visualLines.rowCount() * metrics.lineHeight - (height - HEADER_HEIGHT - PADDING - SCROLLBAR_SIZE);
		if (maxY < 0)
			maxY = 0;
		if (scrollY < 0)
			scrollY = 0;
		else if (scrollY > maxY)
			scrollY = maxY;
		if (scrollX < 0)
			scrollX = 0;
		var maxX = maximumLineWidth() - (width - GUTTER_WIDTH - SCROLLBAR_SIZE);
		if (maxX < 0) maxX = 0;
		if (scrollX > maxX) scrollX = maxX;
	}

	function maximumLineWidth():Int {
		if (measuredVisualRevision == visualLines.revision) return measuredMaximumWidth;
		var result = 0;
		for (index in 0...visualLines.rowCount()) {
			var row = visualLines.lineAt(index);
			var width = metrics.textWidth(document.buffer.line(row.documentLine).substring(row.startColumn, row.endColumn));
			if (width > result) result = width;
		}
		measuredMaximumWidth = result;
		measuredVisualRevision = visualLines.revision;
		return measuredMaximumWidth;
	}

	function updateVerticalScrollbar(pointerY:Int):Void {
		syncVisualLines();
		var viewport = height - HEADER_HEIGHT - PADDING - SCROLLBAR_SIZE, maximum = visualLines.rowCount() * metrics.lineHeight - viewport;
		if (maximum <= 0 || viewport <= 0) { scrollY = 0; return; }
		var position = pointerY - y - HEADER_HEIGHT - PADDING;
		if (position < 0) position = 0;
		if (position > viewport) position = viewport;
		scrollY = Std.int(position * maximum / viewport);
		clampScroll();
	}

	function updateHorizontalScrollbar(pointerX:Int):Void {
		syncVisualLines();
		var viewport = width - GUTTER_WIDTH - SCROLLBAR_SIZE, maximum = maximumLineWidth() - viewport;
		if (maximum <= 0 || viewport <= 0) { scrollX = 0; return; }
		var position = pointerX - x - GUTTER_WIDTH;
		if (position < 0) position = 0;
		if (position > viewport) position = viewport;
		scrollX = Std.int(position * maximum / viewport);
		clampScroll();
	}

	function insideText(x:Int, y:Int):Bool
		return x >= this.x + GUTTER_WIDTH && x < this.x + width - SCROLLBAR_SIZE
			&& y >= this.y + HEADER_HEIGHT + PADDING && y < this.y + height - SCROLLBAR_SIZE;

	function positionFromPoint(x:Int, y:Int):BufferPosition {
		syncVisualLines();
		var buffer = document.buffer, rowIndex = Std.int((y - this.y - HEADER_HEIGHT - PADDING + scrollY) / metrics.lineHeight);
		if (rowIndex < 0) rowIndex = 0;
		else if (rowIndex >= visualLines.rowCount()) rowIndex = visualLines.rowCount() - 1;
		var row = visualLines.lineAt(rowIndex), value = buffer.line(row.documentLine), targetX = x - this.x - GUTTER_WIDTH + scrollX,
			column = row.startColumn;
		while (column < row.endColumn) {
			var left = metrics.textWidth(value.substring(row.startColumn, column)), right = metrics.textWidth(value.substring(row.startColumn, column + 1));
			if (targetX < Std.int((left + right) / 2))
				break;
			column++;
		}
		return buffer.positionAt(row.documentLine, column);
	}

	function syncVisualLines(force:Bool = false):Void {
		var columns = 0;
		if (wordWrap) {
			var available = width - GUTTER_WIDTH - SCROLLBAR_SIZE - PADDING, cell = metrics.textWidth("M");
			if (cell < 1) cell = 1;
			columns = Std.int(available / cell);
			if (columns < 1) columns = 1;
		}
		if (visualLines.wrapColumns != columns) visualLines.setWrapColumns(columns);
		if (force || mappedStateId != document.buffer.stateId) {
			visualLines.rebuild();
			mappedStateId = document.buffer.stateId;
		}
	}

	function revealSelections():Void {
		for (range in selection.allRanges()) {
			visualLines.reveal(range.cursor);
			visualLines.reveal(range.anchor);
		}
	}

	function indentationFoldEnd(startLine:Int):Int {
		var buffer = document.buffer, base = indentation(buffer.line(startLine)), end = startLine;
		for (line in startLine + 1...buffer.lineCount()) {
			var value = buffer.line(line);
			if (StringTools.trim(value).length == 0) {
				if (end > startLine) end = line;
				continue;
			}
			if (indentation(value) <= base) break;
			end = line;
		}
		return end;
	}

	static function indentation(value:String):Int {
		var result = 0;
		while (result < value.length) {
			var code = value.charCodeAt(result);
			if (code != 32 && code != 9) break;
			result++;
		}
		return result;
	}

}
