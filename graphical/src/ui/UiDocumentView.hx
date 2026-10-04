package ui;

import editor.BufferPosition;
import editor.BufferSubscription;
import nativekit.ui.widgets.scroll.ScrollController;
import editor.BufferSelection;
import editor.Document;
import editor.EditorActions;
import search.SearchMatch;
import view.View;

/**
 * The `view.View` UIKit hands back from `WorkbenchHost.openDocument` for one
 * open tab. It shares its `BufferSelection` with the `EditorPane` that
 * actually renders and edits the document (see `ExosuitApp.editorPanel`), so
 * `command.EditorCommands`/`controller.*` operations that go through
 * `command.CommandContext.requireView()` (undo, redo, select-all, indent,
 * line operations, ...) mutate the same buffer state the widget displays.
 *
 * EditorPane imports this view's primary selection through TextArea's
 * controlled-selection API. Keyboard and pointer movement in the widget
 * report back to the same model after text edits synchronize the buffer.
 * Additional normalized selections render through the widget; text insertion,
 * clipboard operations and deletion are delegated to the buffer as one undo unit.
 *
 * Mouse/wheel/draw and clipboard (`copy`/`cut`/`paste`) are left as the
 * `View` base class's no-ops: `TextArea` handles pointer input and the
 * system clipboard itself once focused, and this adapter is never drawn or
 * pointer-dispatched to directly (uikit renders `EditorPane`, not this).
 */
class UiDocumentView extends View {
	static var nextId:Int = 1;
	/** Stable identity for this view, independent of the shared document. */
	public final id:Int;
	public final document:Document;
	public final selection:BufferSelection;
	/** Preview is view-local and permanently clears on the first buffer edit. */
	public var preview:Bool = false;
	public final scrollController:ScrollController = new ScrollController();
	final bufferSubscription:BufferSubscription;
	final matches:Array<SearchMatch> = [];
	var searchRevision:Int = 0;

	public function new(document:Document, selection:BufferSelection, ?settings:config.Settings) {
		super(document.title);
		id = nextId++;
		this.document = document;
		this.selection = selection;
		applyScrollSettings(settings == null ? new config.Settings() : settings);
		bufferSubscription = document.buffer.subscribe(function(change) {
			preview = false;
			this.selection.transform(document.buffer, change);
		});
	}

	public function applyScrollSettings(settings:config.Settings):Void
		scrollController.configureAnimation(settings.scrollAnimationType == "smooth", settings.scrollAnimationDuration);

	override public function dispose():Void {
		bufferSubscription.release(); scrollController.cancelAnimation();
	}

	override public function isDirty():Bool
		return document.dirty;

	override public function getDocument():Null<Document>
		return document;

	override public function getSelection():Null<BufferSelection>
		return selection;

	override public function selectAll():Void
		selection.selectAll(document.buffer);

	override public function undo():Void
		document.buffer.undo(selection);

	override public function redo():Void
		document.buffer.redo(selection);

	override public function backspace():Void {
		if (selection.rangeCount() > 1) document.buffer.deleteSelections(selection, true);
		else document.buffer.deleteBackward(selection);
	}

	override public function deleteForward():Void {
		if (selection.rangeCount() > 1) document.buffer.deleteSelections(selection, false);
		else document.buffer.deleteForward(selection);
	}

	override public function selectRange(from:BufferPosition, to:BufferPosition):Bool {
		selection.restore(document.buffer, to, from);
		return true;
	}

	override public function replaceRange(from:BufferPosition, to:BufferPosition, text:String):Bool
		return document.buffer.replaceRange(selection, from, to, text);

	override public function replaceAllText(text:String):Bool
		return document.buffer.replaceAllText(text, selection);

	override public function indent(tabWidth:Int, insertSpaces:Bool):Bool
		return EditorActions.indent(document.buffer, selection, tabWidth, insertSpaces);

	override public function unindent(tabWidth:Int):Bool
		return EditorActions.unindent(document.buffer, selection, tabWidth);

	override public function insertNewline():Bool
		return EditorActions.insertNewline(document.buffer, selection);

	override public function duplicateLines():Bool
		return EditorActions.duplicateLines(document.buffer, selection);

	override public function moveLines(direction:Int):Bool
		return EditorActions.moveLines(document.buffer, selection, direction);

	override public function deleteLines():Bool
		return EditorActions.deleteLines(document.buffer, selection);

	override public function joinLines():Bool
		return EditorActions.joinLines(document.buffer, selection);

	override public function toggleLineComment():Bool
		return EditorActions.toggleLineComment(document.buffer, selection, document.syntax);

	override public function textInput(text:String):Void {
		if (selection.rangeCount() > 1) document.buffer.replaceSelections(selection, [text]);
		else document.buffer.insert(selection, text, text.indexOf("\n") < 0);
	}

	override public function cursorLine():Int
		return selection.cursor.line;

	override public function cursorColumn():Int
		return selection.cursor.column;

	override public function hasSelection():Bool
		return selection.hasSelection();

	override public function restoreCursor(line:Int, column:Int):Void
		selection.setCursor(document.buffer, new BufferPosition(line, column));

	override public function scrollX():Int return Std.int(scrollController.offsetX);
	override public function scrollY():Int return Std.int(scrollController.offsetY);
	override public function restoreScroll(x:Int, y:Int):Void scrollController.jumpTo(x, y);

	override public function setSearchMatches(matches:Array<SearchMatch>):Void {
		searchRevision++;
		this.matches.resize(0);
		for (match in matches) this.matches.push(match);
	}

	public function decorationSearchMatches():Array<SearchMatch> return matches.copy();
	public function searchDecorationRevision():Int return searchRevision;

	override public function searchMatchCount():Int
		return matches.length;
}
