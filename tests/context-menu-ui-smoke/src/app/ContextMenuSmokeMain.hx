package app;

import haxeon.ui.LayoutFrame;
import haxeon.ui.core.RenderNode;
import haxeon.ui.host.DesktopUiHost;
import haxeon.ui.host.DesktopUiHostOptions;
import haxeon.ui.semantics.AccessibilityRole;
import ui.ExosuitApp;

/** Report native input results without injecting events through UiContext. */
@:access(ui.ExosuitApp)
class ContextMenuSmokeApp extends ExosuitApp {
	final report:String;
	public function new(context:haxeon.ui.host.UiHostContext, directory:String) {
		super(context.fonts, ui.ExosuitPalette.theme(false), context, directory + "/Main.hx", null, null, false);
		report = directory + "/state.json";
	}
	override public function submit(frame:LayoutFrame):RenderNode {
		var root = super.submit(frame);
		var nodes:Array<Dynamic> = [];
		root.walk(function(node) {
			if (node.resolved == null) return;
			var isItem = node.semantics != null && node.semantics.role == AccessibilityRole.MenuItem;
			if (node.styleKey == "activity-manage" || isItem ||
				(node.semantics != null && node.semantics.role == AccessibilityRole.TextField)) {
				var bounds = node.globalBounds();
				nodes.push({key: node.styleKey, label: node.semantics == null ? "" : node.semantics.label,
					menuItem: isItem, enabled: node.enabled, id: node.id.value,
					x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height});
			}
		});
		var focused = ui.focus.focusedNode();
		sys.io.File.saveContent(report, haxe.Json.stringify({menuOpen: contextMenu != null,
			focus: focused == null ? -1 : focused.id.value,
			focusLabel: focused == null || focused.semantics == null ? "" : focused.semantics.label,
			nodes: nodes}));
		return root;
	}
}

class ContextMenuSmokeMain {
	static function main():Int {
		var options = new DesktopUiHostOptions();
		options.title = "Context menu native input smoke";
		options.width = 1100; options.height = 760;
		options.captureDirectory = Sys.args()[0] + "/capture";
		options.captureSeconds = 20;
		return DesktopUiHost.run(options, function(context) return new ContextMenuSmokeApp(context, Sys.args()[0]));
	}
}
