package app;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.widgets.controls.TabItem;
import haxeon.ui.widgets.controls.Tabs;
import haxeon.ui.widgets.controls.TabsSelectionMode;
import haxeon.ui.widgets.text.Text;

class NarrowTabsTestMain {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }
	static function header(root:RenderNode, label:String):RenderNode {
		var found:RenderNode = null;
		root.walk(function(node) {
			if (node.semantics != null && node.semantics.role == AccessibilityRole.Tab && node.semantics.label == label) found = node;
		});
		require(found != null, "missing tab " + label);
		return found;
	}
	static function main():Int {
		var fonts = haxeon.ui.FontCollection.create();
		fonts.add("../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
		for (dark in [false, true]) {
			var session = haxeon.ui.LayoutSession.create();
			var context = new UiContext(session, fonts, ui.ExosuitPalette.theme(dark));
			var labels = ["Terminal 1", "Terminal 2", "Terminal 3", "Terminal with a very long descriptive session title"];
			var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.height = LayoutAxis.grow();
			var tabs = new Tabs("terminal-sessions", [for (label in labels) new TabItem(label, label, new Text("page: " + label))],
				labels[0], null, style, null, null, null, null, TabsSelectionMode.Controlled);
			tabs.headerRevision = function() return "stable";
			for (width in [180.0, 120.0, 700.0, 90.0, 320.0]) for (label in labels) {
				tabs.selectedKey = label;
				var root = context.submit(tabs, new LayoutFrame(width, 200));
				var previousRight:Float = -1e9;
				for (name in labels) {
					var tab = header(root, name);
					var bounds = tab.globalBounds();
					require(bounds.x >= previousRight - 0.1, "adjacent terminal headers overlap at " + width);
					previousRight = bounds.x + bounds.width;
					var geometry:haxeon.ui.ResolvedLayoutItem = cast tab.resolved;
					var clip = geometry.clipBounds;
					require(clip.x >= -0.1 && clip.x + clip.width <= width + 0.1, "tab paint escaped viewport");
					var text:RenderNode = null;
					tab.walk(function(node) { if (node.layout.text == name) text = node; });
					require(text != null && text.globalBounds().width <= bounds.width, "label overflowed its own header");
					if (name == label) require(bounds.x >= -0.1 && bounds.x + Math.min(bounds.width, width) <= width + 0.1,
						"selected tab not revealed at " + width + ": " + label + " x=" + bounds.x);
				}
			}
			tabs.selectedKey = labels[0];
			var frame = new LayoutFrame(180, 200);
			var root = context.submit(tabs, frame);
			var first = header(root, labels[0]);
			require(context.focusWidget(first.id), "could not focus tab");
			context.key(UiEventKind.KeyDown, UiKey.Right);
			root = context.submit(tabs, frame);
			require(tabs.selectedKey == labels[1] && header(root, labels[1]).globalBounds().x >= 0, "keyboard selection did not reveal next tab");
			var before = header(root, labels[0]).globalBounds().x;
			context.scroll(20, 10, 0, 80);
			root = context.submit(tabs, frame);
			require(header(root, labels[0]).globalBounds().x < before, "vertical mouse wheel did not scroll tab rail");
			var after = header(root, labels[0]).globalBounds().x;
			root = context.submit(tabs, frame);
			require(header(root, labels[0]).globalBounds().x == after, "layout snapped back after manual scroll");
			var third = header(root, labels[2]).globalBounds();
			var clickX = Math.min(179, third.x + third.width / 2);
			context.pointerDown(clickX, third.y + third.height / 2, 0);
			context.pointerUp(clickX, third.y + third.height / 2, 0);
			root = context.submit(tabs, frame);
			require(tabs.selectedKey == labels[2], "pointer hit testing did not follow the scrolled tab");
			context.dispose();
		}
		fonts.dispose();
		trace("PASS: narrow terminal tabs retain label widths, clip, reveal selection, resize, and scroll in both themes");
		return 0;
	}
}
