package testing.model;

import view.View;
import view.LayoutKind;

import editor.Document;
import testing.model.EditorViewportModel;
import style.Theme;
import search.SearchMatch;
import editor.BufferPosition;
import editor.BufferChange;
import editor.BufferSubscription;
import testing.model.ModelClipboard;
import editor.EditorActions;
import plugin.PluginDecorationRegistry;
import platform.TextInputArea;

class ModelDocumentView extends View {
	public final document:Document;
	public final editor:EditorViewportModel;
	final bufferSubscription:BufferSubscription;

	public function new(document:Document, metrics:testing.model.ModelTextMetrics, theme:Theme, width:Int, height:Int, decorations:PluginDecorationRegistry) {
		super(document.title);
		this.document = document;
		editor = new EditorViewportModel(document, metrics, theme, width, height, null, null, decorations);
		bufferSubscription = document.buffer.subscribe(bufferChanged);
	}

	override public function isDirty():Bool
		return document.dirty;

	override public function getDocument():Null<Document>
		return document;
	override public function getSelection():Null<editor.BufferSelection>
		return editor.selection;

	override public function moveVertical(delta:Int, extend:Bool):Void {
		editor.moveVertical(delta, extend);
	}

	override public function moveHorizontal(delta:Int, extend:Bool):Void
		editor.selection.move(document.buffer, delta, extend);
	override public function moveHome(extend:Bool):Void editor.selection.moveHome(document.buffer, extend);
	override public function moveEnd(extend:Bool):Void editor.selection.moveEnd(document.buffer, extend);
	override public function moveWord(direction:Int, extend:Bool):Void editor.selection.moveWord(document.buffer, direction, extend);
	override public function moveDocumentStart(extend:Bool):Void editor.selection.moveDocumentStart(document.buffer, extend);
	override public function moveDocumentEnd(extend:Bool):Void editor.selection.moveDocumentEnd(document.buffer, extend);
	override public function movePage(delta:Int, extend:Bool):Void editor.movePage(delta, extend);
	override public function selectAll():Void editor.selection.selectAll(document.buffer);
	override public function undo():Void document.buffer.undo(editor.selection);
	override public function redo():Void document.buffer.redo(editor.selection);
	override public function backspace():Void {
		if (editor.selection.rangeCount() > 1) document.buffer.deleteSelections(editor.selection, true);
		else document.buffer.deleteBackward(editor.selection);
	}
	override public function deleteForward():Void {
		if (editor.selection.rangeCount() > 1) document.buffer.deleteSelections(editor.selection, false);
		else document.buffer.deleteForward(editor.selection);
	}
	override public function selectRange(from:BufferPosition, to:BufferPosition):Bool {
		editor.selection.restore(document.buffer, to, from);
		return true;
	}
	override public function replaceRange(from:BufferPosition, to:BufferPosition, text:String):Bool
		return document.buffer.replaceRange(editor.selection, from, to, text);
	override public function replaceAllText(text:String):Bool
		return document.buffer.replaceAllText(text, editor.selection);
	override public function copy():Bool {
		var values:Array<String> = [];
		for (range in editor.selection.documentRanges()) {
			if (range.isCollapsed()) return false;
			values.push(document.buffer.textRange(range.start(), range.end()));
		}
		return ModelClipboard.write(values.join("\n"));
	}
	override public function cut():Bool {
		if (!copy()) return false;
		return document.buffer.replaceSelections(editor.selection, [""]);
	}
	override public function paste():Bool {
		var text = ModelClipboard.read();
		text = StringTools.replace(StringTools.replace(text, "\r\n", "\n"), "\r", "\n");
		var lines = text.split("\n");
		return document.buffer.replaceSelections(editor.selection,
			editor.selection.rangeCount() > 1 && lines.length == editor.selection.rangeCount() ? lines : [text]);
	}
	override public function indent(tabWidth:Int, insertSpaces:Bool):Bool
		return EditorActions.indent(document.buffer, editor.selection, tabWidth, insertSpaces);
	override public function unindent(tabWidth:Int):Bool
		return EditorActions.unindent(document.buffer, editor.selection, tabWidth);
	override public function insertNewline():Bool return EditorActions.insertNewline(document.buffer, editor.selection);
	override public function duplicateLines():Bool return EditorActions.duplicateLines(document.buffer, editor.selection);
	override public function moveLines(direction:Int):Bool return EditorActions.moveLines(document.buffer, editor.selection, direction);
	override public function deleteLines():Bool return EditorActions.deleteLines(document.buffer, editor.selection);
	override public function joinLines():Bool return EditorActions.joinLines(document.buffer, editor.selection);
	override public function toggleLineComment():Bool return EditorActions.toggleLineComment(document.buffer, editor.selection, document.syntax);
	override public function selectNextOccurrence():Bool {
		var buffer = document.buffer, selection = editor.selection;
		if (!selection.hasSelection()) {
			var from = buffer.wordStartAt(selection.cursor), to = buffer.wordEndAt(selection.cursor);
			if (from.equals(to)) return false;
			selection.restore(buffer, to, from);
			return true;
		}
		var needle = buffer.textRange(selection.start(), selection.end()), startOffset = 0;
		for (range in selection.allRanges()) {
			var endOffset = buffer.offsetOf(range.end());
			if (endOffset > startOffset) startOffset = endOffset;
		}
		var offset = buffer.text.indexOf(needle, startOffset);
		if (offset < 0) offset = buffer.text.indexOf(needle);
		if (offset < 0) return false;
		var from = buffer.positionFromOffset(offset), to = buffer.positionFromOffset(offset + needle.length);
		if (from.equals(selection.start()) && to.equals(selection.end())) return false;
		selection.addRange(buffer, to, from);
		return true;
	}
	override public function toggleWordWrap():Bool return editor.toggleWordWrap();
	override public function toggleFold():Bool return editor.toggleCurrentFold();

