package ui;

import haxeon.ui.TextLayout.TextPosition;

import haxeon.ui.FontFamily;
import haxeon.ui.LayoutVisualKind;

import haxeon.ui.TextStyle;

import haxeon.ui.Rect;
import haxeon.ui.widgets.scroll.ScrollController;
import haxeon.ui.widgets.scroll.ScrollAxis;

import haxeon.ui.Color;
import haxeon.ui.Point;
import haxeon.ui.Insets;
import haxeon.ui.TextColorRange;
import editor.SyntaxPresentation;
import editor.DecorationPresentation;
import editor.EditorCoordinates;
import editor.CaretPresentation;
import haxeon.ui.widgets.text.TextSelection;
import haxeon.ui.widgets.text.TextEditIntent;
import plugin.PluginDecorationRegistry;
import search.SearchMatch;
import haxeon.ui.widgets.text.TextDecoration;
import haxeon.ui.widgets.text.TextDecorationKind;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.View;
import haxeon.ui.theme.Theme;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.text.TextArea;
import haxeon.ui.widgets.text.EditTransaction;
import editor.Document;
import editor.BufferSelection;
import editor.BufferRange;
import haxeon.ui.widgets.text.TextEditorLayout;
import haxeon.ui.widgets.text.TextNavigationIntent;

