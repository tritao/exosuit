package ui;

import Color;
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
 * Multi-cursor editing, syntax-colored spans, and independent gutter/text
 * scroll-position sync are not implemented; `TextArea` and `TextDocument`
 * do not currently expose the per-widget scroll offset or styled-span API
 * that would need, and this keeps to the "record the gap; don't hack UIKit"
 * guidance rather than reaching around the widget for it.
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
	final theme:Theme;
	final onEdited:Void->Void;

	public function new(document:Document, theme:Theme, onEdited:Void->Void, ?selection:BufferSelection) {
		this.document = document;
		this.theme = theme;
		this.onEdited = onEdited;
		this.selection = selection == null ? new BufferSelection() : selection;
	}

	function handleEdit(transaction:EditTransaction):Void {
		document.buffer.applyEditTransaction(selection, transaction);
		onEdited();
	}

	public function build(context:nativekit.ui.core.BuildContext):nativekit.ui.core.RenderNode {
		var gutter = new EditorGutter("gutter:" + document.id, document.buffer,
			theme.tokens.textSecondary, theme.tokens.surface);
		var editorStyle = new LayoutStyle();
		editorStyle.width = LayoutAxis.grow();
		editorStyle.height = LayoutAxis.fit();
		var area = TextArea.withDocument("editor:" + document.id, document.buffer.document,
			handleEdit, editorStyle, null, null, theme.tokens.textPrimary);
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
		scrollStyle.background = theme.tokens.surfaceSunken;
		return new ScrollView("editor-scroll:" + document.id, row, scrollStyle).build(context);
	}
}
