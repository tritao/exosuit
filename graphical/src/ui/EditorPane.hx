package ui;

import TextStyle;

import Rect;
import nativekit.ui.widgets.scroll.ScrollController;
import nativekit.ui.widgets.scroll.ScrollAxis;

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
import editor.BufferRange;
import nativekit.ui.widgets.text.TextEditorLayout;
import nativekit.ui.widgets.text.TextNavigationIntent;

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
	final scrollController:ScrollController;
	final minimap:EditorMinimap;
	public var minimapEnabled:Bool = true;
	public var fontSize:Float = 15.0;
	final onEdited:Void->Void;
	public var caretRect(default, null):Null<Rect> = null;
	public var onResolvedEditor:Null<Rect->nativekit.ui.core.WidgetId->Void> = null;
	public var onActivated:Null<Void->Void> = null;
	public var onContextMenu:Null<nativekit.ui.core.UiEvent->Void> = null;
	public var onCaretRectChanged:Null<Void->Void> = null;
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
	final navigationIntentHandler:(TextNavigationIntent, TextEditorLayout)->Bool;
	final selectedTextProvider:Void->Null<String>;
	var desiredVerticalXs:Array<Float> = [];

	public function new(document:Document, theme:Theme, onEdited:Void->Void, ?selection:BufferSelection, ?editorTheme:style.Theme,
			?decorations:PluginDecorationRegistry, ?searchMatches:Void->Array<SearchMatch>, ?searchRevision:Void->Int, ?scrollController:ScrollController) {
		this.document = document;
		this.scrollController = scrollController == null ? new ScrollController() : scrollController;
		this.decorations = decorations == null ? new PluginDecorationRegistry() : decorations;
		this.searchMatches = searchMatches == null ? function() return [] : searchMatches;
		this.searchRevision = searchRevision == null ? function() return 0 : searchRevision;
		foregroundProvider = provideForeground;
		decorationProvider = provideDecorations;
		this.onEdited = onEdited;
		this.editorTheme = editorTheme == null ? new style.Theme() : editorTheme;
		minimap = new EditorMinimap(document, this.scrollController, this.editorTheme, new editor.MinimapModel());
		this.selection = selection == null ? new BufferSelection() : selection;
		widgetSelection = new TextSelection(EditorCoordinates.codepoint(document, this.selection.anchor),
			EditorCoordinates.codepoint(document, this.selection.cursor));
		selectionProvider = provideSelection;
		selectionHandler = handleSelection;
		additionalProvider = provideAdditionalSelections;
		editIntentHandler = handleEditIntent;
		navigationIntentHandler = handleNavigationIntent;
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
		desiredVerticalXs = [];
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
		desiredVerticalXs = [];
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

	function handleNavigationIntent(intent:TextNavigationIntent, layout:TextEditorLayout):Bool {
		if (selection.rangeCount() < 2) return false;
		var vertical = switch intent { case VisualLine(_, _): true; case _: false; };
		if (!vertical) desiredVerticalXs = [];
		var ranges = selection.allRanges();
		var moved:Array<BufferRange> = [];
		var changed = false;
		for (index in 0...ranges.length) {
			var range = ranges[index];
			var focus = EditorCoordinates.codepoint(document, range.cursor);
			var anchor = EditorCoordinates.codepoint(document, range.anchor);
			var next = focus;
			var extend = switch intent {
				case Character(_, value) | Word(_, value, _) | Paragraph(_, value, _) |
					VisualLine(_, value) | LineBoundary(_, value) | DocumentBoundary(_, value): value;
			};
			switch intent {
				case Character(direction, _):
					next = !extend && anchor != focus ? (direction < 0 ? Std.int(Math.min(anchor, focus)) : Std.int(Math.max(anchor, focus))) :
						direction < 0 ? layout.previousGrapheme(focus) : layout.nextGrapheme(focus);
				case Word(direction, _, macStyle):
					next = !extend && anchor != focus ? (direction < 0 ? Std.int(Math.min(anchor, focus)) : Std.int(Math.max(anchor, focus))) :
						layout.moveWord(focus, direction, macStyle);
				case Paragraph(direction, _, macStyle):
					next = !extend && anchor != focus ? (direction < 0 ? Std.int(Math.min(anchor, focus)) : Std.int(Math.max(anchor, focus))) :
						layout.moveParagraph(focus, direction, macStyle);
				case VisualLine(direction, _):
					if (!extend && anchor != focus) {
						next = direction < 0 ? Std.int(Math.min(anchor, focus)) : Std.int(Math.max(anchor, focus));
						desiredVerticalXs = [];
					} else {
						var caret = layout.caret(new TextPosition(focus, 0));
						var desiredX = index < desiredVerticalXs.length ? desiredVerticalXs[index] : caret.x;
						desiredVerticalXs[index] = desiredX;
						var lineStep = layout.paragraphStyle.lineHeight == null ?
							Math.abs(caret.descender - caret.ascender) : layout.paragraphStyle.lineHeight;
						lineStep = Math.max(1.0, lineStep);
						for (probe in 0...5) {
							var hit = layout.hitTest(desiredX, caret.y + direction * lineStep * (1.0 + probe * 0.25));
							var hitCaret = layout.caret(hit);
							if (direction < 0 ? hitCaret.y < caret.y - 0.01 : hitCaret.y > caret.y + 0.01) {
								next = hit.offset;
								break;
							}
						}
					}
				case LineBoundary(end, _):
					var line = layout.lineRangeAt(focus);
					next = end ? line.end : line.start;
					if (end)
						while (next > line.start) {
							var tail = document.buffer.document.sliceCodepoints(next - 1, next);
							if (tail != "\n" && tail != "\r") break;
							next--;
						}
				case DocumentBoundary(end, _): next = end ? document.buffer.document.codepointCount : 0;
			}
			var nextFocus = EditorCoordinates.position(document, next);
			var nextAnchor = extend ? range.anchor : nextFocus;
			if (!nextFocus.equals(range.cursor) || !nextAnchor.equals(range.anchor)) changed = true;
			moved.push(new BufferRange(nextFocus, nextAnchor));
		}
		if (changed) {
			selection.setRanges(document.buffer, moved);
			onEdited();
		}
		return true;
	}

	function handleEdit(transaction:EditTransaction):Void {
		desiredVerticalXs = [];
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
			handleEdit, editorStyle, null, new TextStyle(fontSize), color(editorTheme.editorForeground));
		area.colorRangeProvider = foregroundProvider;
		area.decorationProvider = decorationProvider;
		area.selectionProvider = selectionProvider;
		area.onLayoutResolved = function(layout, geometry) {
			gutter.resolveTextLayout(layout, geometry);
			minimap.resolveTextLayout(layout);
		};
		area.onCaretRect = function(rect) {
			var previous = caretRect;
			caretRect = rect;
			var changed = previous == null ? rect != null : rect == null ||
				previous.x != rect.x || previous.y != rect.y || previous.width != rect.width || previous.height != rect.height;
			if (changed && onCaretRectChanged != null)
				onCaretRectChanged();
		};
		area.onSelectionChange = selectionHandler;
		area.additionalSelectionProvider = additionalProvider;
		area.onEditIntent = editIntentHandler;
		area.onNavigationIntent = navigationIntentHandler;
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
		var containerStyle = new LayoutStyle();
		containerStyle.width = LayoutAxis.grow();
		containerStyle.height = LayoutAxis.grow();
		containerStyle.direction = LayoutDirection.LeftToRight;
		var container = new nativekit.ui.core.RenderNode(context.id("editor-container:" + document.id), LayoutVisualKind.Box, containerStyle);
		container.setStyleIdentity("editor-container", "editor-container:" + document.id);
		var viewport = new ScrollView("editor-scroll:" + document.id, row, scrollStyle, ScrollAxis.Vertical, scrollController);
		viewport.scrollbarOverlayHost = container;
		var node = viewport.build(context);

		node.onResolved(function(_) {
			var handler = onResolvedEditor;
			if (handler == null) return;
			node.walk(function(child) {
				if (child.focusable && child.styleKey == "editor:" + document.id)
					handler(node.globalBounds(), child.id);
			});
		});
		var activate = function(event:nativekit.ui.core.UiEvent) { if (onActivated != null) onActivated(); };
		container.on(nativekit.ui.core.UiEventKind.Focus, activate, "capture");
		container.on(nativekit.ui.core.UiEventKind.PointerDown, activate, "capture");
		var requestMenu = function(event:nativekit.ui.core.UiEvent) {
			var handler = onContextMenu;
			if (handler == null) return;
			handler(event);
			event.preventDefault();
			event.stopPropagation();
		};
		node.on(nativekit.ui.core.UiEventKind.PointerDown, function(event) {
			if (event.button == 1) requestMenu(event);
		});
		node.on(nativekit.ui.core.UiEventKind.KeyDown, function(event) {
			if (nativekit.ui.core.UiKey.isContextMenuRequest(event.key, event.modifiers)) requestMenu(event);
		});
		container.add(node);
		if (!minimapEnabled) return container;
		var preview = minimap.build(context);
		container.add(preview);
		container.onResolved(function(geometry) {
			var width = geometry.width >= 480 ? 88.0 : 0.0;
			if (preview.layout.style.width.value != width) {
				preview.layout.style.width = LayoutAxis.fixed(width);
				context.requestLayoutFeedback();
			}
			preview.hitTestSelf = width > 0;
		});
		return container;
	}
}
