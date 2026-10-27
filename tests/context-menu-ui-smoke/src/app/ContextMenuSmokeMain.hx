package app;

import haxeon.ui.LayoutFrame;
import haxeon.ui.core.RenderNode;
import haxeon.ui.host.DesktopUiHost;
import haxeon.ui.host.DesktopUiHostOptions;
import haxeon.ui.semantics.AccessibilityRole;
import ui.ExosuitApp;

/** Report native input results without injecting events through UiContext. */
@:access(ui.ExosuitApp)
@:access(ui.CommandMenu)
class ContextMenuSmokeApp extends ExosuitApp {
	final report:String;
	var pointerUps = 0;
	var observedRoot:Null<RenderNode> = null;
	public function new(context:haxeon.ui.host.UiHostContext, directory:String) {
		super(context.fonts, ui.ExosuitPalette.theme(false), context, directory + "/Main.hx", null, null, false);
		report = directory + "/state.json";
	}
	override public function submit(frame:LayoutFrame):RenderNode {
		var root = super.submit(frame);
		if (root != observedRoot) {
			observedRoot = root;
			root.on(haxeon.ui.core.UiEventKind.PointerUp, function(_) { pointerUps++; requestFrame(); }, "capture");
		}
		// Exercise the workbench custom-action entry point with the same native
		// editor input target, without depending on a running workspace agent.
		if (sys.FileSystem.exists(haxe.io.Path.directory(report) + "/workbench-menu")) {
			for (pane in editorPanes) pane.onContextMenu = function(event) {
				showWorkbenchMenu([new haxeon.ui.widgets.overlays.MenuItem("smoke-action", "Smoke action", function() {})],
					event, function() return true);
			};
		}
		var nodes:Array<Dynamic> = [];
		root.walk(function(node) {
			if (node.resolved == null) return;
			var isItem = node.semantics != null && node.semantics.role == AccessibilityRole.MenuItem;
			if ((node.styleKey != null && StringTools.startsWith(node.styleKey, "activity:")) ||
				node.styleKey == "activity-manage" || node.styleKey == "layout-menu" || isItem ||
				(node.semantics != null && node.semantics.role == AccessibilityRole.TextField)) {
				var bounds = node.globalBounds();
				nodes.push({key: node.styleKey, label: node.semantics == null ? "" : node.semantics.label,
					menuItem: isItem, enabled: node.enabled, id: node.id.value,
					x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height});
			}
		});
		var focused = ui.focus.focusedNode();
		sys.io.File.saveContent(report, haxe.Json.stringify({menuOpen: contextMenu != null,
			activityId: sidebar.activeId, sidebarVisible: sidebar.visible, pointerUps: pointerUps,
			anchor: contextMenu == null ? null : {x: contextMenu.x, y: contextMenu.y},
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
		options.captureSeconds = 35;
		return DesktopUiHost.run(options, function(context) return new ContextMenuSmokeApp(context, Sys.args()[0]));
	}
}
