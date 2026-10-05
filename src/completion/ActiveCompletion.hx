package completion;

import core.WorkbenchHost;
import editor.BufferPosition;
import editor.Document;
import platform.Platform;
import view.View;

/** Tracks only edits made by this completion interaction; unrelated edits retire it. */
class ActiveCompletion {
	final host:WorkbenchHost;
	final view:View;
	final document:Document;
	final from:BufferPosition;
	final items:Array<CompletionItem>;
	final current:Void->Bool;
	var to:BufferPosition;
	var revision:Int;

	public function new(host:WorkbenchHost, view:View, document:Document, from:BufferPosition, to:BufferPosition,
		items:Array<CompletionItem>, current:Void->Bool) {
		this.host = host;
		this.view = view;
		this.document = document;
		this.from = from;
		this.to = to;
		this.items = items;
		this.current = current;
		revision = document.buffer.stateId;
	}

	function valid():Bool return current() && document.buffer.stateId == revision
		&& view.cursorLine() == to.line && view.cursorColumn() == to.column && !view.hasSelection();

	public function show():Void {
		if (!valid()) { host.dismissLanguagePopup(); return; }
		var area = host.textInputArea();
		if (area == null) { host.dismissLanguagePopup(); return; }
		var matches = CompletionItem.matching(items, document.buffer.line(to.line).substring(from.column, to.column));
		if (matches.length == 0) { host.dismissLanguagePopup(); return; }
		host.openLanguageCompletion(area, matches, accept, input, key);
	}

	function accept(item:CompletionItem):Void {
		if (valid() && view.replaceRange(from, to, item.insertText)) view.cursorChanged();
	}

	function input(text:String):Void {
		if (!valid()) { host.dismissLanguagePopup(); host.textInput(text); host.cursorChanged(); return; }
		view.textInput(text);
		afterEdit();
	}

	function key(key:Int, modifiers:Int):Bool {
		if (modifiers != 0) return false;
		if (key == Platform.KEY_LEFT || key == Platform.KEY_RIGHT || key == Platform.KEY_HOME || key == Platform.KEY_END || key == Platform.KEY_DELETE) {
			host.dismissLanguagePopup();
			if (current()) {
				if (key == Platform.KEY_LEFT) view.moveHorizontal(-1, false);
				else if (key == Platform.KEY_RIGHT) view.moveHorizontal(1, false);
				else if (key == Platform.KEY_HOME) view.moveHome(false);
				else if (key == Platform.KEY_END) view.moveEnd(false);
				else view.deleteForward();
				view.cursorChanged();
			}
			return true;
		}
		if (key != Platform.KEY_BACKSPACE) return false;
		if (!valid()) { host.dismissLanguagePopup(); return true; }
		view.backspace();
		afterEdit();
		return true;
	}

	function afterEdit():Void {
		revision = document.buffer.stateId;
		to = new BufferPosition(view.cursorLine(), view.cursorColumn());
		view.cursorChanged();
		if (to.line != from.line || to.column < from.column) host.dismissLanguagePopup();
		else show();
	}
}
