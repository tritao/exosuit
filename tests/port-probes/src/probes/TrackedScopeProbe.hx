package probes;

import haxeon.reactive.Signal;
import haxeon.ui.FontCollection;
import haxeon.ui.component.TrackedScope;
import haxeon.ui.core.View;
import haxeon.ui.widgets.text.Text;

/**
	Open point 6 (stage 2, F1-F3): does a full root build re-run a `TrackedScope` body, and does a write to a signal the
	body read schedule a frame by itself and re-run only the body (no root build)?
	Two shapes: a scope made in every root build (new instance and closure each time) and one made once.
**/
class TrackedScopeProbe {
	public static function run(fonts:FontCollection):Void {
		Report.guard(6, "scope made per build", () -> probe(fonts, false));
		Report.guard(6, "scope made once", () -> probe(fonts, true));
	}

	static function probe(fonts:FontCollection, stable:Bool):Void {
		var shape = stable ? "made once" : "per build";
		var source = new Signal<Int>(0);
		var bodyRuns = 0;
		var body = function():View {
			bodyRuns++;
			return new Text("scope:" + source.value);
		};
		var made = new TrackedScope("scope", body);
		var harness = new Harness(fonts, function(_) return [new Text("outside"), stable ? made : new TrackedScope("scope", body)]);
		var root = harness.submit();
		var runs = bodyRuns, builds = harness.rootBuilds;
		harness.requestFrame();
		root = harness.submit();
		Report.check(6, shape + ": a full root build re-runs the scope body", bodyRuns > runs,
			"bodyRuns+=" + (bodyRuns - runs) + " rootBuilds+=" + (harness.rootBuilds - builds));

		runs = bodyRuns;
		builds = harness.rootBuilds;
		var frames = harness.selfFrames;
		source.value = source.value + 1;
		var asked = harness.selfFrames - frames;
		Report.check(6, shape + ": a write to a signal the body read asks the host for a frame by itself", asked > 0,
			"selfFrames+=" + asked);
		root = harness.submit();
		Report.check(6, shape + ": that frame re-runs only the body (no root build) and shows the new value",
			bodyRuns == runs + 1 && harness.rootBuilds == builds && Harness.hasText(root, "scope:" + source.value),
			"bodyRuns+=" + (bodyRuns - runs) + " rootBuilds+=" + (harness.rootBuilds - builds) + " shown="
			+ Harness.textStartingWith(root, "scope:"));

		runs = bodyRuns;
		builds = harness.rootBuilds;
		root = harness.submit();
		Report.check(6, shape + ": an idle frame after it runs nothing", bodyRuns == runs && harness.rootBuilds == builds,
			"bodyRuns+=" + (bodyRuns - runs) + " rootBuilds+=" + (harness.rootBuilds - builds));
		harness.dispose();
	}
}
