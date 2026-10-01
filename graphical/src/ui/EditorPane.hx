package ui;

import Color;
import TextColorRange;
import editor.SyntaxPresentation;
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
 * layout's codepoint ranges. Multi-cursor editing remains a follow-on.
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

	public function new(document:Document, theme:Theme, onEdited:Void->Void, ?selection:BufferSelection, ?editorTheme:style.Theme) {
		this.document = document;
		this.onEdited = onEdited;
		this.editorTheme = editorTheme == null ? new style.Theme() : editorTheme;
		this.selection = selection == null ? new BufferSelection() : selection;
	}

	static function color(value:Int):Color {
		return Color.fromBytes((value >>> 24) & 255, (value >>> 16) & 255,
			(value >>> 8) & 255, value & 255);
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
		area.colorRangeProvider = function(start, end) {
			return [for (range in SyntaxPresentation.foreground(document, editorTheme, start, end))
				new TextColorRange(range.start, range.end, color(range.color))];
		};
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
