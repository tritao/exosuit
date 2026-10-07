package ui;

import haxeon.ui.Insets;
import haxeon.ui.Color;
import haxeon.ui.FontFamily;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.theme.Theme;
import haxeon.ui.TextStyle;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextArea;
import style.Theme as EditorTheme;

/** Selectable, copyable text surface with all edits disabled by UIKit. */
class WorkspaceFilePreviewView implements View {
	final file:UiWorkspaceFileTab;
	final theme:Theme;
	final editorTheme:EditorTheme;

	public function new(file:UiWorkspaceFileTab, theme:Theme, editorTheme:EditorTheme) {
		this.file = file;
		this.theme = theme;
		this.editorTheme = editorTheme;
	}

	public function build(context:haxeon.ui.core.BuildContext):haxeon.ui.core.RenderNode {
		var outer = new LayoutStyle();
		outer.width = LayoutAxis.grow();
		outer.height = LayoutAxis.grow();
		outer.direction = LayoutDirection.TopToBottom;
		var headerStyle = new LayoutStyle();
		headerStyle.width = LayoutAxis.grow();
		headerStyle.padding = new Insets(12.0, 7.0, 12.0, 7.0);
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
		return new Column("workspace-file-preview:" + file.id, [
			new KeyedView("path", new Text(label, headerStyle, theme.tokens.textSecondary,
				TextStyleOverride.text(12.0))),
			new KeyedView("contents", contents)
		], outer).build(context);
	}
}
