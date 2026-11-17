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
		var builds = harness.rootBuilds;
		press();
		harness.submit();
		var reuseMoved = focused();
		Report.check(2, "a deferred focus request with no requestFrame is NOT applied by the next (reuse) frame",
			!reuseMoved, "focus moved=" + reuseMoved + " rootBuilds+=" + (harness.rootBuilds - builds));
		builds = harness.rootBuilds;
		harness.submit();
		Report.info(2, "second idle frame after it: focus moved=" + focused() + " rootBuilds+=" + (harness.rootBuilds - builds));
		builds = harness.rootBuilds;
		harness.requestFrame();
		harness.submit();
		Report.check(2, "the request is kept: the next full build (an unrelated requestFrame) applies it late",
			focused(), "focus moved=" + focused() + " rootBuilds+=" + (harness.rootBuilds - builds));

		bumpTick = true;
		harness.ui.focusWidget(start);
		harness.submit();
		builds = harness.rootBuilds;
		press();
		harness.submit();
		Report.check(2, "requestFocusAfterLayout + requestFrame() in the handler moves focus in the next frame",
			focused(), "focus moved=" + focused() + " rootBuilds+=" + (harness.rootBuilds - builds));
		harness.dispose();
	}
}
