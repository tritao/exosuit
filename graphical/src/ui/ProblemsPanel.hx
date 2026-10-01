package ui;

import Color;
import Insets;
import LayoutAxis;
import LayoutStyle;
import feedback.Problem;
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
 * The dock's "Problems" panel, rebuilt fresh from `UiWorkbenchHost.getProblems()`
 * every frame - so anything that publishes into that registry (the build
 * controller, the language controller, a plugin) shows up here without this
 * panel needing to know who published it. Activating a row goes through
 * `WorkbenchController`'s registered handler (`UiWorkbenchHost.activateProblem`),
 * which opens the document and selects the reported range.
 */
class ProblemsPanel implements View {
	final host:UiWorkbenchHost;

	public function new(host:UiWorkbenchHost) {
		this.host = host;
	}

	public function build(context:BuildContext):RenderNode {
		var values = host.getProblems().values();
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.grow();
		if (values.length == 0) {
			style.padding = new Insets(16.0, 16.0, 16.0, 16.0);
			return new Text("No problems reported.", style, Color.rgba(0.6, 0.6, 0.65, 1.0), TextStyleOverride.text(13.0)).build(context);
		}
		var rows:Array<KeyedView> = [];
		for (index in 0...values.length)
			rows.push(new KeyedView("problem" + index, buildRow(values[index], index)));
		var listStyle = new LayoutStyle();
		listStyle.width = LayoutAxis.grow();
		var list = new Column("problems-list", rows, listStyle);
		return new ScrollView("problems-scroll", list, style).build(context);
	}

	function buildRow(problem:Problem, index:Int):View {
		var location = problem.path + ":" + (problem.line + 1) + ":" + (problem.column + 1);
		var button = new Button(location + "  " + problem.message, null, function() host.activateProblem(problem), "problem" + index);
		button.variant = ButtonVariant.Secondary;
		return button;
	}
}
