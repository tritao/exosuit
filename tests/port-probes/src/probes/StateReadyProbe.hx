package probes;

import haxeon.reactive.ReactiveRuntime;
import haxeon.reactive.Signal;
import haxeon.ui.FontCollection;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.widgets.collections.TreeView;

/**
	Open point 4 (mapping row 22): when does `TreeView.onStateReady` fire, and may it call `select` / `scrollIntoView`
	(ExplorerPanelController's rename flow) and write tracked state? The explorer makes its tree in every build, so the
	selection must also survive into the next build's new `TreeView` instance.
**/
class StateReadyProbe {
	public static function run(fonts:FontCollection):Void {
		Report.guard(4, "onStateReady", () -> probe(fonts));
	}

	static function probe(fonts:FontCollection):Void {
		var model = new ProbeTreeModel();
		var pending:Null<String> = null;
		var written = new Signal<Int>(0);
		var calls = 0, trackingSeen = false, threw:Null<String> = null, buildsAtCall = -1;
		var tree:Null<TreeView> = null;
		var harness:Harness = null;
		harness = new Harness(fonts, function(_) {
			var style = new LayoutStyle();
			style.width = LayoutAxis.fixed(320);
			style.height = LayoutAxis.fixed(240);
			var made = new TreeView("tree", model, style, null, 240.0, null, ["root", "group"]);
			made.onStateReady = function(current) {
				calls++;
				buildsAtCall = harness.rootBuilds;
				if (ReactiveRuntime.isTracking()) trackingSeen = true;
				var path = pending;
				if (path == null) return;
				try {
					for (index in 0...model.childCount("group")) if (model.childKeyAt("group", index) == path) {
						current.select(path);
						current.scrollIntoView(path);
						written.value = written.value + 1;
						pending = null;
						break;
					}
				} catch (error:Dynamic) threw = Std.string(error);
			};
			tree = made;
			return [made];
		});
		harness.submit();
		Report.check(4, "onStateReady runs on a full build, after the build, outside tracking",
			calls == 1 && !trackingSeen, "calls=" + calls + " tracking=" + trackingSeen);
		var before = calls;
		harness.submit();
		Report.check(4, "a reuse frame does not run onStateReady", calls == before, "calls+=" + (calls - before));

		pending = "b";
		harness.requestFrame();
		var builds = harness.rootBuilds;
		harness.submit();
		Report.check(4, "select + scrollIntoView + a tracked write in onStateReady do not throw", threw == null,
			threw == null ? "no throw" : threw);
		Report.check(4, "the selection is applied in the same submit (build feedback re-runs the root build)",
			tree.isSelected("b") && pending == null,
			"selected b=" + tree.isSelected("b") + " rootBuilds+=" + (harness.rootBuilds - builds) + " onStateReady calls="
			+ calls);
		harness.requestFrame();
		harness.submit();
		Report.check(4, "the selection survives into the next build's new TreeView instance", tree.isSelected("b"),
			"selected b=" + tree.isSelected("b"));
		Report.info(4, "the tracked write from onStateReady: written=" + written.value + " (the root did not read it)");
		harness.dispose();
	}
}