/**
 * One editor tab: a line-number gutter next to a `TextArea` sharing the
 * active document's `TextBuffer.document` EditorKit document. Gutter and
 * text share resolved source coordinates; the gutter stays fixed horizontally.
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
	final viewportGeometry = new editor.EditorViewportGeometry();
	var previousWrap:Null<Bool> = null;
	var wrapAnchorLine:Int = -1;
	final minimap:EditorMinimap;
	public var minimapEnabled:Bool = true;
	public var fontSize:Float = 15.0;
	public var applicationZoom:Float = 1.0;
	public var editSettings:config.Settings = new config.Settings();
	var editingLayout:Null<TextEditorLayout> = null;

	final onEdited:Void->Void;
	public var caretRect(default, null):Null<Rect> = null;
	public var onResolvedEditor:Null<Rect->haxeon.ui.core.WidgetId->Void> = null;
	public var onActivated:Null<Void->Void> = null;
	public var onNavigationKey:Null<haxeon.ui.core.UiEvent->Bool> = null;
	public var onDefinition:Null<Void->Void> = null;
	public var onContextMenu:Null<haxeon.ui.core.UiEvent->Void> = null;
	public var onCaretRectChanged:Null<Void->Void> = null;
	public var onEditorAction:Null<haxeon.ui.widgets.text.TextEditorAction->Bool>;
	public var requestCursorReveal:Void->Void = function() {};
	public var consumeCursorReveal:Void->Bool = function() return false;
	final editorTheme:style.Theme;
	final decorations:PluginDecorationRegistry;
	final searchMatches:Void->Array<SearchMatch>;
	final searchRevision:Void->Int;
	final foregroundProvider:(Int, Int)->Array<TextColorRange>;
	final decorationProvider:(Int, Int)->Array<TextDecoration>;
	final caretPresentation = new CaretPresentation();
	var presentationRevision:Int = 0;
	var semanticSnapshot:Null<language.LanguageSemanticSnapshot>;
	var semanticRevision:Int = 0;

	public function setSemanticTokens(value:Null<language.LanguageSemanticSnapshot>):Void {
		if (semanticSnapshot == value) return;
		semanticSnapshot = value;
		semanticRevision++;
	}
	var pointerOffset:Int = -1;
	var definitionStart:Int = -1;
	var definitionEnd:Int = -1;
	var definitionState:Int = -1;

	public function pointerModifiersChanged(modifiers:Int):Void {
		if (updateDefinitionUnderline(modifiers == haxeon.ui.core.UiModifier.Control)) onEdited();
	}

	function updateDefinitionUnderline(control:Bool):Bool {
		var start = -1, end = -1;
		if (control && pointerOffset >= 0 && pointerOffset < document.buffer.document.codepointCount) {
			var position = EditorCoordinates.position(document, pointerOffset);
			var line = document.buffer.line(position.line);
			for (token in document.highlighter.line(position.line).tokens)
				if (position.column >= token.start && position.column < token.start + token.length &&
					token.kind != syntax.HighlightToken.NORMAL && token.kind != syntax.HighlightToken.TYPE)
					return updateDefinitionUnderline(false);
			var identifier = ~/[A-Za-z_][A-Za-z0-9_]*/g;
			var at = 0;
			while (identifier.matchSub(line, at)) {
				var match = identifier.matchedPos();
				if (position.column >= match.pos && position.column < match.pos + match.len) {
					start = EditorCoordinates.codepoint(document, new editor.BufferPosition(position.line, match.pos));
					end = EditorCoordinates.codepoint(document, new editor.BufferPosition(position.line, match.pos + match.len));
					break;
				}
				at = match.pos + match.len;
			}
		}
		if (start == definitionStart && end == definitionEnd && definitionState == document.buffer.stateId) return false;
		definitionStart = start; definitionEnd = end;
		definitionState = document.buffer.stateId;
		return true;
	}
	var previousPresentation:Array<Int> = [];
	final selectionProvider:Void->TextSelection;
	final selectionHandler:TextSelection->Void;
	var widgetSelection:TextSelection;
	final additionalProvider:Void->Array<TextSelection>;
	final editIntentHandler:(TextEditIntent, TextEditorLayout)->Bool;
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
		minimap = new EditorMinimap(document, this.scrollController, this.editorTheme, new editor.MinimapModel(), viewportGeometry);
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

	public function deletionBoundary(position:editor.BufferPosition, direction:Int):editor.BufferPosition {
		if (editingLayout == null || editingLayout.isDisposed()) return document.buffer.graphemeOffset(position, direction);
		editingLayout.updateDocument(document.buffer.document, editingLayout.width, editingLayout.textStyle, editingLayout.paragraphStyle);
		var point = EditorCoordinates.codepoint(document, position);
		return EditorCoordinates.position(document, direction < 0 ? editingLayout.previousGrapheme(point) : editingLayout.nextGrapheme(point));
	}

	static function color(value:Int):Color {
		return Color.fromBytes((value >>> 24) & 255, (value >>> 16) & 255,
			(value >>> 8) & 255, value & 255);
	}

	function provideForeground(start:Int, end:Int):Array<TextColorRange> {
		return [for (range in editor.SemanticPresentation.foreground(document, editorTheme, semanticSnapshot, start, end))
			new TextColorRange(range.start, range.end, color(range.color))];
	}

	function provideDecorations(start:Int, end:Int):Array<TextDecoration> {
		var ranges = caretPresentation.ranges(start, end);
		for (range in DecorationPresentation.ranges(document, editorTheme,
			decorations.forDocument(document), searchMatches(), start, end)) ranges.push(range);
		var result = [for (range in ranges)
			new TextDecoration(range.start, range.end, color(range.color), switch range.kind {
				case Background: TextDecorationKind.Background;
				case WholeLineBackground: TextDecorationKind.WholeLineBackground;
				case WavyUnderline: TextDecorationKind.WavyUnderline;
			})];
		if (definitionState == document.buffer.stateId && definitionStart >= 0 && definitionStart < end && definitionEnd > start)
			result.push(new TextDecoration(definitionStart, definitionEnd, color(editorTheme.editorForeground), TextDecorationKind.Underline));
		return result;
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

	function handleEditIntent(intent:TextEditIntent, layout:TextEditorLayout):Bool {
		var policyEdit = switch intent { case DeleteBackward | DeleteForward | Insert("\n"): true; case _: false; };
		if (selection.rangeCount() == 1 && !policyEdit) return false;
		desiredVerticalXs = [];
		switch intent {
			case Insert("\n"): editor.EditorActions.insertNewline(document.buffer, selection, editSettings.tabWidth, editSettings.insertSpaces, document.highlighter, editSettings.indentSize, document.indentation.cache);
			case Insert(text): document.buffer.replaceSelections(selection, [text]);
			case Paste(text):
				var normalized = StringTools.replace(StringTools.replace(text, "\r\n", "\n"), "\r", "\n");
				var lines = normalized.split("\n");
				document.buffer.replaceSelections(selection, lines.length == selection.rangeCount() ? lines : [normalized]);
			case DeleteBackward: editor.EditorActions.backspace(document.buffer, selection, editSettings.tabWidth, deletionBoundary, editSettings.indentSize);
			case DeleteForward: document.buffer.deleteSelections(selection, false, deletionBoundary);
			case DeleteWordBackward(macStyle): deleteWords(layout, true, macStyle);
			case DeleteWordForward(macStyle): deleteWords(layout, false, macStyle);
		}
		requestCursorReveal();
		onEdited();
		return true;
	}

	function deleteWords(layout:TextEditorLayout, backwards:Bool, macStyle:Bool):Void {
		document.buffer.deleteSelections(selection, backwards, function(position, direction) {
			return EditorCoordinates.position(document, layout.moveWord(
				EditorCoordinates.codepoint(document, position), direction, macStyle));
		});
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
			requestCursorReveal();
			onEdited();
		}
		return true;
	}

	function handleEdit(transaction:EditTransaction):Void {
		desiredVerticalXs = [];
		document.buffer.applyEditTransaction(selection, transaction);
		requestCursorReveal();
		onEdited();
	}

	/** One layout bridge applies the retained dimensions atomically after shaping. */
	function applySourceGeometry(node:Null<haxeon.ui.core.RenderNode>):Bool {
		if (node == null) return false;
		var latest = haxeon.ui.core.RenderNode.latest(node), style = latest.layout.style;
		var changed = style.width.sizing != haxeon.ui.LayoutSizing.Fixed || style.height.sizing != haxeon.ui.LayoutSizing.Fixed ||
			Math.abs(style.width.value - viewportGeometry.contentWidth) > 0.01 || Math.abs(style.height.value - viewportGeometry.contentHeight) > 0.01 ||
			Math.abs(style.padding.right - viewportGeometry.rightPadding()) > 0.01 || Math.abs(style.padding.bottom - viewportGeometry.trailingSpace()) > 0.01;
		if (changed) {
			style.width = LayoutAxis.fixed(viewportGeometry.contentWidth); style.height = LayoutAxis.fixed(viewportGeometry.contentHeight);
			style.padding = new Insets(0, 0, viewportGeometry.rightPadding(), viewportGeometry.trailingSpace());
		}
		return changed;
	}

	public function build(context:haxeon.ui.core.BuildContext):haxeon.ui.core.RenderNode {
		var viewportNode:Null<haxeon.ui.core.RenderNode> = null;
		var editorNode:Null<haxeon.ui.core.RenderNode> = null;
		var gutter = new EditorGutter("gutter:" + document.id, document.buffer,
			color(editorTheme.foregroundMuted), color(editorTheme.surface), fontSize, selection.cursor.line, context.theme.tokens.accent);
		viewportGeometry.configure(editSettings.wordWrap, minimapEnabled);
		var editorStyle = new LayoutStyle();
		editorStyle.width = viewportGeometry.viewportWidth > 0 ? LayoutAxis.fixed(viewportGeometry.contentWidth) : LayoutAxis.grow();
		// Blank viewport space and the trailing scroll margin belong to the
		// text field, so pointer focus/selection uses its normal hit-test path.
		editorStyle.height = viewportGeometry.viewportHeight > 0 ? LayoutAxis.fixed(viewportGeometry.contentHeight) : LayoutAxis.grow();
		editorStyle.padding = new Insets(0, 0, viewportGeometry.rightPadding(), viewportGeometry.trailingSpace());
		editorStyle.background = color(editorTheme.editorBackground);
		var area = TextArea.withDocument("editor:" + document.id, document.buffer.document,
			handleEdit, editorStyle, null, new TextStyle(fontSize, FontFamily.Monospace), color(editorTheme.editorForeground));
		area.codeWordBoundaries = true;
		area.wrap = editSettings.wordWrap ? haxeon.ui.TextWrap.WordCharacter : haxeon.ui.TextWrap.None;
		if (previousWrap != null && previousWrap != editSettings.wordWrap) {
			if (editingLayout != null && editingLayout.paragraphCount > 0)
				wrapAnchorLine = editingLayout.paragraphIndexAtY(scrollController.offsetY + editingLayout.paragraphCaret(0).y);
			scrollController.jumpTo(0.0, scrollController.offsetY);
		}
		previousWrap = editSettings.wordWrap;
		area.renderWhitespace = editSettings.renderWhitespace;
		area.whitespaceColor = color(editorTheme.foregroundSubtle);
		area.tabWidth = Std.int(Math.max(1, editSettings.tabWidth));
		area.colorRangeProvider = foregroundProvider;
		area.decorationProvider = decorationProvider;
		area.selectionProvider = selectionProvider;
		area.onLayoutResolved = function(layout, geometry) {
			editingLayout = layout;
			gutter.resolveTextLayout(layout, geometry);
			minimap.resolveTextLayout(layout);
			if (viewportNode == null || viewportNode.resolved == null || scrollController.viewportHeight <= 0) return;
			var caret = layout.caret(new TextPosition(EditorCoordinates.codepoint(document, selection.cursor), 0));
			var bounds = viewportNode.globalBounds();
			viewportGeometry.setViewport(bounds.width, bounds.height);
			var metrics = layout.measure();
			viewportGeometry.resolveSource(metrics.width, metrics.height,
				layout.paragraphStyle.lineHeight == null ? Math.abs(caret.descender - caret.ascender) : layout.paragraphStyle.lineHeight);
			if (applySourceGeometry(editorNode)) { context.requestLayoutFeedback(); return; }
			if (Math.abs(scrollController.contentHeight - viewportGeometry.contentHeight) > 0.01 ||
				Math.abs(scrollController.contentWidth - viewportGeometry.contentWidth) > 0.01) { context.requestLayoutFeedback(); return; }
			if (wrapAnchorLine >= 0) {
				var line = Std.int(Math.min(wrapAnchorLine, layout.paragraphCount - 1));
				wrapAnchorLine = -1;
				if (scrollController.jumpTo(0.0, Math.max(0, layout.paragraphCaret(line).y - layout.paragraphCaret(0).y))) context.requestLayoutFeedback();
			}
			if (!consumeCursorReveal()) return;
			var target = viewportGeometry.reveal(caret.x, caret.y + Math.min(caret.ascender, caret.descender),
				caret.y + Math.max(caret.ascender, caret.descender), scrollController.offsetX, scrollController.offsetY);
			if (scrollController.jumpTo(target.x, target.y)) context.requestLayoutFeedback();
		};
		area.onCaretRect = function(rect) {
			var previous = caretRect;
			caretRect = rect;
			var changed = previous == null ? rect != null : rect == null ||
				previous.x != rect.x || previous.y != rect.y || previous.width != rect.width || previous.height != rect.height;
			if (changed && onCaretRectChanged != null)
				onCaretRectChanged();
		};
		area.onTextPointerMove = function(offset, event) {
			pointerOffset = offset;
			if (updateDefinitionUnderline(event.modifiers == haxeon.ui.core.UiModifier.Control)) onEdited();
		};
		area.onTextPointerDown = function(offset, event) {
			var definition = event.button == 0 && event.modifiers == haxeon.ui.core.UiModifier.Control;
			if (event.button != 1 && !definition) return false;
			if (onActivated != null) onActivated();
			var position = EditorCoordinates.position(document, offset);
			var insideSelection = false;
			if (!definition) for (range in selection.allRanges())
				if (!range.isCollapsed() && !position.before(range.start()) && !range.end().before(position)) insideSelection = true;
			if (!insideSelection) selection.setCursor(document.buffer, position);
			onEdited();
			requestCursorReveal();
			if (definition) { if (onDefinition != null) onDefinition(); }
			else if (onContextMenu != null) onContextMenu(event);
			return true;
		};
		area.onSelectionChange = selectionHandler;
		area.onEditorAction = onEditorAction;
		area.onCaretRevealRequest = requestCursorReveal;
		area.additionalSelectionProvider = additionalProvider;
		area.onSelectionDragScroll = function(delta) return scrollController.jumpTo(scrollController.offsetX, scrollController.offsetY + delta);
		area.historyManagedExternally = true;
		area.onEditIntent = editIntentHandler;
		area.onNavigationIntent = navigationIntentHandler;
		area.pageHeightProvider = function() return scrollController.viewportHeight;
		area.selectionTextProvider = selectedTextProvider;
		var current = [document.buffer.stateId, decorations.revision, searchRevision(),
			editorTheme.searchMatch, editorTheme.editorForeground, definitionStart, definitionEnd, definitionState, semanticRevision];
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
		var scrollStyle = new LayoutStyle();
		scrollStyle.width = LayoutAxis.grow();
		scrollStyle.height = LayoutAxis.grow();
		scrollStyle.background = color(editorTheme.editorBackground);
		var containerStyle = new LayoutStyle();
		containerStyle.width = LayoutAxis.grow();
		containerStyle.height = LayoutAxis.grow();
		containerStyle.direction = LayoutDirection.LeftToRight;
		containerStyle.clipHorizontal = true;
		containerStyle.clipVertical = true;
		var container = new haxeon.ui.core.RenderNode(context.id("editor-container:" + document.id), LayoutVisualKind.Box, containerStyle);
		container.setStyleIdentity("editor-container", "editor-container:" + document.id);
		var viewport = new ScrollView("editor-scroll:" + document.id, area, scrollStyle, editSettings.wordWrap ? ScrollAxis.Vertical : ScrollAxis.Both, scrollController);
		viewport.fillViewport = true;
		viewport.contentExtentProvider = function(width, height) {
			viewportGeometry.setViewport(width, height);
			return {width: viewportGeometry.contentWidth, height: viewportGeometry.contentHeight};
		};
		viewport.scrollbarOverlayHost = container;
		var node = viewport.build(context);
		viewportNode = node;
		node.walk(function(child) {
			if (child.focusable && child.styleKey == "editor:" + document.id) editorNode = child;
		});

		node.onResolved(function(_) {
			var handler = onResolvedEditor;
			if (handler == null) return;
			node.walk(function(child) {
				if (child.focusable && child.styleKey == "editor:" + document.id)
					handler(node.globalBounds(), child.id);
			});
		});
		var activate = function(event:haxeon.ui.core.UiEvent) { if (onActivated != null) onActivated(); };
		container.on(haxeon.ui.core.UiEventKind.Focus, activate, "capture");
		container.on(haxeon.ui.core.UiEventKind.PointerDown, activate, "capture");
		var requestMenu = function(event:haxeon.ui.core.UiEvent) {
			var handler = onContextMenu;
			if (handler == null) return;
			handler(event);
			event.preventDefault();
			event.stopPropagation();
		};
		node.on(haxeon.ui.core.UiEventKind.PointerDown, function(event) {
			if (event.button == 1) requestMenu(event);
		});
		node.on(haxeon.ui.core.UiEventKind.KeyDown, function(event) {
			if (haxeon.ui.core.UiKey.isContextMenuRequest(event.key, event.modifiers)) requestMenu(event);
		});
		container.on(haxeon.ui.core.UiEventKind.KeyDown, function(event) {
			var handler = onNavigationKey;
			if (handler != null && handler(event)) { event.preventDefault(); event.stopPropagation(); }
		}, "capture");
		container.on(haxeon.ui.core.UiEventKind.FocusLost, function(_) {
			if (updateDefinitionUnderline(false)) onEdited();
		}, "capture");
		node.on(haxeon.ui.core.UiEventKind.HoverLeave, function(_) {
			pointerOffset = -1;
			if (updateDefinitionUnderline(false)) onEdited();
		});
		container.add(gutter.build(context));
		container.add(node);
		if (!minimapEnabled) return container;
		minimap.applicationZoom = applicationZoom;
		var preview = minimap.build(context);
		preview.layout.style.positioning = haxeon.ui.LayoutPositioning.Absolute;
		preview.layout.style.zIndex = 10;
		container.add(preview);
		var shadowStyle = new LayoutStyle();
		shadowStyle.positioning = haxeon.ui.LayoutPositioning.Absolute;
		shadowStyle.width = LayoutAxis.fixed(8.0);
		shadowStyle.height = LayoutAxis.grow();
		shadowStyle.zIndex = 9;
		var shadow = new haxeon.ui.core.RenderNode(context.id("minimap-shadow:" + document.id), LayoutVisualKind.Custom, shadowStyle);
		shadow.hitTestSelf = false;
		shadow.onPaint(function(canvas, geometry) {
			if (!viewportGeometry.overlapsMinimap(scrollController.offsetX) || geometry.height <= 0) return;
			canvas.fillLinearGradientRect(new Rect(0, 0, geometry.width, geometry.height), 0, 0, geometry.width, 0, [
				new haxeon.ui.GradientStop(0.0, Color.rgba(0, 0, 0, 0)),
				new haxeon.ui.GradientStop(1.0, Color.rgba(0, 0, 0, editorTheme.lightSyntax ? 0.15 : 0.35))
			]);
		});
		container.add(shadow);
		container.onResolved(function(geometry) {
			var width = viewportGeometry.minimapWidth;
			var x = Math.max(0.0, geometry.width - width);
			if (shadowStyle.positionX != x - 8.0) { shadowStyle.positionX = x - 8.0; context.requestLayoutFeedback(); }
			if (preview.layout.style.positionX != x) { preview.layout.style.positionX = x; context.requestLayoutFeedback(); }
			if (preview.layout.style.width.value != width) {
				preview.layout.style.width = LayoutAxis.fixed(width);
				context.requestLayoutFeedback();
			}
			preview.hitTestSelf = width > 0;
		});
		return container;
	}
}
