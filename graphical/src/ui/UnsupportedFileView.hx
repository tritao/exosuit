package ui;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextArea;

/** Explains an unsupported text file and offers bounded, read-only byte inspection. */
class UnsupportedFileView implements View {
	final tab:UiUnsupportedFileTab;
	final changed:Void->Void;
	public function new(tab:UiUnsupportedFileTab, changed:Void->Void) {
		this.tab = tab; this.changed = changed;
	}
	public function build(context:BuildContext):RenderNode {
		var outer = new LayoutStyle();
		outer.width = LayoutAxis.grow(); outer.height = LayoutAxis.grow();
		outer.background = context.theme.tokens.surface;
		outer.padding = new haxeon.ui.Insets(24, 24, 24, 24);
		if (tab.showBytes) {
			var style = new LayoutStyle();
			style.width = LayoutAxis.stretch(); style.height = LayoutAxis.grow();
			var text = new TextArea(tab.id + ":bytes", tab.file.bytePreview, null, style,
				"Read-only file bytes", new haxeon.ui.TextStyle(14, haxeon.ui.FontFamily.Monospace));
			text.readOnly = true;
			return new Column(tab.id, [
				new KeyedView("info", new Text("Read-only byte preview · " + tab.file.previewBytes + " of " + tab.file.sizeBytes + " bytes")),
				new KeyedView("bytes", text)
			], outer).build(context);
		}
		outer.childDistribution = haxeon.ui.LayoutDistribution.Center;
		outer.childAlignX = haxeon.ui.LayoutAlignmentX.Center;
		outer.childGap = 16;
		var message = new LayoutStyle(); message.width = LayoutAxis.grow(0, 560);
		return new Column(tab.id, [
			new KeyedView("warning", new haxeon.ui.widgets.Icon("unsupported-file", haxeon.ui.icons.IconName.AlertTriangle,
				42, haxeon.ui.Color.fromBytes(185, 135, 0))),
			new KeyedView("message", new Text(tab.file.toString() + " It cannot be displayed in the text editor.", message)),
			new KeyedView("inspect", new Button("View Bytes", null, function() { tab.showBytes = true; changed(); }))
		], outer).build(context);
	}
}
