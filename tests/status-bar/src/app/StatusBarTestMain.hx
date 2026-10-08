package app;

import haxeon.ui.LayoutFrame;
import haxeon.ui.Rect;
import haxeon.ui.TextLayout;
import haxeon.ui.TextWrap;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.semantics.AccessibilityRole;
import ui.StatusBarView;

private class StatusFixture implements haxeon.ui.core.View {
	public var width:Float = 1000;
	final view:haxeon.ui.core.View;
	public function new(view:haxeon.ui.core.View) this.view = view;
	public function build(context:haxeon.ui.core.BuildContext):RenderNode {
		var style = new haxeon.ui.LayoutStyle();
		style.width = haxeon.ui.LayoutAxis.fixed(width); style.height = haxeon.ui.LayoutAxis.fixed(200);
		var root = new RenderNode(context.id("status-fixture"), haxeon.ui.LayoutVisualKind.Box, style);
		var spaceStyle = new haxeon.ui.LayoutStyle(); spaceStyle.height = haxeon.ui.LayoutAxis.grow();
		root.add(new RenderNode(context.id("status-fixture-space"), haxeon.ui.LayoutVisualKind.Box, spaceStyle));
		root.add(view.build(context));
		return root;
	}
}

class StatusBarTestMain {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }
	static function main():Int {
		var fonts = haxeon.ui.FontCollection.create();
		fonts.add("../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
		var status = "Haxeon: disabled after repeated failures";
		var document = "a-very-long-document-name-with-Unicode-日本語.hx * - UTF-8";
		for (dark in [false, true]) {
			var context = new UiContext(null, fonts, ui.ExosuitPalette.theme(dark));
			var ellipsis = new haxeon.ui.widgets.text.MiddleEllipsisText("single-line-regression", status, false,
				haxeon.ui.core.TextStyleOverride.text(12));
			var ellipsisRoot = context.submit(ellipsis, new LayoutFrame(70, 26));
			require(ellipsisRoot.layout.paragraphStyle.wrap == TextWrap.None && ellipsisRoot.layout.text != status,
				"font-only override or first-frame ellipsis allowed an overflowing message");
			for (remote in [false, true]) for (toast in [false, true]) for (unread in [0, 100]) {
				var center = new feedback.NotificationCenter();
				var notice = center.publish("A long notification with 日本語 and multiple lines\nFull details remain available", Error);
				var toggles = 0, details = 0, dismissals = 0, connections = 0;
				var view = new StatusBarView({
					document: document, status: status,
					remoteDetails: remote ? "Remote workspace · Connected\n/home/example/project" : "",
					notification: toast ? notice : null, notificationsVisible: false, unread: unread,
					viewport: function() return new Rect(0, 0, 1000, 600),
					openRemote: function() connections++, showNotification: function(_) details++,
					dismissNotification: function() dismissals++, toggleNotifications: function() toggles++
				});
				var fixture = new StatusFixture(new haxeon.ui.core.RetainedView("retained-status", function(_) return view, function() return remote + ":" + toast + ":" + unread));
				for (width in [180.0, 64.0, 120.0, 320.0, 1000.0, 520.0, 280.0, 32.0]) {
					fixture.width = width;
					var root = context.submit(fixture, new LayoutFrame(1000, 200)).children[1];
					require(root.globalBounds().height == 26, "status bar changed height");
					var previousRight = 0.0;
					for (child in root.children) {
						if (!child.layout.style.visible) continue;
						var bounds = child.globalBounds();
						require(bounds.x >= previousRight - 0.1 && bounds.x + bounds.width <= width + 0.1,
							"status slots overlap or escape at " + width + " remote=" + remote + " toast=" + toast + " unread=" + unread + ": " + bounds.x + "," + bounds.width + " slots=" + [for (slot in root.children) slot.globalBounds().x + "," + slot.globalBounds().width]);
						previousRight = bounds.x + bounds.width;
					}
					var bell:RenderNode = null, message:RenderNode = null, dismiss:RenderNode = null, connection:RenderNode = null;
					function visit(node:RenderNode):Void {
						if (node.styleType == "tooltip" || !node.layout.style.visible) return;
						var semantics = node.semantics;
						if (semantics != null && semantics.role == AccessibilityRole.Button && semantics.label == "Notifications, " + unread + " unread") bell = node;
						if (semantics != null && semantics.label == "Hide notification") dismiss = node;
						if (semantics != null && semantics.role == AccessibilityRole.Button && semantics.label.indexOf("Open Remote Access") >= 0) connection = node;
						if (semantics != null && semantics.label == (toast ? "Show notification details: " + notice.message : status)) message = node;
						if (node.layout.text != null && node.layout.text.length > 0) {
							require(node.layout.paragraphStyle.wrap == TextWrap.None, "status text may wrap: " + node.layout.text);
							var layout = TextLayout.createStyled(fonts, node.layout.text, 100000, node.layout.textStyle, node.layout.paragraphStyle);
							var measured = layout.measure(); layout.dispose();
							require(measured.height <= 22.1, "status text broke onto another line");
							var geometry:haxeon.ui.ResolvedLayoutItem = cast node.resolved;
							require(measured.width <= geometry.width + 0.1, "status label paints beyond allocated width at " + width);
						}
						for (child in node.children) visit(child);
					}
					visit(root);
					require(bell != null && (message != null || width < 48), "status actions or full accessible message missing");
					var bellBounds = bell.globalBounds();
					require(bellBounds.width >= 28 && bellBounds.x + bellBounds.width <= width + 0.1, "notification action was clipped");
					context.pointerDown(bellBounds.x + bellBounds.width / 2, bellBounds.y + bellBounds.height / 2, 0);
					context.pointerUp(bellBounds.x + bellBounds.width / 2, bellBounds.y + bellBounds.height / 2, 0);
					if (width == 520) {
						for (action in [toast ? message : null, dismiss, connection]) if (action != null) {
							var bounds = action.globalBounds();
							context.pointerDown(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
							context.pointerUp(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
						}
						var bounds = message.globalBounds();
						context.pointerMove(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
						context.animations.advance(0.6);
						root = context.submit(fixture, new LayoutFrame(1000, 200)).children[1];
						var fullTip = false;
						root.walk(function(node) {
							if (node.styleType != "tooltip" || !node.layout.style.visible) return;
							var geometry:haxeon.ui.ResolvedLayoutItem = cast node.resolved;
							require(geometry.clipBounds.y < root.globalBounds().y && geometry.clipBounds.height > 26,
								"status tooltip was clipped to the status line");
							node.walk(function(text) { if (text.layout.text == (toast ? notice.message : status)) fullTip = true; });
						});
						require(fullTip, "full status text was not available on hover");
					}
				}
				require(toggles == 8, "notification button became unreachable after resizing");
				require(details == (toast ? 1 : 0) && dismissals == (toast ? 1 : 0) && connections == (remote ? 1 : 0),
					"message, dismiss, or remote action became unreachable");
			}
			context.dispose();
		}
		fonts.dispose();
		trace("PASS: fixed-height status bar, bounded single-line labels, responsive priorities, and reachable actions in both themes");
		return 0;
	}
}
