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
		Report.check(7, "hovering the pane alone causes no root build, so the header actions stay hidden (T19 holds)",
			!actionsVisible(root) && harness.rootBuilds == builds,
			"visible=" + actionsVisible(root) + " rootBuilds+=" + (harness.rootBuilds - builds));
		builds = harness.rootBuilds;
		harness.requestFrame();
		root = harness.submit();
		Report.check(7, "with requestFrame() after the hover, the full build shows them",
			actionsVisible(root), "visible=" + actionsVisible(root) + " rootBuilds+=" + (harness.rootBuilds - builds));
		harness.ui.pointerLeave();
		harness.requestFrame();
		root = harness.submit();
		Report.check(7, "leaving + requestFrame() hides them", !actionsVisible(root), "visible=" + actionsVisible(root));

		builds = harness.rootBuilds;
		harness.ui.focusWidget(Harness.first(root, AccessibilityRole.Button, "Inside").id);
		root = harness.submit();
		Report.check(7, "focusing a control in the pane alone causes no root build, so they stay hidden",
			!actionsVisible(root) && harness.rootBuilds == builds,
			"visible=" + actionsVisible(root) + " rootBuilds+=" + (harness.rootBuilds - builds));
		harness.requestFrame();
		root = harness.submit();
		Report.check(7, "with requestFrame() after the focus change, the full build shows them", actionsVisible(root),
			"visible=" + actionsVisible(root));
		harness.ui.clearFocus();
		harness.requestFrame();
		root = harness.submit();
		Report.check(7, "clearing focus + requestFrame() hides them", !actionsVisible(root), "visible=" + actionsVisible(root));
		harness.dispose();
	}

	static function actionsVisible(root:RenderNode):Bool return Harness.hasText(root, "ACTIONS");
}
