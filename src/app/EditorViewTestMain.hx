package app;

import editor.Document;
import editor.SyntaxPresentation;
import editor.DecorationPresentation;
import editor.EditorCoordinates;
import editor.CaretPresentation;
import plugin.PluginDecorationRegistry;
import plugin.PluginDecorationKind;
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
		var preview = new editor.MinimapModel();
		var previewDocument = new Document("preview.hx", "class Main {\n\t🙂x\n}", syntaxes);
		preview.update(previewDocument);
		require(preview.rows.length == 3 && preview.rows[1].spans[0].start == 4 && preview.rows[1].spans[0].length == 1 && preview.rows[1].spans[1].start == 5,
			"minimap tabs or Unicode columns are incorrect");
		require(preview.rows[0].spans[0].kind == syntax.HighlightToken.KEYWORD, "minimap lost syntax colors");
		var retainedRow = preview.rows[0];
		preview.update(previewDocument);
		require(preview.rows[0] == retainedRow, "unchanged minimap rebuilt its spans");
		previewDocument.buffer.replaceAllText("x", new BufferSelection());
		preview.update(previewDocument);
		require(preview.rows.length == 1 && preview.rows[0].spans[0].length == 1, "minimap edit left stale rows");
		previewDocument.buffer.undo(new BufferSelection());
		preview.update(previewDocument);
		require(preview.rows.length == 3, "minimap undo did not restore rows");
		var largePreview = new Document("large.hx", [for (_ in 0...10000) "class Main {}"].join("\n"), syntaxes);
		preview.update(largePreview);
		require(preview.rows.length == editor.MinimapModel.MAX_ROWS && preview.rows[511].line == 9999,
			"large minimap is unbounded or misses the end of the file");
		require(preview.rows[0].spans[0].kind == 0, "large minimap unnecessarily requests syntax highlighting");
		require(editor.MinimapModel.scrollTarget(0, 100, 1000, 200) == 0 &&
			editor.MinimapModel.scrollTarget(100, 100, 1000, 200) == 800 &&
			editor.MinimapModel.scrollTarget(50, 100, 1000, 200) == 400 &&
			editor.MinimapModel.scrollTarget(50, 100, 50, 200) == 0,
			"minimap navigation is not centered or clamped");
		var coordinates = new Document(null, "é🙂x\ná🙂\n", syntaxes);
		for (offset in 0...coordinates.buffer.document.codepointCount + 1) {
			var position = EditorCoordinates.position(coordinates, offset);
			require(EditorCoordinates.codepoint(coordinates, position) == offset,
				"caret coordinate roundtrip failed at " + offset);
		}
		require(EditorCoordinates.position(coordinates, 2).column == 3,
			"emoji caret must use UTF-16 buffer columns");
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
		var decorationDocument = new Document("marks.hx", "é🙂value\nsecond", syntaxes);
		var decorationRegistry = new PluginDecorationRegistry();
		var diagnosticDecoration = decorationRegistry.add("language", "error", decorationDocument, 0, 3, 8,
			syntaxTheme.diagnosticError, WavyUnderline);
		var decorationMatches = DocumentSearch.find(decorationDocument, "🙂", new SearchOptions());
		var presented = DecorationPresentation.ranges(decorationDocument, syntaxTheme,
			decorationRegistry.forDocument(decorationDocument), decorationMatches, 0, 7);
		require(presented.length == 2 && presented[0].start == 2 && presented[0].end == 7
			&& presented[0].kind == WavyUnderline && presented[1].start == 1 && presented[1].end == 2,
			"decoration conversion confused Unicode columns or lost diagnostic/search layers");
		require(DecorationPresentation.ranges(decorationDocument, syntaxTheme,
			decorationRegistry.forDocument(decorationDocument), decorationMatches, 8, 10).length == 0,
			"offscreen decorations were returned for another visible chunk");
		decorationRegistry.remove(diagnosticDecoration);
		require(DecorationPresentation.ranges(decorationDocument, syntaxTheme,
			decorationRegistry.forDocument(decorationDocument), [], 0, 7).length == 0,
			"removed diagnostic decoration survived presentation");
		decorationDocument.buffer.replaceRange(new BufferSelection(), new BufferPosition(0, 0), new BufferPosition(0, 0), "x");
		require(DecorationPresentation.ranges(decorationDocument, syntaxTheme, [], decorationMatches, 0, 8).length == 0,
			"search decorations from a previous revision survived an edit");
		decorationRegistry.add("plugin", "empty-line", decorationDocument, 1, 0, 0,
			syntaxTheme.currentLine, WholeLineBackground);
		var reversedRejected = false;
		try {
			decorationRegistry.add("plugin", "reversed", decorationDocument, 0, 4, 1,
				syntaxTheme.currentLine, WholeLineBackground);
		} catch (_:Dynamic) { reversedRejected = true; }
		require(reversedRejected, "registry accepted reversed whole-line columns");
		var wholeLines = DecorationPresentation.ranges(decorationDocument, syntaxTheme,
			decorationRegistry.forDocument(decorationDocument), [], 0, decorationDocument.buffer.document.codepointCount);
		require(wholeLines.length == 1 && wholeLines[0].start == wholeLines[0].end,
			"whole-line presentation lost empty range or accepted reversed columns");
		var caretDocument = new Document("caret.hx", "é🙂(x)\n\n// (ignored)", syntaxes);
		var caretSelection = new BufferSelection(new BufferPosition(0, 3));
		var caretPresentation = new CaretPresentation();
		require(caretPresentation.update(caretDocument, caretSelection, syntaxTheme), "initial caret marks not built");
		var caretMarks = caretPresentation.ranges(0, 6);
		require(caretMarks.length == 3 && caretMarks[0].kind == WholeLineBackground
			&& caretMarks[1].start == 2 && caretMarks[2].start == 4,
			"caret bracket marks lost Unicode coordinates or whole-line layer");
		require(!caretPresentation.update(caretDocument, caretSelection, syntaxTheme),
			"unchanged caret rescanned brackets");
		caretSelection.restore(caretDocument.buffer, new BufferPosition(1, 0), new BufferPosition(1, 0));
		require(caretPresentation.update(caretDocument, caretSelection, syntaxTheme), "caret movement kept old marks");
		caretMarks = caretPresentation.ranges(6, 6);
		require(caretMarks.length == 1 && caretMarks[0].start == caretMarks[0].end,
			"empty current line has no whole-line background");
		caretSelection.restore(caretDocument.buffer, new BufferPosition(2, 3), new BufferPosition(2, 3));
		caretPresentation.update(caretDocument, caretSelection, syntaxTheme);
		require(caretPresentation.ranges(0, caretDocument.buffer.document.codepointCount).length == 1,
			"brackets inside a comment were highlighted");
		caretSelection.restore(caretDocument.buffer, new BufferPosition(0, 3), new BufferPosition(0, 3));
		caretDocument.buffer.replaceRange(caretSelection, new BufferPosition(0, 5), new BufferPosition(0, 6), " ");
		caretPresentation.update(caretDocument, caretSelection, syntaxTheme);
		require(caretPresentation.ranges(0, 6).length == 1, "deleted closing bracket retained its match");
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
