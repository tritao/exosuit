package ui;

import Color;
import TextColorRange;
import editor.SyntaxPresentation;
import editor.DecorationPresentation;
import editor.EditorCoordinates;
import editor.CaretPresentation;
import nativekit.ui.widgets.text.TextSelection;
import nativekit.ui.widgets.text.TextEditIntent;
import plugin.PluginDecorationRegistry;
import search.SearchMatch;
import nativekit.ui.widgets.text.TextDecoration;
import nativekit.ui.widgets.text.TextDecorationKind;
import LayoutAxis;
import LayoutDirection;
import LayoutStyle;
import nativekit.ui.core.View;
import nativekit.ui.theme.Theme;
import nativekit.ui.widgets.KeyedView;
import nativekit.ui.widgets.layout.Row;
import nativekit.ui.widgets.scroll.ScrollView;
import nativekit.ui.widgets.text.TextArea;
import nativekit.ui.widgets.text.EditTransaction;
import editor.Document;
import editor.BufferSelection;

/**
 * One editor tab: a line-number gutter next to a `TextArea` sharing the
 * active document's `TextBuffer.document` EditorKit document. Gutter and
 * text share a single scroll container, so they always scroll together.
 *
 * Syntax providers adapt the document's cached UTF-16 tokens to the retained
 * layout's codepoint ranges. Multiple selections paint through UIKit and
 * delegate their mutations to the normalized buffer transaction model.
 */
class EditorPane implements View {
	public final document:Document;
	/**
	 * Shared with the `ui.UiDocumentView` `WorkbenchHost.openDocument` hands
	 * back for this same document, so `command.EditorCommands`/`controller.*`
	 * operations dispatched through `command.CommandContext` (undo, indent,
	 * line operations, ...) and this pane's own typing both act on one
	 * caret/undo-bookkeeping state. Callers that don't need that (tests,
	 * ad-hoc panes) may omit it and get a private one, as before.
	 */
	public final selection:BufferSelection;
	final onEdited:Void->Void;
	final editorTheme:style.Theme;
	final decorations:PluginDecorationRegistry;
	final searchMatches:Void->Array<SearchMatch>;
	final searchRevision:Void->Int;
	final foregroundProvider:(Int, Int)->Array<TextColorRange>;
	final decorationProvider:(Int, Int)->Array<TextDecoration>;
	final caretPresentation = new CaretPresentation();
	var presentationRevision:Int = 0;
	var previousPresentation:Array<Int> = [];
	final selectionProvider:Void->TextSelection;
	final selectionHandler:TextSelection->Void;
	var widgetSelection:TextSelection;
	final additionalProvider:Void->Array<TextSelection>;
	final editIntentHandler:TextEditIntent->Bool;
	final selectedTextProvider:Void->Null<String>;

	public function new(document:Document, theme:Theme, onEdited:Void->Void, ?selection:BufferSelection, ?editorTheme:style.Theme,
			?decorations:PluginDecorationRegistry, ?searchMatches:Void->Array<SearchMatch>, ?searchRevision:Void->Int) {
		this.document = document;
		this.decorations = decorations == null ? new PluginDecorationRegistry() : decorations;
		this.searchMatches = searchMatches == null ? function() return [] : searchMatches;
		this.searchRevision = searchRevision == null ? function() return 0 : searchRevision;
		foregroundProvider = provideForeground;
		decorationProvider = provideDecorations;
		this.onEdited = onEdited;
		this.editorTheme = editorTheme == null ? new style.Theme() : editorTheme;
		this.selection = selection == null ? new BufferSelection() : selection;
		widgetSelection = new TextSelection(EditorCoordinates.codepoint(document, this.selection.anchor),
			EditorCoordinates.codepoint(document, this.selection.cursor));
		selectionProvider = provideSelection;
		selectionHandler = handleSelection;
		additionalProvider = provideAdditionalSelections;
		editIntentHandler = handleEditIntent;
		selectedTextProvider = provideSelectedText;
	}

	static function color(value:Int):Color {
		return Color.fromBytes((value >>> 24) & 255, (value >>> 16) & 255,
			(value >>> 8) & 255, value & 255);
	}

	function provideForeground(start:Int, end:Int):Array<TextColorRange> {
		return [for (range in SyntaxPresentation.foreground(document, editorTheme, start, end))
			new TextColorRange(range.start, range.end, color(range.color))];
	}

