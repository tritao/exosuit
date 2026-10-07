package ui;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.theme.Theme;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextArea;

/** Selectable, copyable text surface with all edits disabled by UIKit. */
class WorkspaceFilePreviewView implements View {
	final file:UiWorkspaceFileTab;
	final theme:Theme;

	public function new(file:UiWorkspaceFileTab, theme:Theme) {
		this.file = file;
		this.theme = theme;
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
		var label = file.rootName + " / " + file.path + "  ·  Read-only";
		var contents = new haxeon.ui.widgets.text.TextArea("workspace-preview:" + file.id + ":" + file.revision,
			file.contents, null, bodyStyle, "Read-only workspace file", null, theme.tokens.text);
		contents.readOnly = true;
		return new Column("workspace-file-preview:" + file.id, [
			new KeyedView("path", new Text(label, headerStyle, theme.tokens.textSecondary,
				TextStyleOverride.text(12.0))),
			new KeyedView("contents", contents)
		], outer).build(context);
	}
}
