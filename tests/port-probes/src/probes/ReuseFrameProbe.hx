package probes;

import haxeon.reactive.Signal;
import haxeon.ui.FontCollection;
import haxeon.ui.component.BoundText;
import haxeon.ui.widgets.text.Text;

/**
	Open point 8 (trap T20): the FPS title. A reuse frame runs no build; does it still return the tree (so the host counts
	it as rendered)? A `BoundText` over a `Signal<String>` (plan D5): an equal
	write asks for nothing, a new value asks for a frame and rewrites the text without a root build.
**/
class ReuseFrameProbe {
	public static function run(fonts:FontCollection):Void {
		Report.guard(8, "reuse frame and BoundText", () -> probe(fonts));
	}

	static function probe(fonts:FontCollection):Void {
		var fps = new Signal<String>("");
		var harness = new Harness(fonts, function(_) return [new Text("title"), new BoundText("fps", function() return fps.value)]);
		var first = harness.submit();
		var builds = harness.rootBuilds;
		var again = harness.submit();
		Report.check(8, "an idle frame with the constant key is a reuse frame: no build, same tree returned",
			harness.rootBuilds == builds && again == first, "rootBuilds+=" + (harness.rootBuilds - builds) + " same tree="
			+ (again == first));

		var frames = harness.selfFrames;
		fps.value = "60 fps";
		Report.check(8, "a new label value asks the host for a frame by itself", harness.selfFrames > frames,
			"selfFrames+=" + (harness.selfFrames - frames));
		builds = harness.rootBuilds;
		var root = harness.submit();
		Report.check(8, "that frame rewrites the label without a root build",
			harness.rootBuilds == builds && Harness.hasText(root, "60 fps"),
			"rootBuilds+=" + (harness.rootBuilds - builds) + " shown=" + Harness.textStartingWith(root, "60"));

		frames = harness.selfFrames;
		fps.value = "60 fps";
		Report.check(8, "an equal label write asks for nothing (T20: keep the once-a-second scheduleFrame)",
			harness.selfFrames == frames, "selfFrames+=" + (harness.selfFrames - frames));
		builds = harness.rootBuilds;
		var before = harness.root;
		harness.scheduleFrame();
		root = harness.submit();
		Report.check(8, "a scheduleFrame() with nothing changed is a reuse frame", harness.rootBuilds == builds && root == before,
			"rootBuilds+=" + (harness.rootBuilds - builds));
		harness.dispose();
	}
}