	override public function resize(width:Int, height:Int):Void
		editor.resize(width, height);

	override public function setBounds(x:Int, y:Int, width:Int, height:Int):Void
		editor.setBounds(x, y, width, height);

	override public function textInput(text:String):Void {
		editor.clearComposition();
		if (editor.selection.rangeCount() > 1) document.buffer.replaceSelections(editor.selection, [text]);
		else document.buffer.insert(editor.selection, text, text.indexOf("\n") < 0);
		editor.cursorChanged();
	}
	override public function setComposition(text:String, start:Int, length:Int):Void editor.setComposition(text, start, length);
	override public function clearComposition():Void editor.clearComposition();
	override public function textInputArea():Null<TextInputArea> return editor.textInputArea();
	override public function deactivate():Void editor.clearComposition();

	override public function cursorChanged():Void {
		editor.cursorChanged();
	}

	override public function scrollX():Int return editor.scrollX;
	override public function scrollY():Int return editor.scrollY;
	override public function restoreScroll(x:Int, y:Int):Void editor.restoreScroll(x, y);
	override public function cursorLine():Int return editor.selection.cursor.line;
	override public function cursorColumn():Int return editor.selection.cursor.column;
	override public function hasSelection():Bool return editor.selection.hasSelection();
	override public function restoreCursor(line:Int, column:Int):Void {
		editor.selection.setCursor(document.buffer, new BufferPosition(line, column));
	}

	override public function setSearchMatches(matches:Array<SearchMatch>):Void
		editor.setSearchMatches(matches);
	override public function searchMatchCount():Int return editor.searchMatches.length;

	override public function wheel(vertical:Int, horizontal:Int):Void
		editor.wheel(vertical, horizontal);

	override public function mouseDown(button:Int, x:Int, y:Int, clicks:Int = 1):Void {
		editor.mouseDown(button, x, y, clicks);
	}

	override public function mouseMove(x:Int, y:Int):Void {
		editor.mouseMove(x, y);
	}

	override public function mouseUp(button:Int):Void
		editor.mouseUp(button);
	override public function dispose():Void bufferSubscription.release();

	function bufferChanged(change:BufferChange):Void {
		editor.clearComposition();
		editor.selection.transform(document.buffer, change);
	}
}
