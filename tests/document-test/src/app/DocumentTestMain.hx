package app;

import editor.TextBuffer;
import editor.Document;
import editor.BufferPosition;
import editor.BufferSelection;
import editor.BufferReplacement;
import editor.EditorActions;
import syntax.HighlightToken;
import syntax.BuiltinSyntax;
import syntax.SyntaxRegistry;
import search.DocumentSearch;
import search.SearchOptions;
import editor.ExternalState;
import haxeon.ui.widgets.text.EditTransaction;
import sys.io.File;
import haxe.io.Bytes;
import sys.FileSystem;
import workspace.FileSystemService;
import workspace.EditorFileSystem;
import core.DocumentManager;

class FailingFileSystem implements EditorFileSystem {
	final delegate = new FileSystemService();
	public function new() {}
	public function normalize(path:String):String return delegate.normalize(path);
	public function exists(path:String):Bool return delegate.exists(path);
	public function isDirectory(path:String):Bool return delegate.isDirectory(path);
	public function entries(path:String):Array<String> return delegate.entries(path);
	public function join(parent:String, name:String):String return delegate.join(parent, name);
	public function read(path:String):String return delegate.read(path);
	public function writeAtomic(path:String, content:String):Bool return false;
	public function createFile(path:String):Bool return delegate.createFile(path);
	public function createFolder(path:String):Bool return delegate.createFolder(path);
	public function rename(path:String, destination:String):Bool return delegate.rename(path, destination);
	public function deleteFile(path:String):Bool return delegate.deleteFile(path);
}

class DocumentTestMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}

	static function main():Int {
		var syntaxes = new SyntaxRegistry();
		BuiltinSyntax.install(syntaxes);
		require(syntaxes.find("script", "#!/usr/bin/env lua\n").name == "Lua" && syntaxes.find("data.json").name == "JSON"
			&& syntaxes.find("README.md").name == "Markdown" && syntaxes.find("main.c").name == "C"
			&& syntaxes.find("main.cpp").name == "C++" && syntaxes.find("build.sh").name == "Shell", "built-in syntax selection failed");
		var buffer = new TextBuffer("alpha\nbeta"), selection = new BufferSelection();
		var observedChanges = 0, secondObservedChanges = 0;
		var releaseFirst = buffer.subscribe(change -> {
			observedChanges++;
		});
		var releaseSecond = buffer.subscribe(change -> {
			secondObservedChanges++;
		});
		require(buffer.lineCount() == 2 && buffer.line(1) == "beta", "line indexing failed");
		selection.setCursor(buffer, new BufferPosition(0, 5));
		buffer.insert(selection, "!");
		require(observedChanges == 1 && secondObservedChanges == 1, "buffer change subscriptions did not fan out");
		releaseFirst.release();
		require(buffer.text == "alpha!\nbeta" && selection.cursor.equals(new BufferPosition(0, 6)), "insertion failed");
		selection.move(buffer, -5, true);
		require(selection.selectedText(buffer) == "lpha!", "selection failed");
		buffer.insert(selection, "L");
		require(buffer.text == "aL\nbeta" && !selection.hasSelection(), "selection replacement failed");
		buffer.deleteBackward(selection);
		require(buffer.text == "a\nbeta", "backspace failed");
		buffer.deleteForward(selection);
		require(observedChanges == 1 && secondObservedChanges == 4, "released buffer subscription was still invoked");
		require(buffer.text == "abeta", "forward delete failed");
		require(buffer.undo(selection) && buffer.text == "a\nbeta", "undo delete failed");
		require(buffer.undo(selection) && buffer.text == "aL\nbeta", "undo backspace failed");
		require(buffer.redo(selection) && buffer.text == "a\nbeta", "redo failed");
		selection.selectAll(buffer);
		buffer.insert(selection, "replacement");
		require(buffer.text == "replacement" && selection.cursor.equals(new BufferPosition(0, 11)), "select-all replacement failed");
		var vertical = new TextBuffer("abcdef\nxy\n123456"), verticalSelection = new BufferSelection();
		verticalSelection.setCursor(vertical, vertical.positionAt(0, 5));
		verticalSelection.moveVertical(vertical, 1);
		require(verticalSelection.cursor.equals(new BufferPosition(1, 2)), "vertical movement did not clamp to short line");
		verticalSelection.moveVertical(vertical, 1);
		require(verticalSelection.cursor.equals(new BufferPosition(2, 5)), "vertical movement did not preserve preferred column");
		verticalSelection.moveVertical(vertical, -1, true);
		require(verticalSelection.hasSelection() && verticalSelection.cursor.column == 2, "vertical selection failed");
		var multiline = new TextBuffer("one\ntwo\nthree"), multilineSelection = new BufferSelection(), cleanState = multiline.stateId;
		multilineSelection.setCursor(multiline, new BufferPosition(0, 2));
		multiline.insert(multilineSelection, "X\nY");
		require(multiline.lineCount() == 4 && multiline.line(0) == "onX" && multiline.line(1) == "Ye", "line splice insertion failed");
		require(multiline.undo(multilineSelection) && multiline.text == "one\ntwo\nthree" && multiline.stateId == cleanState, "range undo failed");
		require(multiline.redo(multilineSelection) && multiline.text == "onX\nYe\ntwo\nthree", "range redo failed");
		var unicode = new TextBuffer("A😀B"), unicodeSelection = new BufferSelection();
		require(unicode.positionAt(0, 2).column == 1 && unicode.positionFromOffset(2).column == 1,
			"position conversion accepted the middle of a surrogate pair");
		unicodeSelection.setCursor(unicode, new BufferPosition(0, 1));
		unicodeSelection.move(unicode, 1);
		require(unicodeSelection.cursor.column == 3, "cursor split a surrogate pair");
		unicode.deleteBackward(unicodeSelection);
		require(unicode.text == "AB" && unicodeSelection.cursor.column == 1, "backspace split a surrogate pair");
		var combining = new TextBuffer("é"), combiningSelection = new BufferSelection();
		combiningSelection.setCursor(combining, new BufferPosition(0, 2));
		combiningSelection.move(combining, -1);
		require(combiningSelection.cursor.column == 1, "combining-mark scalar boundary policy changed");
		var navigation = new TextBuffer("one  two\nthree"), navigationSelection = new BufferSelection(new BufferPosition(0, 8));
		navigationSelection.moveWord(navigation, -1);
		require(navigationSelection.cursor.column == 5, "previous-word navigation failed");
		navigationSelection.moveWord(navigation, -1, true);
		require(navigationSelection.start().column == 0 && navigationSelection.end().column == 5, "word selection failed");
		navigationSelection.move(navigation, 1);
		require(!navigationSelection.hasSelection() && navigationSelection.cursor.column == 5,
			"right movement did not collapse selection to its end");
		navigationSelection.moveDocumentEnd(navigation);
		require(navigationSelection.cursor.line == 1 && navigationSelection.cursor.column == 5, "document-end navigation failed");
		navigationSelection.moveDocumentStart(navigation, true);
		require(navigationSelection.start().equals(new BufferPosition(0, 0)) && navigationSelection.end().equals(new BufferPosition(1, 5)),
			"document selection failed");
		var typing = new TextBuffer(), typingSelection = new BufferSelection();
		typing.insert(typingSelection, "a", true);
		typing.insert(typingSelection, "b", true);
		typing.insert(typingSelection, "c", true);
		require(typing.undo(typingSelection) && typing.text == "", "adjacent typing was not grouped into one undo");
		require(typing.redo(typingSelection) && typing.text == "abc", "typing-group redo failed");
		typing.undo(typingSelection);
		typing.insert(typingSelection, "x", true);
		require(!typing.redo(typingSelection), "new edit did not invalidate redo history");
		typing.insert(typingSelection, "y", true);
		typingSelection.move(typing, -1);
		typingSelection.move(typing, 1);
		typing.insert(typingSelection, "z", true);
		require(typing.undo(typingSelection) && typing.text == "xy", "cursor movement did not end the typing group");
		var transactional = new TextBuffer("abcdef"), transactionSelection = new BufferSelection(new BufferPosition(0, 3));
		require(transactional.applyReplacements(transactionSelection, [
			new BufferReplacement(new BufferPosition(0, 4), new BufferPosition(0, 5), "Y"),
			new BufferReplacement(new BufferPosition(0, 1), new BufferPosition(0, 2), "X")
		]) && transactional.text == "aXcdYf", "multi-replacement transaction failed");
		require(transactional.undo(transactionSelection) && transactional.text == "abcdef"
			&& transactionSelection.cursor.column == 3, "transaction undo did not restore text and initiating selection");
		require(transactional.redo(transactionSelection) && transactional.text == "aXcdYf", "transaction redo failed");
		var normalized = new BufferSelection();
		normalized.setRanges(transactional, [
			new editor.BufferRange(new BufferPosition(0, 0), new BufferPosition(0, 3)),
			new editor.BufferRange(new BufferPosition(0, 2), new BufferPosition(0, 5)),
			new editor.BufferRange(new BufferPosition(0, 6), new BufferPosition(0, 6))
		], 0);
		require(normalized.rangeCount() == 2 && normalized.cursor.column == 0 && normalized.anchor.column == 5,
			"overlapping reversed selections did not merge around a stable primary");
		var transactionState = transactional.stateId;
		require(!transactional.applyReplacements(transactionSelection, [
			new BufferReplacement(new BufferPosition(0, 1), new BufferPosition(0, 4), "bad"),
			new BufferReplacement(new BufferPosition(0, 3), new BufferPosition(0, 5), "overlap")
		]) && transactional.text == "aXcdYf" && transactional.stateId == transactionState,
			"overlapping transaction was partially applied");
		var coding = new TextBuffer("one\n  two\nthree"), codingSelection = new BufferSelection();
		codingSelection.restore(coding, new BufferPosition(2, 5), new BufferPosition(0, 0));
		require(EditorActions.indent(coding, codingSelection, 2, true) && coding.text == "  one\n    two\n  three"
			&& codingSelection.cursor.line == 2 && codingSelection.cursor.column == 7 && codingSelection.anchor.column == 0,
			"selection indent lost content or reversed selection direction");
		require(coding.undo(codingSelection) && coding.text == "one\n  two\nthree" && codingSelection.cursor.column == 5,
			"selection indent was not one undo transaction");
		var trailing = new TextBuffer("a\n\nc\n"), trailingSelection = new BufferSelection();
		trailingSelection.restore(trailing, new BufferPosition(3, 0), new BufferPosition(0, 1));
		require(EditorActions.indent(trailing, trailingSelection, 2, true) && trailing.text == "  a\n  \n  c\n",
			"partial multiline indent changed the excluded trailing line or skipped a blank line");
		require(trailing.undo(trailingSelection) && trailing.text == "a\n\nc\n", "trailing-newline indent was not one undo transaction");
		codingSelection.restore(coding, new BufferPosition(2, 5), new BufferPosition(0, 0));
		require(EditorActions.unindent(coding, codingSelection, 2) && coding.text == "one\ntwo\nthree", "mixed unindent failed");
		var autoindent = new TextBuffer("  value"), autoindentSelection = new BufferSelection(autoindent.endPosition());
		require(EditorActions.insertNewline(autoindent, autoindentSelection) && autoindent.text == "  value\n  ", "autoindent failed");
		var lines = new TextBuffer("a\nb\nc"), lineSelection = new BufferSelection(new BufferPosition(1, 1));
		require(EditorActions.duplicateLines(lines, lineSelection) && lines.text == "a\nb\nb\nc" && lineSelection.cursor.line == 2,
			"line duplication failed");
		require(lines.undo(lineSelection) && lines.text == "a\nb\nc", "line duplication was not one undo transaction");
		require(EditorActions.moveLines(lines, lineSelection, -1) && lines.text == "b\na\nc" && lineSelection.cursor.line == 0,
			"move line up failed");
		lines.undo(lineSelection);
		require(EditorActions.moveLines(lines, lineSelection, 1) && lines.text == "a\nc\nb" && lineSelection.cursor.line == 2,
			"move line down failed");
		lines.undo(lineSelection);
		lineSelection.restore(lines, new BufferPosition(0, 0), new BufferPosition(2, 1));
		require(EditorActions.joinLines(lines, lineSelection) && lines.text == "a b c", "join lines failed");
		require(lines.undo(lineSelection) && lines.text == "a\nb\nc", "join lines was not one undo transaction");
		lineSelection.restore(lines, new BufferPosition(1, 1), new BufferPosition(1, 1));
		require(EditorActions.deleteLines(lines, lineSelection) && lines.text == "a\nc", "delete line failed");
		var commented = new TextBuffer("  value\nnext"), commentSelection = new BufferSelection(new BufferPosition(1, 4), new BufferPosition(0, 0)),
			haxeSyntax = syntaxes.find("Main.hx");
		require(EditorActions.toggleLineComment(commented, commentSelection, haxeSyntax)
			&& commented.text == "  // value\n// next", "line comment insertion failed");
		require(EditorActions.toggleLineComment(commented, commentSelection, haxeSyntax)
			&& commented.text == "  value\nnext", "line comment removal failed");
		var multiCoding = new TextBuffer("a\nb\nc"), multiCodingSelection = new BufferSelection(new BufferPosition(0, 1));
		multiCodingSelection.addRange(multiCoding, new BufferPosition(2, 1), new BufferPosition(2, 1));
		require(EditorActions.indent(multiCoding, multiCodingSelection, 2, true) && multiCoding.text == "  a\nb\n  c"
			&& multiCodingSelection.rangeCount() == 2, "multi-selection indentation failed");
		multiCoding.undo(multiCodingSelection);
		require(multiCoding.text == "a\nb\nc" && multiCodingSelection.rangeCount() == 2,
			"multi-selection indentation undo lost ranges");
		require(EditorActions.duplicateLines(multiCoding, multiCodingSelection) && multiCoding.text == "a\na\nb\nc\nc"
			&& multiCodingSelection.rangeCount() == 2, "multi-selection line duplication failed");
		multiCoding.undo(multiCodingSelection);
		require(EditorActions.deleteLines(multiCoding, multiCodingSelection) && multiCoding.text == "b",
			"multi-selection line deletion failed");
		require(multiCoding.undo(multiCodingSelection) && multiCoding.text == "a\nb\nc" && multiCodingSelection.rangeCount() == 2,
			"multi-selection line deletion undo failed");
		var wordDeletes = new TextBuffer("hello world"), wordSelections = new BufferSelection(new BufferPosition(0, 8));
		wordSelections.addRange(wordDeletes, new BufferPosition(0, 11), new BufferPosition(0, 11));
		require(wordDeletes.deleteSelections(wordSelections, true, function(position, direction) {
			var cursor = new BufferSelection(position);
			cursor.moveWord(wordDeletes, direction);
			return cursor.cursor;
		}) && wordDeletes.text == "hello ", "overlapping word deletion ranges were not merged");
		require(wordDeletes.undo(wordSelections) && wordDeletes.text == "hello world" && wordSelections.rangeCount() == 2,
			"word deletion undo did not restore text and original carets");
		require(wordDeletes.redo(wordSelections) && wordDeletes.text == "hello ", "word deletion redo failed");
		// --- editor.TextBuffer <-> haxeon.editor.TextDocument bridge ---
		// TextArea.withDocument mutates the shared TextDocument itself (see
		// TextEditorState.applyTransaction) and hands the resulting
		// EditTransaction to TextBuffer.applyEditTransaction, which must fold
		// it into this buffer's own undo history without re-mirroring back
		// into the document it was already applied to.
		var bridged = new TextBuffer("hello world"), bridgedSelection = new BufferSelection();
		require(bridged.document.text == "hello world", "TextDocument was not seeded with the buffer's initial text");
		bridged.document.replace(6, 11, "haxeon"); // simulates the widget's own in-place edit
		var widgetEdit = new EditTransaction(6, 11, "haxeon", 12, 12);
		require(bridged.applyEditTransaction(bridgedSelection, widgetEdit) && bridged.text == "hello haxeon"
			&& bridged.document.text == "hello haxeon", "widget-originated edit did not mirror into the buffer");
		require(bridgedSelection.cursor.equals(new BufferPosition(0, 12)),
			"widget-originated edit did not move the buffer selection to the replacement end");
		require(bridged.undo(bridgedSelection) && bridged.text == "hello world" && bridged.document.text == "hello world",
			"undoing a widget-originated edit did not restore the shared document");
		require(bridged.redo(bridgedSelection) && bridged.text == "hello haxeon" && bridged.document.text == "hello haxeon",
			"redoing a widget-originated edit did not restore the shared document");
		// A buffer-originated edit right after a widget-originated one must
		// still mirror forward (mirroring must be re-enabled afterward).
		bridgedSelection.setCursor(bridged, bridged.endPosition());
		bridged.insert(bridgedSelection, "!");
		require(bridged.text == "hello haxeon!" && bridged.document.text == "hello haxeon!",
			"a buffer-originated edit stopped mirroring into the document after a prior widget-originated edit");
		var bridgedChanges = 0, bridgedRelease = bridged.subscribe(change -> bridgedChanges++);
		bridged.document.replace(0, 0, "so ");
		require(bridged.applyEditTransaction(bridgedSelection, new EditTransaction(0, 0, "so ", 3, 3)) && bridgedChanges == 1,
			"widget-originated edit did not notify buffer subscribers exactly once");
		bridgedRelease.release();
		require(bridged.undo(bridgedSelection) && bridged.text == "hello haxeon!" && bridged.document.text == "hello haxeon!",
			"undo did not roll back a widget-originated prefix edit in both the buffer and the document");
		// Unicode: a codepoint-offset transaction from the widget must land
		// on the correct line/column even across a surrogate pair.
		var unicodeBridge = new TextBuffer("A😀B"), unicodeBridgeSelection = new BufferSelection();
		unicodeBridge.document.replace(1, 2, "X");
		require(unicodeBridge.applyEditTransaction(unicodeBridgeSelection, new EditTransaction(1, 2, "X", 2, 2)) && unicodeBridge.text == "AXB"
			&& unicodeBridge.document.text == "AXB", "widget-originated edit mishandled a surrogate pair codepoint offset");
		// Replay at every boundary across complete lines and surrogate pairs,
		// including line ends and the document end, then round-trip history.
		var replaySource = "A😀B\n\nC😀D";
		var replayCount = new TextBuffer(replaySource).document.codepointCount;
		for (offset in 0...replayCount + 1) {
			var replay = new TextBuffer(replaySource), replaySelection = new BufferSelection();
			var expected = replay.document.sliceCodepoints(0, offset) + "X" +
				replay.document.sliceCodepoints(offset, replayCount);
			replay.document.replace(offset, offset, "X");
			require(replay.applyEditTransaction(replaySelection, new EditTransaction(offset, offset, "X", offset + 1, offset + 1)) &&
				replay.text == expected && replay.document.text == expected,
				"widget replay at multiline Unicode boundary failed");
			require(replay.undo(replaySelection) && replay.text == replaySource && replay.document.text == replaySource,
				"multiline Unicode replay undo failed");
			require(replay.redo(replaySelection) && replay.text == expected && replay.document.text == expected,
				"multiline Unicode replay redo failed");
		}
		// Document-level: a widget-originated edit must flip dirty state and
		// undo must clear it again, exactly as a buffer-originated edit does.
		var nestedBridge = new TextBuffer("before");
		var nestedSelection = new BufferSelection();
		var nestedEdited = false;
		nestedBridge.subscribe(change -> {
			if (!nestedEdited) {
				nestedEdited = true;
				nestedBridge.replaceRange(nestedSelection, nestedBridge.endPosition(), nestedBridge.endPosition(), " // plugin");
			}
		});
		nestedBridge.document.replace(0, 6, "typed");
		nestedBridge.applyEditTransaction(nestedSelection, new EditTransaction(0, 6, "typed", 5, 5));
		require(nestedBridge.text == "typed // plugin" && nestedBridge.document.text == nestedBridge.text,
			"nested subscriber edit during widget replay did not update the shared document");
		var bridgedDocument = new Document("unused", "saved text", syntaxes), bridgedDocumentSelection = new BufferSelection();
		require(!bridgedDocument.dirty, "freshly constructed document was dirty before any edit");
		bridgedDocument.buffer.document.replace(0, 5, "typed");
		require(bridgedDocument.buffer.applyEditTransaction(bridgedDocumentSelection, new EditTransaction(0, 5, "typed", 5, 5))
			&& bridgedDocument.dirty && bridgedDocument.buffer.text == "typed text", "widget-originated edit did not dirty the owning document");
		bridgedDocument.undo(bridgedDocumentSelection);
		require(!bridgedDocument.dirty && bridgedDocument.buffer.text == "saved text" && bridgedDocument.buffer.document.text == "saved text",
			"undoing a widget-originated edit did not clear document dirty state");
		var document = new Document("unused", "clean", syntaxes), documentSelection = new BufferSelection();
		document.insert(documentSelection, " edit");
		require(document.dirty && document.buffer.text == " editclean", "document dirty state failed");
		document.undo(documentSelection);
		require(!document.dirty && document.buffer.text == "clean", "undo did not restore document savepoint");
		var searched = new Document("search.txt", "Alpha alpha alphabet\n😀 alpha", syntaxes), searchedSelection = new BufferSelection(),
			options = new SearchOptions();
		var matches = DocumentSearch.find(searched, "alpha", options);
		require(matches.length == 4 && matches[3].line == 1 && matches[3].column == 3, "case-insensitive Unicode search positions failed");
		options.caseSensitive = true;
		require(DocumentSearch.find(searched, "Alpha", options).length == 1, "case-sensitive search failed");
		options.caseSensitive = false;
		options.wholeWord = true;
		require(DocumentSearch.find(searched, "alpha", options).length == 3, "whole-word search failed");
		require(DocumentSearch.replaceAll(searched, searchedSelection, "alpha", "beta", options) == 3, "replace-all count failed");
		require(searched.buffer.text == "beta beta alphabet\n😀 beta", "replace-all content failed");
		require(searched.buffer.undo(searchedSelection) && searched.buffer.text == "Alpha alpha alphabet\n😀 alpha", "replace-all was not one undo transaction");
		options.wholeWord = false;
		options.regularExpression = true;
		var regexMatches = DocumentSearch.find(searched, "(Alpha|alpha) (alpha)", options);
		require(regexMatches.length == 1 && regexMatches[0].captures.length == 3 && regexMatches[0].captures[2] == "alpha",
			"regular-expression captures failed");
		require(DocumentSearch.replaceAll(searched, searchedSelection, "(Alpha|alpha) (alpha)", "$2:$1", options) == 1
			&& searched.buffer.text == "alpha:Alpha alphabet\n😀 alpha", "capture replacement failed");
		searched.buffer.undo(searchedSelection);
		var zeroWidth = new Document("zero.txt", "aa", syntaxes);
		require(DocumentSearch.find(zeroWidth, "(?=a)", options).length == 2, "zero-width regular-expression search did not terminate");
		var invalidPattern = false;
		try DocumentSearch.find(searched, "(", options) catch (error:Dynamic) invalidPattern = true;
		require(invalidPattern, "invalid regular expression was accepted");
		var source = new Document("Main.hx", "class Main {\n/* comment\nstill comment */ var value = 42;\n}", syntaxes);
		source.setPath("Main.txt");
		require(source.syntax.name == "Plain Text", "path change did not reselect syntax");
		source.setPath("Main.hx");
		var firstHighlight = source.highlighter.line(0), cachedHighlight = source.highlighter.line(0), comment = source.highlighter.line(1),
			continued = source.highlighter.line(2), stableTail = source.highlighter.line(3);
		require(firstHighlight == cachedHighlight && hasToken(firstHighlight.tokens, HighlightToken.KEYWORD), "highlight cache or keyword token failed");
		require(comment.stateAfter != 0 && hasToken(continued.tokens, HighlightToken.COMMENT), "multiline comment state failed");
		var sourceSelection = new BufferSelection();
		sourceSelection.setCursor(source.buffer, new BufferPosition(1, 0));
		sourceSelection.move(source.buffer, 2, true);
		source.insert(sourceSelection, "");
		var updated = source.highlighter.line(2);
		require(updated != continued && updated.stateBefore == 0, "edit did not invalidate downstream lexical state");
		require(source.highlighter.line(3) == stableTail, "unchanged converged highlight cache was discarded");
		var lua = new Document("fixture.lua", "local text = [[first\nsecond]]\nreturn text", syntaxes),
			markdown = new Document("fixture.md", "```haxe\nclass Main {}\n```\nafter", syntaxes),
			shell = new Document("fixture.sh", "value=\"first\nsecond\"\nif true; then", syntaxes);
		require(lua.highlighter.line(0).stateAfter != 0
			&& hasToken(lua.highlighter.line(1).tokens, HighlightToken.STRING)
			&& lua.highlighter.line(1).stateAfter == 0
			&& hasToken(lua.highlighter.line(2).tokens, HighlightToken.KEYWORD), "Lua long-string state did not converge");
		require(markdown.highlighter.line(0).stateAfter != 0
			&& hasToken(markdown.highlighter.line(1).tokens, HighlightToken.STRING)
			&& markdown.highlighter.line(2).stateAfter == 0, "Markdown fenced-code state did not converge");
		require(shell.highlighter.line(0).stateAfter != 0
			&& hasToken(shell.highlighter.line(1).tokens, HighlightToken.STRING)
			&& shell.highlighter.line(1).stateAfter == 0
			&& hasToken(shell.highlighter.line(2).tokens, HighlightToken.KEYWORD), "shell multiline quote state did not converge");
		var brackets = new Document("brackets.hx", "call(\"ignored )\", { value: [1, 2] }) // }", syntaxes),
			outer = brackets.matchingBrackets(new BufferPosition(0, 4)), inner = brackets.matchingBrackets(new BufferPosition(0, 27));
		require(outer != null && outer.first.column == 4 && outer.second.column == 35,
			"bracket matching counted a string or comment delimiter");
		require(inner != null && inner.first.column == 27 && inner.second.column == 32, "nested bracket matching failed");
		var arguments = Sys.args();
		if (arguments.length > 0) {
			var saveAsPath = arguments[0] + ".save-as";
			if (FileSystem.exists(saveAsPath)) FileSystem.deleteFile(saveAsPath);
			var manager = new DocumentManager(syntaxes), untitled = manager.createUntitled(), untitledSelection = new BufferSelection();
			untitled.insert(untitledSelection, "new document");
			require(manager.saveAs(untitled, saveAsPath) && untitled.path == FileSystem.fullPath(saveAsPath) && !untitled.dirty
				&& File.getContent(saveAsPath) == "new document", "Save As did not assign identity after successful persistence");
			var another = manager.createUntitled(), anotherSelection = new BufferSelection();
			another.insert(anotherSelection, "collision");
			require(!manager.saveAs(another, saveAsPath) && another.path == null && another.dirty,
				"Save As collision changed an untitled document identity");
			FileSystem.deleteFile(saveAsPath);
			var saved = Document.open(arguments[0], syntaxes), savedSelection = new BufferSelection();
			saved.insert(savedSelection, "!");
			require(saved.save() && !saved.dirty && Document.open(arguments[0], syntaxes).buffer.text == "!saved by Haxeon\n", "atomic document save failed");
			File.saveContent(arguments[0], "external\n");
			require(saved.checkExternal() == ExternalState.Current && saved.buffer.text == "external\n", "clean external edit did not reload");
			saved.insert(savedSelection, "dirty ");
			File.saveContent(arguments[0], "other writer\n");
			require(saved.checkExternal() == ExternalState.Changed && !saved.save() && File.getContent(arguments[0]) == "other writer\n",
				"dirty external conflict overwrote disk");
			require(saved.save(true) && File.getContent(arguments[0]) == saved.buffer.text, "explicit conflict overwrite failed");
			var failing = new Document(arguments[0], File.getContent(arguments[0]), syntaxes, new FailingFileSystem()),
				failingSelection = new BufferSelection();
			failing.insert(failingSelection, "unsaved ");
			require(!failing.save() && failing.dirty && File.getContent(arguments[0]) == saved.buffer.text, "failed save changed disk or clean state");
			File.saveContent(arguments[0], "﻿first\r\nsecond\r\n");
			var formatted = Document.open(arguments[0], syntaxes), formattedSelection = new BufferSelection();
			var lastLine = formatted.buffer.lineCount() - 1;
			formattedSelection.setCursor(formatted.buffer, formatted.buffer.positionAt(lastLine, formatted.buffer.line(lastLine).length));
			formatted.insert(formattedSelection, "third\n");
			require(formatted.save() && File.getContent(arguments[0]) == "﻿first\r\nsecond\r\nthird\r\n", "BOM/CRLF format was not preserved");
			var invalidWriteFailed = false;
			try sys.io.AtomicFile.write(arguments[0] + "/missing/file.txt", "bad") catch (error:Dynamic) invalidWriteFailed = true;
			require(invalidWriteFailed, "invalid atomic destination was accepted");
			var exclusiveCreateFailed = false;
			try sys.io.AtomicFile.create(arguments[0], "overwrite") catch (error:Dynamic) exclusiveCreateFailed = true;
			require(exclusiveCreateFailed && File.getContent(arguments[0]) == "﻿first\r\nsecond\r\nthird\r\n",
				"exclusive file creation overwrote an existing file");
			var binaryPath = arguments[0] + ".binary";
			if (FileSystem.exists(binaryPath)) FileSystem.deleteFile(binaryPath);
			var binary = Bytes.alloc(3);
			binary.set(0, 65);
			binary.set(1, 0);
			binary.set(2, 66);
			sys.io.AtomicFile.createBytes(binaryPath, binary);
			var loaded = File.getBytes(binaryPath);
			require(loaded.length == 3 && loaded.get(0) == 65 && loaded.get(1) == 0 && loaded.get(2) == 66,
				"atomic byte publication did not preserve embedded NUL data");
			FileSystem.deleteFile(binaryPath);
		}
		Sys.println("PASS: Haxeon text buffer editing, selections, and history");
		return 0;
	}

	static function hasToken(tokens:Array<HighlightToken>, kind:Int):Bool {
		for (token in tokens)
			if (token.kind == kind) return true;
		return false;
	}
}
