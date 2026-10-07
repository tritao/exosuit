package ui;

import haxeon.ui.Insets;
import haxeon.ui.Color;
import haxeon.ui.FontFamily;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutStyle;
import haxeon.ui.TextWrap;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.theme.Theme;
import haxeon.ui.TextStyle;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.text.MiddleEllipsisText;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextArea;
import style.Theme as EditorTheme;

/** Selectable, copyable text surface with all edits disabled by UIKit. */
class WorkspaceFilePreviewView implements View {
	final file:UiWorkspaceFileTab;
	final theme:Theme;
	final editorTheme:EditorTheme;
	final refresh:Void->Void;

	public function new(file:UiWorkspaceFileTab, theme:Theme, editorTheme:EditorTheme, refresh:Void->Void) {
		this.file = file;
		this.theme = theme;
		this.editorTheme = editorTheme;
		this.refresh = refresh;
	}

	public function build(context:haxeon.ui.core.BuildContext):haxeon.ui.core.RenderNode {
		var outer = new LayoutStyle();
		outer.width = LayoutAxis.grow();
		outer.height = LayoutAxis.grow();
		outer.direction = LayoutDirection.TopToBottom;
		var headerStyle = new LayoutStyle();
		headerStyle.width = LayoutAxis.grow();
		headerStyle.padding = new Insets(8.0, 7.0, 8.0, 7.0);
		headerStyle.direction = LayoutDirection.LeftToRight;
		headerStyle.childAlignY = LayoutAlignmentY.Center;
		headerStyle.childGap = 8.0;
		var bodyStyle = new LayoutStyle();
		bodyStyle.width = LayoutAxis.grow();
		bodyStyle.height = LayoutAxis.grow();
		bodyStyle.background = Color.fromBytes((editorTheme.editorBackground >>> 24) & 255,
			(editorTheme.editorBackground >>> 16) & 255, (editorTheme.editorBackground >>> 8) & 255,
			editorTheme.editorBackground & 255);
		var label = file.rootName + " / " + file.path + "  ·  Read-only";
		file.textModel.updateTheme(editorTheme);
		var contents = TextArea.withDocument("workspace-preview:" + file.id + ":" + file.revision,
			file.textModel.document(), null, bodyStyle, "Read-only workspace file",
			new TextStyle(15.0, FontFamily.Monospace), Color.fromBytes((editorTheme.editorForeground >>> 24) & 255,
				(editorTheme.editorForeground >>> 16) & 255, (editorTheme.editorForeground >>> 8) & 255,
				editorTheme.editorForeground & 255));
		contents.readOnly = true;
		contents.colorRangeProvider = file.textModel.foregroundProvider;
		contents.presentationRevision = file.textModel.presentationRevision;
		var refreshButton = new Button(file.refreshing ? "Refreshing…" : "Refresh", null, refresh,
			"workspace-file-refresh:" + file.id);
		refreshButton.enabled = !file.refreshing;
		refreshButton.accessibilityLabel = "Refresh saved workspace file";
		var rows:Array<KeyedView> = [
			new KeyedView("header", new Row("workspace-file-header:" + file.id, [
				new KeyedView("path", new MiddleEllipsisText("path-label", label, false,
					new TextStyleOverride(null, 12.0, null, TextWrap.None, null, null, null, theme.tokens.textSecondary))),
				new KeyedView("refresh", refreshButton)
			], headerStyle))
		];
		if (file.refreshError != null) {
			var errorStyle = new LayoutStyle();
			errorStyle.width = LayoutAxis.grow();
			errorStyle.padding = new Insets(4.0, 8.0, 4.0, 8.0);
			rows.push(new KeyedView("refresh-error", new Text(file.refreshError, errorStyle, theme.tokens.danger,
				TextStyleOverride.text(12.0))));
		}
		rows.push(new KeyedView("contents", contents));
		return new Column("workspace-file-preview:" + file.id, rows, outer).build(context);
	}
}
