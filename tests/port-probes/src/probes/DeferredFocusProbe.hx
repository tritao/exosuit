package probes;

import haxeon.ui.FontCollection;
import haxeon.ui.core.Command;
import haxeon.ui.core.Shortcut;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.WidgetId;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.text.TextField;

/**
	Open point 2 (trap T10): `requestFocusAfterLayout` made from a handler (a command run by its shortcut, as in
	ExosuitApp's `focusEditor` and TerminalTabs), then the next frame. Does focus move on a reuse frame? With a full build?
**/
class DeferredFocusProbe {
	public static function run(fonts:FontCollection):Void {
		Report.guard(2, "deferred focus", () -> probe(fonts));
	}

	static function probe(fonts:FontCollection):Void {
		var bumpTick = false;
		var target:Null<WidgetId> = null;
		var harness:Harness = null;
		harness = new Harness(fonts, function(_) return [
			new Button("Start", null, function() {}, "start"),
			new TextField("target", "", null, null, "Target")
		]);
		harness.ui.commands.register(new Command("probe.focus-target", "Focus target", function() {
			harness.ui.buildContext.requestFocusAfterLayout(target);
			if (bumpTick) harness.requestFrame();
		}, new Shortcut(UiKey.F6)));
		var root = harness.submit();
		var start = Harness.first(root, AccessibilityRole.Button, "Start").id;
		target = Harness.first(root, AccessibilityRole.TextField).id;
		var focused = function() return Harness.sameId(harness.ui.focus.focusedId, target);
		var press = function() {
			harness.ui.key(UiEventKind.KeyDown, UiKey.F6);
			harness.ui.key(UiEventKind.KeyUp, UiKey.F6);
		};

		harness.ui.focusWidget(start);
		harness.submit();
		harness.submit();
		var builds = harness.rootBuilds;
		press();
		harness.submit();
		Report.check(2, "from a shortcut handler with no requestFrame, focus does NOT move in the next (reuse) frame",
			!focused(), "focus moved=" + focused() + " rootBuilds+=" + (harness.rootBuilds - builds));
		harness.requestFrame();
		harness.submit();

		harness.ui.focusWidget(start);
		harness.submit();
		var steady = harness.submit();
		var idle = harness.submit();
		Report.info(2, "steady frames before the callback request reuse the tree: " + (steady == idle));
		builds = harness.rootBuilds;
		harness.ui.buildContext.requestFocusAfterLayout(target);
		harness.scheduleFrame();
		var after = harness.submit();
		var moved = focused();
		Report.info(2, "the frame after the callback request returned the same tree object: " + (after == idle));
		Report.check(2, "from code outside any input event (a callback), with only a host frame, focus does NOT move (reuse frame)",
			!moved, "focus moved=" + moved + " rootBuilds+=" + (harness.rootBuilds - builds));
		builds = harness.rootBuilds;
		harness.requestFrame();
		harness.submit();
		Report.check(2, "...the request is kept and the next full build applies it", focused(),
			"focus moved=" + focused() + " rootBuilds+=" + (harness.rootBuilds - builds));

		harness.ui.focusWidget(start);
		harness.submit();
		builds = harness.rootBuilds;
		harness.ui.buildContext.requestFocusAfterLayout(target);
		harness.requestFrame();
		harness.submit();
		Report.check(2, "from a callback, requestFocusAfterLayout + requestFrame() moves focus in the next frame", focused(),
			"focus moved=" + focused() + " rootBuilds+=" + (harness.rootBuilds - builds));

		bumpTick = true;
		harness.ui.focusWidget(start);
		harness.submit();
		builds = harness.rootBuilds;
		press();
		harness.submit();
		Report.check(2, "from a shortcut handler, requestFocusAfterLayout + requestFrame() moves focus in the next frame",
			focused(), "focus moved=" + focused() + " rootBuilds+=" + (harness.rootBuilds - builds));
		harness.dispose();
	}
}
