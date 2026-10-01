package app;

import editor.Document;
import editor.SyntaxPresentation;
import editor.EditorView;
import platform.Native;
import platform.Platform;
import renderer.Renderer;
import syntax.BuiltinSyntax;
import syntax.SyntaxRegistry;
import style.Theme;
import editor.BufferSelection;
import editor.EditorClock;
import editor.BufferPosition;
import editor.TextBuffer;
import editor.VisualLineMap;
import completion.CompletionRegistry;
import completion.DocumentWordCompletionProvider;
import search.DocumentSearch;
import search.SearchOptions;

class FakeEditorClock implements EditorClock {
	public var value:Float = 0.0;
	public function new() {}
	public function now():Float return value;
	public function advance(seconds:Float):Void value += seconds;
}

class EditorViewTestMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}

	static function main():Int {
		Platform.startHeadless();
		var syntaxes = new SyntaxRegistry();
		BuiltinSyntax.install(syntaxes);
		var syntaxDocument = new Document("colors.hx", "var s = \"é🙂\"; // comment\n/* first\nsecond */ var n = 42;", syntaxes);
		var syntaxTheme = new Theme();
		var syntaxColors = SyntaxPresentation.foreground(syntaxDocument, syntaxTheme, 0,
			syntaxDocument.buffer.document.codepointCount);
		var stringFound = false;
		for (range in syntaxColors) {
			if (range.color == syntaxTheme.tokenColor(syntax.HighlightToken.STRING)) {
				stringFound = true;
				require(range.start == 8 && range.end == 12, "syntax string range confused UTF-16 with codepoints");
			}
		}
		require(stringFound, "syntax presentation omitted the Unicode string");
		var clippedColors = SyntaxPresentation.foreground(syntaxDocument, syntaxTheme, 9, 11);
		require(clippedColors.length == 1 && clippedColors[0].start == 9 && clippedColors[0].end == 11,
			"syntax foreground did not clip to the visible range");
		var thirdLine = syntaxDocument.buffer.document.paragraphRangeAtIndex(2);
		var continuedColors = SyntaxPresentation.foreground(syntaxDocument, syntaxTheme, thirdLine.start, thirdLine.end);
		require(continuedColors.length > 0 && continuedColors[0].color == syntaxTheme.tokenColor(syntax.HighlightToken.COMMENT),
			"syntax viewport lost multiline comment state");
		syntaxDocument.buffer.replaceRange(new BufferSelection(), new BufferPosition(1, 0), new BufferPosition(1, 2), "  ");
		thirdLine = syntaxDocument.buffer.document.paragraphRangeAtIndex(2);
		continuedColors = SyntaxPresentation.foreground(syntaxDocument, syntaxTheme, thirdLine.start, thirdLine.end);
		require(continuedColors.length > 0 && continuedColors[0].color != syntaxTheme.tokenColor(syntax.HighlightToken.COMMENT),
			"syntax presentation retained stale multiline state after an edit");
		var symbolDocument = new Document("symbols.hx", "🙂 + 42", syntaxes);
		var symbolColors = SyntaxPresentation.foreground(symbolDocument, syntaxTheme, 0,
			symbolDocument.buffer.document.codepointCount);
		require(symbolColors.length == 3 && symbolColors[0].start == 0 && symbolColors[0].end == 1,
			"syntax token boundaries split an astral character outside a string");
		var clock = new FakeEditorClock();
		var completionDocument = new Document("words.txt", "alpha alphabet al", syntaxes), completions = new CompletionRegistry();
		completions.add("core", new DocumentWordCompletionProvider());
		var completion = completions.request(completionDocument, completionDocument.buffer.endPosition());
		require(completion.replaceFrom.equals(new BufferPosition(0, 15)) && completion.items.length == 2
			&& completion.items[0].label == "alpha" && completion.items[1].label == "alphabet",
			"document word completion did not use the typed replacement prefix");
		var visual = new VisualLineMap(new TextBuffer("abcdef\nxy\n123456\nlast"), 3);
		require(visual.rowCount() == 7
			&& visual.rowAt(new BufferPosition(0, 4)) == 1
			&& visual.positionAt(1, 1).equals(new BufferPosition(0, 4))
			&& visual.moveVertical(new BufferPosition(0, 4), 1).equals(new BufferPosition(1, 1)),
			"wrapped visual-line mapping did not preserve document positions");
		require(visual.toggleFold(1, 2) && visual.rowCount() == 5
			&& visual.rowAt(new BufferPosition(2, 4)) == 2, "collapsed visual-line mapping did not hide its document range");
		require(visual.reveal(new BufferPosition(2, 4)) && visual.rowCount() == 7
			&& visual.rowAt(new BufferPosition(2, 4)) == 4, "caret reveal did not expand a containing fold");
		var window = Native.window_create("view-test", 640, 160), renderer = new Renderer(window, "ignored-headlessly.ttf", 15),
			document = new Document("unused", "abcdef\nxy\n123456\nline four\nline five\nline six\nline seven\nline eight\nline nine\nline ten\nline eleven\nline twelve", syntaxes),
			view = new EditorView(document, renderer, new Theme(), 640, 160, new BufferSelection(), clock);
		var wrappedWidth = EditorView.GUTTER_WIDTH + EditorView.SCROLLBAR_SIZE + EditorView.PADDING + renderer.textWidth("MMM");
		view.setBounds(0, 0, wrappedWidth, 160);
		view.setWordWrap(true);
		require(view.visualLines.rowCount() > document.buffer.lineCount(), "view word wrapping did not create visual rows");
		view.selection.setCursor(document.buffer, new BufferPosition(0, 4));
		view.cursorChanged();
		view.moveVertical(1, false);
		require(view.selection.cursor.equals(new BufferPosition(1, 1)), "view vertical movement did not follow wrapped rows");
		view.selection.setCursor(document.buffer, new BufferPosition(0, 4));
		view.cursorChanged();
		view.moveVertical(1, true);
		require(view.selection.cursor.equals(new BufferPosition(1, 1)) && view.selection.anchor.equals(new BufferPosition(0, 4))
			&& view.selection.selectedText(document.buffer) == "ef\nx", "wrapped selection did not retain physical buffer positions");
		require(view.toggleFold(1, 2) && view.visualLines.rowAt(new BufferPosition(2, 1)) == view.visualLines.rowAt(new BufferPosition(1, 1)),
			"view folding did not collapse physical lines into its marker row");
		var hiddenMatch = DocumentSearch.find(document, "123456", new SearchOptions())[0];
		require(DocumentSearch.select(document, view.selection, hiddenMatch), "search did not select its hidden physical match");
		view.cursorChanged();
		require(view.visualLines.rowAt(view.selection.cursor) != view.visualLines.rowAt(new BufferPosition(1, 1)),
			"searching into a fold did not reveal its physical line");
		view.setWordWrap(false);
		view.setBounds(0, 0, 640, 160);
		view.mouseDown(Platform.MOUSE_LEFT, EditorView.GUTTER_WIDTH + 20, EditorView.HEADER_HEIGHT + EditorView.PADDING + 2, 2);
		view.mouseUp(Platform.MOUSE_LEFT);
		require(view.selection.selectedText(document.buffer) == "abcdef", "double click did not select a word");
		view.mouseDown(Platform.MOUSE_LEFT, EditorView.GUTTER_WIDTH + 20, EditorView.HEADER_HEIGHT + EditorView.PADDING + 2, 3);
		view.mouseUp(Platform.MOUSE_LEFT);
		require(view.selection.selectedText(document.buffer) == "abcdef\n", "triple click did not select a complete line");
		view.selection.setCursor(document.buffer, document.buffer.positionAt(0, 5));
		view.moveVertical(1, false);
		view.moveVertical(1, false);
		require(view.selection.cursor.line == 2 && view.selection.cursor.column == 5, "view lost preferred cursor column");
		view.movePage(1, false);
		require(view.selection.cursor.line > 2, "page movement did not use the viewport height");
		view.wheel(-100, 0);
		require(view.scrollY > 0, "mouse wheel did not scroll document");
		view.restoreScroll(0, 0);
		view.mouseDown(Platform.MOUSE_LEFT, 639, 100);
		view.mouseMove(639, 150);
		view.mouseUp(Platform.MOUSE_LEFT);
		require(view.scrollY > 0, "vertical scrollbar drag did not scroll the document");
		view.mouseDown(Platform.MOUSE_LEFT, EditorView.GUTTER_WIDTH + 2,
			EditorView.HEADER_HEIGHT + EditorView.PADDING + 2);
		view.mouseMove(EditorView.GUTTER_WIDTH + 40,
			EditorView.HEADER_HEIGHT + EditorView.PADDING + renderer.lineHeight + 2);
		view.mouseUp(Platform.MOUSE_LEFT);
		require(view.selection.hasSelection(), "mouse drag did not select text");
		view.restoreScroll(0, 0);
		var beforeAutoscroll = view.scrollY;
		view.mouseDown(Platform.MOUSE_LEFT, EditorView.GUTTER_WIDTH + 10, EditorView.HEADER_HEIGHT + EditorView.PADDING + 2);
		view.mouseMove(EditorView.GUTTER_WIDTH + 10, 220);
		clock.advance(0.1);
		renderer.begin();
		view.draw("unused");
		renderer.present();
		view.mouseUp(Platform.MOUSE_LEFT);
		require(view.scrollY > beforeAutoscroll && view.selection.cursor.line > 0, "timed drag autoscroll did not advance the viewport");
		renderer.begin();
		view.draw("unused");
		renderer.present();
		renderer.destroy();
		Platform.require(Native.window_destroy(window), "destroy view test window");
		Native.shutdown();
		Sys.println("PASS: editor viewport navigation, scrolling, clipping, and mouse selection");
		return 0;
	}
}