	function provideDecorations(start:Int, end:Int):Array<TextDecoration> {
		var ranges = caretPresentation.ranges(start, end);
		for (range in DecorationPresentation.ranges(document, editorTheme,
			decorations.forDocument(document), searchMatches(), start, end)) ranges.push(range);
		return [for (range in ranges)
			new TextDecoration(range.start, range.end, color(range.color), switch range.kind {
				case Background: TextDecorationKind.Background;
				case WholeLineBackground: TextDecorationKind.WholeLineBackground;
				case WavyUnderline: TextDecorationKind.WavyUnderline;
			})];
	}

	function provideSelection():TextSelection {
		var anchor = EditorCoordinates.codepoint(document, selection.anchor);
		var focus = EditorCoordinates.codepoint(document, selection.cursor);
		if (widgetSelection.anchor != anchor || widgetSelection.focus != focus)
			widgetSelection = new TextSelection(anchor, focus);
		return widgetSelection;
	}

	function handleSelection(value:TextSelection):Void {
		widgetSelection = value;
		var anchor = EditorCoordinates.position(document, value.anchor);
		var cursor = EditorCoordinates.position(document, value.focus);
		if (!selection.anchor.equals(anchor) || !selection.cursor.equals(cursor)) {
			selection.restore(document.buffer, cursor, anchor);
			onEdited();
		}
	}

	function provideAdditionalSelections():Array<TextSelection> {
		var ranges = selection.allRanges();
		return [for (index in 1...ranges.length)
			new TextSelection(EditorCoordinates.codepoint(document, ranges[index].anchor),
				EditorCoordinates.codepoint(document, ranges[index].cursor))];
	}

	function provideSelectedText():Null<String> {
		for (range in selection.documentRanges()) if (range.isCollapsed()) return null;
		return [for (range in selection.documentRanges()) document.buffer.textRange(range.start(), range.end())].join("\n");
	}

	function handleEditIntent(intent:TextEditIntent):Bool {
		if (selection.rangeCount() == 1) return false;
		switch intent {
			case Insert(text): document.buffer.replaceSelections(selection, [text]);
			case Paste(text):
				var normalized = StringTools.replace(StringTools.replace(text, "\r\n", "\n"), "\r", "\n");
				var lines = normalized.split("\n");
				document.buffer.replaceSelections(selection, lines.length == selection.rangeCount() ? lines : [normalized]);
			case DeleteBackward: document.buffer.deleteSelections(selection, true);
			case DeleteForward: document.buffer.deleteSelections(selection, false);
		}
		onEdited();
		return true;
	}

	function handleEdit(transaction:EditTransaction):Void {
		document.buffer.applyEditTransaction(selection, transaction);
		onEdited();
	}

	public function build(context:nativekit.ui.core.BuildContext):nativekit.ui.core.RenderNode {
		var gutter = new EditorGutter("gutter:" + document.id, document.buffer,
			color(editorTheme.foregroundMuted), color(editorTheme.surface));
		var editorStyle = new LayoutStyle();
		editorStyle.width = LayoutAxis.grow();
		editorStyle.height = LayoutAxis.fit();
		editorStyle.background = color(editorTheme.editorBackground);
		var area = TextArea.withDocument("editor:" + document.id, document.buffer.document,
			handleEdit, editorStyle, null, null, color(editorTheme.editorForeground));
		area.colorRangeProvider = foregroundProvider;
		area.decorationProvider = decorationProvider;
		area.selectionProvider = selectionProvider;
		area.onSelectionChange = selectionHandler;
		area.additionalSelectionProvider = additionalProvider;
		area.onEditIntent = editIntentHandler;
		area.selectionTextProvider = selectedTextProvider;
		var current = [document.buffer.stateId, decorations.revision, searchRevision(),
			editorTheme.searchMatch, editorTheme.editorForeground];
		for (kind in 0...8) current.push(editorTheme.tokenColor(kind));
		var changed = caretPresentation.update(document, selection, editorTheme);
		if (current.length != previousPresentation.length) changed = true;
		if (!changed)
			for (index in 0...current.length)
				if (current[index] != previousPresentation[index]) changed = true;
		if (changed) {
			presentationRevision++;
			previousPresentation = current;
		}
		area.presentationRevision = presentationRevision;
		var rowStyle = new LayoutStyle();
		rowStyle.width = LayoutAxis.grow();
		rowStyle.height = LayoutAxis.fit();
		rowStyle.direction = LayoutDirection.LeftToRight;
		var row = new Row("editor-row:" + document.id, [
			new KeyedView("gutter", gutter),
			new KeyedView("text", area)
		], rowStyle);
		var scrollStyle = new LayoutStyle();
		scrollStyle.width = LayoutAxis.grow();
		scrollStyle.height = LayoutAxis.grow();
		scrollStyle.background = color(editorTheme.editorBackground);
		return new ScrollView("editor-scroll:" + document.id, row, scrollStyle).build(context);
	}
}
