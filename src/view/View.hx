package view;

import editor.Document;
import editor.BufferPosition;
import editor.BufferSelection;
import search.SearchMatch;
import platform.TextInputArea;

class View {
	public var title(default, null):String;

	public function new(title:String) {
		this.title = title;
	}

	public function setTitle(title:String):Void
		this.title = title;

	public function isDirty():Bool
		return false;

	public function getDocument():Null<Document>
		return null;
	public function getSelection():Null<BufferSelection>
		return null;

	public function moveVertical(delta:Int, extend:Bool):Void {}
	public function moveHorizontal(delta:Int, extend:Bool):Void {}
	public function moveHome(extend:Bool):Void {}
	public function moveEnd(extend:Bool):Void {}
	public function moveWord(direction:Int, extend:Bool):Void {}
	public function moveDocumentStart(extend:Bool):Void {}
	public function moveDocumentEnd(extend:Bool):Void {}
	public function movePage(delta:Int, extend:Bool):Void {}
	public function selectAll():Void {}
	public function undo():Void {}
	public function redo():Void {}
	public function backspace(tabWidth:Int = 0, indentSize:Int = 0):Void {}
	public function deleteForward():Void {}
	public function selectRange(from:BufferPosition, to:BufferPosition):Bool return false;
	public function replaceRange(from:BufferPosition, to:BufferPosition, text:String):Bool return false;
	public function replaceAllText(text:String):Bool return false;
	public function copy():Bool return false;
	public function cut():Bool return false;
	public function paste():Bool return false;
	public function tab(tabWidth:Int, insertSpaces:Bool, indentSize:Int = 0):Bool return indent(tabWidth, insertSpaces, indentSize);
	public function indent(tabWidth:Int, insertSpaces:Bool, indentSize:Int = 0):Bool return false;
	public function unindent(tabWidth:Int, indentSize:Int = 0):Bool return false;
	public function insertNewline(tabWidth:Int = 0, insertSpaces:Bool = true, indentSize:Int = 0):Bool return false;
	public function duplicateLines():Bool return false;
	public function moveLines(direction:Int):Bool return false;
	public function deleteLines():Bool return false;
	public function joinLines():Bool return false;
	public function toggleLineComment():Bool return false;
	public function selectNextOccurrence():Bool return false;
	public function toggleWordWrap():Bool return false;
	public function toggleFold():Bool return false;
	public function setBounds(x:Int, y:Int, width:Int, height:Int):Void
		resize(width, height);

	public function resize(width:Int, height:Int):Void {}
	public function textInput(text:String):Void {}
	public function setComposition(text:String, start:Int, length:Int):Void {}
	public function clearComposition():Void {}
	public function textInputArea():Null<TextInputArea> return null;
	public function cursorChanged():Void {}
	public function scrollX():Int return 0;
	public function scrollY():Int return 0;
	public function restoreScroll(x:Int, y:Int):Void {}
	public function activate():Void {}
	public function deactivate():Void {}
	public function cursorLine():Int return 0;
	public function cursorColumn():Int return 0;
	public function hasSelection():Bool return false;
	public function restoreCursor(line:Int, column:Int):Void {}
	public function setSearchMatches(matches:Array<SearchMatch>):Void {}
	public function searchMatchCount():Int return 0;
	public function wheel(vertical:Int, horizontal:Int):Void {}
	public function mouseDown(button:Int, x:Int, y:Int, clicks:Int = 1):Void {}
	public function mouseMove(x:Int, y:Int):Void {}
	public function mouseUp(button:Int):Void {}
	public function dispose():Void {}
}
