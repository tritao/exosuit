package probes;

import haxeon.ui.FontCollection;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.style.StyleState;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.sidebar.SidebarHost;
import haxeon.ui.widgets.sidebar.SidebarModel;
import haxeon.ui.widgets.sidebar.SidebarModeOptions;
import haxeon.ui.widgets.text.Text;

/**
	Open point 7 (trap T19): ExosuitApp's explorer `SidebarHost.headerActionsVisible` reads the pane node's interaction
	states and `ui.focus.focusedId` as plain values in the build. Does a hover or a focus change alone cause a root build,
	and do the header actions appear and disappear?
**/
class InteractionProbe {
	public static function run(fonts:FontCollection):Void {
		Report.guard(7, "sidebar header actions", () -> probe(fonts));
	}

	static function probe(fonts:FontCollection):Void {
		var sidebar = new SidebarModel();
		sidebar.register("files", function() return new Button("Inside", null, function() {}, "inside"),
			new SidebarModeOptions("Files"));
		var harness:Harness = null;
		harness = new Harness(fonts, function(_:haxeon.ui.core.BuildContext):Array<View> {
			var view = new SidebarHost("sidebar-modes", sidebar, function(_:String):Void {}, null, true);
			view.headerActions = function(_:String):Null<View> return new Text("ACTIONS");
			view.headerActionsVisible = function(node:RenderNode):Bool {
				var focused = harness.ui.focus.focusedId;
				return node.states.contains(StyleState.Hovered) || (focused != null && node.find(focused) != null);
			};
			return [view];
		});
		var root = harness.submit();
		Report.check(7, "header actions start hidden", !actionsVisible(root), "visible=" + actionsVisible(root));

		var inside = Harness.first(root, AccessibilityRole.Button, "Inside");
		var bounds = inside.globalBounds();
		var builds = harness.rootBuilds;
		harness.ui.pointerMove(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
		root = harness.submit();
		var hoverBuilds = harness.rootBuilds - builds;
		Report.info(7, "hover over the pane: rootBuilds+=" + hoverBuilds + " actions visible=" + actionsVisible(root));
		Report.check(7, "hovering the pane shows the header actions in the next frame without requestFrame",
			actionsVisible(root), "visible=" + actionsVisible(root) + " rootBuilds+=" + hoverBuilds);

		builds = harness.rootBuilds;
		harness.ui.pointerLeave();
		root = harness.submit();
		Report.check(7, "leaving the pane hides them again", !actionsVisible(root),
			"visible=" + actionsVisible(root) + " rootBuilds+=" + (harness.rootBuilds - builds));

		builds = harness.rootBuilds;
		harness.ui.focusWidget(Harness.first(root, AccessibilityRole.Button, "Inside").id);
		root = harness.submit();
		Report.check(7, "focusing a control in the pane shows them in the next frame without requestFrame",
			actionsVisible(root), "visible=" + actionsVisible(root) + " rootBuilds+=" + (harness.rootBuilds - builds));

		builds = harness.rootBuilds;
		harness.ui.clearFocus();
		root = harness.submit();
		Report.check(7, "clearing focus hides them again", !actionsVisible(root),
			"visible=" + actionsVisible(root) + " rootBuilds+=" + (harness.rootBuilds - builds));

		var plain = harness.rootBuilds;
		harness.ui.pointerMove(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
		harness.submit();
		harness.ui.pointerLeave();
		harness.submit();
		Report.info(7, "hover in and out with the pane's own visuals only: rootBuilds+=" + (harness.rootBuilds - plain));
		harness.dispose();
	}

	static function actionsVisible(root:RenderNode):Bool return Harness.hasText(root, "ACTIONS");
}
