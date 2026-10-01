package ui;

import Color;
import Insets;
import LayoutAxis;
import LayoutStyle;
import build.BuildOutputLine;
import nativekit.ui.core.BuildContext;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.TextStyleOverride;
import nativekit.ui.core.View;
import nativekit.ui.widgets.KeyedView;
import nativekit.ui.widgets.controls.Button;
import nativekit.ui.widgets.controls.ButtonVariant;
import nativekit.ui.widgets.layout.Column;
import nativekit.ui.widgets.scroll.ScrollView;
import nativekit.ui.widgets.text.Text;

/**
 * The dock's "Build Output" panel, rebuilt fresh from
 * `UiWorkbenchHost.currentBuildOutput` every frame while `BuildController`
 * drains its running process (see `BuildController.update`), so output
 * streams in live. A line `BuildOutput.append` recognized as a diagnostic
 * (`path:line[:column]: ...`) is clickable and opens/navigates to it through
 * `UiWorkbenchHost.activateBuildDiagnostic`; other lines are plain text.
 */
class BuildOutputPanel implements View {
	final host:UiWorkbenchHost;

	public function new(host:UiWorkbenchHost) {
		this.host = host;
	}

	public function build(context:BuildContext):RenderNode {
		var output = host.currentBuildOutput;
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.grow();
		if (output == null || output.lines.length == 0) {
			style.padding = new Insets(16.0, 16.0, 16.0, 16.0);
			return new Text("No build has run. Use \"Run Task\" from the command palette.", style,
				context.theme.tokens.textSecondary, TextStyleOverride.text(13.0)).build(context);
		}
		var rows:Array<KeyedView> = [];
		for (index in 0...output.lines.length)
			rows.push(new KeyedView("line" + index,
				buildRow(output.lines[index], index, context.theme.tokens.textPrimary)));
		var listStyle = new LayoutStyle();
		listStyle.width = LayoutAxis.grow();
		var list = new Column("build-output-list", rows, listStyle);
		return new ScrollView("build-output-scroll", list, style).build(context);
	}

	function buildRow(line:BuildOutputLine, index:Int, foreground:Color):View {
		var diagnostic = line.diagnostic;
		if (diagnostic == null) {
			var style = new LayoutStyle();
			style.width = LayoutAxis.grow();
			return new Text(line.text, style, foreground, TextStyleOverride.text(12.0));
		}
		var button = new Button(line.text, null, function() host.activateBuildDiagnostic(diagnostic), "build-line" + index);
		button.variant = ButtonVariant.Secondary;
		return button;
	}
}
