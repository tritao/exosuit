package probes;

import haxeon.reactive.ReactiveRuntime;
import haxeon.reactive.Signal;
import haxeon.ui.FontCollection;
import haxeon.ui.core.State;
import haxeon.ui.widgets.text.Text;

/**
	Open point 5 (trap T3): a tracked write during the root build. What does `submitCached` do, and can the context
	submit again afterwards? (What `DesktopUiHost` then does with the error is answered from code in C-probe-results.md.)
	Also trap T5: a write wrapped in `withoutTracking` after a read of the same source in the same build.
**/
class BuildWriteProbe {
	public static function run(fonts:FontCollection):Void {
		Report.guard(5, "build-time writes", () -> probe(fonts));
		Report.guard(5, "withoutTracking after a read", () -> lateWrite(fonts));
	}

	static function probe(fonts:FontCollection):Void {
		var shown = new Signal<Int>(0);
		var unread = new Signal<Int>(0);
		var held = new ProbeObservable();
		var mode = "";
		var harness:Harness = null;
		harness = new Harness(fonts, function(context) {
			var value = shown.value;
			switch (mode) {
				case "read-signal":
					shown.value = value + 1;
				case "unread-signal":
					unread.value = unread.value + 1;
				case "state":
					var local:State<Int> = context.state(context.id("local"), 0);
					local.update(local.value + 1);
				case "fresh-signal":
					var fresh = new Signal<Int>(0);
					fresh.value = 1;
				case "fresh-observable":
					var fresh = new ProbeObservable();
					fresh.count = 1;
				case "held-observable":
					held.count = held.count + 1;
				case _:
			}
			return [new Text("shown:" + shown.value)];
		});
		harness.submit();
		for (variant in ["read-signal", "unread-signal", "state", "fresh-signal", "held-observable", "fresh-observable"]) {
			mode = variant;
			harness.requestFrame();
			var error:Null<String> = null;
			try harness.submit() catch (e:Dynamic) error = Std.string(e);
			var expectThrow = variant != "fresh-observable";
			Report.check(5, "a build-time write to " + variant + (expectThrow ? " throws out of submitCached" : " is allowed"),
				(error != null) == expectThrow, error == null ? "no throw" : "threw: " + error);
			mode = "";
			harness.requestFrame();
			var recovered:Null<String> = null;
			try {
				var root = harness.submit();
				recovered = Harness.textStartingWith(root, "shown:");
			} catch (e:Dynamic) recovered = "threw again: " + Std.string(e);
			Report.check(5, "after the " + variant + " throw, the context builds the next frame normally",
				recovered == "shown:" + shown.value, "next frame shows " + recovered + " (signal=" + shown.value + ")");
		}
		harness.dispose();
	}

	static function lateWrite(fonts:FontCollection):Void {
		var source = new Signal<Int>(0);
		var bump = false;
		var harness = new Harness(fonts, function(_) {
			var seen = source.value;
			if (bump) {
				bump = false;
				ReactiveRuntime.withoutTracking(function():Int return source.value = seen + 1);
			}
			return [new Text("seen:" + seen)];
		});
		harness.submit();
		bump = true;
		harness.requestFrame();
		var root = harness.submit();
		var builds = harness.rootBuilds;
		root = harness.submit();
		var shown = Harness.textStartingWith(root, "seen:");
		Report.check(5, "T5: a withoutTracking write after a read in the same build is lost (the next frame reuses)",
			shown == "seen:0" && source.value == 1,
			"shown=" + shown + " source=" + source.value + " rootBuilds+=" + (harness.rootBuilds - builds));
		harness.dispose();
	}
}

/** An Observable made inside a build may be written in that build (its creation is logged); one made before may not. */
private class ProbeObservable implements Observable {
	public var count:Int = 0;

	public function new() {}
}
