package probes;

import haxeon.ui.FontCollection;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextField;

/**
	Open point 1 (trap T1 with D1): a `TextField` whose `onChange` stores the text in a plain field and calls
	`requestFrame()`; a sibling `Text` shows that field. Is the sibling rebuilt in the frame after the keystroke?
**/
class TextFieldTickProbe {
	public static function run(fonts:FontCollection):Void {
		Report.guard(1, "tick", () -> withTick(fonts));
		Report.guard(1, "string key", () -> withStringKey(fonts));
	}

	/** The port's loop: constant key, `requestFrame()` bumps `frameTick`. */
	static function withTick(fonts:FontCollection):Void {
		var text = "";
		var harness:Harness = null;
		harness = new Harness(fonts, function(_) return [
			new TextField("field", text, function(value) {
				text = value;
				harness.requestFrame();
			}, null, "Query"),
			new Text("echo:" + text)
		]);
		var root = harness.submit();
		harness.ui.focusWidget(Harness.first(root, AccessibilityRole.TextField).id);
		root = harness.submit();
		var builds = harness.rootBuilds;
		harness.ui.text(UiEventKind.TextInput, "a");
		root = harness.submit();
		Report.check(1, "with the tick, the sibling shows the typed text in the next frame",
			Harness.hasText(root, "echo:a"), "sibling=" + Harness.textStartingWith(root, "echo:") + " rootBuilds+="
			+ (harness.rootBuilds - builds));
		harness.ui.text(UiEventKind.TextInput, "b");
		root = harness.submit();
		Report.check(1, "a second keystroke updates the sibling too", Harness.hasText(root, "echo:ab"),
			"sibling=" + Harness.textStartingWith(root, "echo:"));
		harness.dispose();
	}

	/**
		The pre-port loop (control): no tick, the key carries a revision that `onChange` bumps. This is trap T1 itself; the
		check states what upstream does, so the port knows why the tick is needed.
	**/
	static function withStringKey(fonts:FontCollection):Void {
		var text = "";
		var revision = 0;
		var harness = new Harness(fonts, function(_) return [
			new TextField("field", text, function(value) {
				text = value;
				revision++;
			}, null, "Query"),
			new Text("echo:" + text)
		]);
		var root = harness.submitKeyed("k" + revision);
		harness.ui.focusWidget(Harness.first(root, AccessibilityRole.TextField).id);
		root = harness.submitKeyed("k" + revision);
		var builds = harness.rootBuilds;
		harness.ui.text(UiEventKind.TextInput, "a");
		root = harness.submitKeyed("k" + revision);
		var shown = Harness.textStartingWith(root, "echo:");
		Report.check(1, "a changed key alone does NOT rebuild while the field's patch is pending (T1 holds upstream)",
			shown == "echo:", "sibling=" + shown + " rootBuilds+=" + (harness.rootBuilds - builds));
		root = harness.submitKeyed("k" + revision);
		shown = Harness.textStartingWith(root, "echo:");
		Report.info(1, "string key, following idle frame with the same key: sibling=" + shown);
		harness.dispose();
	}
}
