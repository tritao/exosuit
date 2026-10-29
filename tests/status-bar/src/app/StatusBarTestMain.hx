package app;

import haxeon.ui.LayoutFrame;
import haxeon.ui.Rect;
import haxeon.ui.TextLayout;
import haxeon.ui.TextWrap;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.semantics.AccessibilityRole;
import ui.StatusBarView;
import haxeon.ui.icons.IconName;
import plugin.PluginResourceDecorationColor;
import plugin.PluginResourceDecorationRegistry;
import plugin.PluginStatusRegistry;
import plugin.PluginStatusSide;

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

@:access(haxeon.ui.core.RenderNode)
class StatusBarTestMain {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }
	static function main():Int {
		var fonts = haxeon.ui.FontCollection.create();
		fonts.add("../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
		resourceDecorationRollup();
		resourceDecorationRendering(fonts);
		folderIconRendering(fonts);
		editorTabResourceDecoration(fonts);
		statusContributions(fonts);
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
				var toggles = 0, details = 0, dismissals = 0, connections = 0, indentations = 0;
				var view = new StatusBarView({
					document: document, status: status,
					indentation: "Spaces: 4", indentationDetails: "Spaces: 4 · Detected from document", openIndentation: function() indentations++,
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
					// The first child is the non-interactive painted top boundary, not a slot.
					for (child in root.children.slice(1)) {
						if (!child.layout.style.visible) continue;
						var bounds = child.globalBounds();
						require(bounds.x >= previousRight - 0.1 && bounds.x + bounds.width <= width + 0.1,
							"status slots overlap or escape at " + width + " remote=" + remote + " toast=" + toast + " unread=" + unread + ": " + bounds.x + "," + bounds.width + " slots=" + [for (slot in root.children) slot.globalBounds().x + "," + slot.globalBounds().width]);
						previousRight = bounds.x + bounds.width;
					}
					var bell:RenderNode = null, message:RenderNode = null, dismiss:RenderNode = null, connection:RenderNode = null, indentation:RenderNode = null;
					function visit(node:RenderNode):Void {
						if (node.styleType == "tooltip" || !node.layout.style.visible) return;
						var semantics = node.semantics;
						if (semantics != null && semantics.role == AccessibilityRole.Button && semantics.label == "Notifications, " + unread + " unread") bell = node;
						if (semantics != null && semantics.label == "Spaces: 4. Choose document indentation") indentation = node;
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
					require((indentation != null) == (width >= 480), "indentation control did not follow available width");
					require(bell != null && (message != null || width < 48), "status actions or full accessible message missing");
					var bellBounds = bell.globalBounds();
					require(bellBounds.width >= 28 && bellBounds.x + bellBounds.width <= width + 0.1, "notification action was clipped");
					context.pointerDown(bellBounds.x + bellBounds.width / 2, bellBounds.y + bellBounds.height / 2, 0);
					context.pointerUp(bellBounds.x + bellBounds.width / 2, bellBounds.y + bellBounds.height / 2, 0);
					if (width == 520) {
						for (action in [toast ? message : null, dismiss, connection, indentation]) if (action != null) {
							var bounds = action.globalBounds();
							context.pointerDown(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
							context.pointerUp(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
						}
						var bounds = message.globalBounds();
						context.pointerMove(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
						context.animations.advance(config.Settings.DEFAULT_TOOLTIP_DELAY + 0.1);
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
				require(indentations == 1, "indentation action became unreachable after resizing");
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

	static function resourceDecorationRollup():Void {
		var registry = new PluginResourceDecorationRegistry();
		registry.add("test-low", "modified", "C:/repo/src/old.hx", "M", Accent, "Modified", true, 10);
		registry.add("test-high", "added", "C:\\repo\\src\\new.hx", "A", Success, "Added", true, 20);
		var folder = registry.forPath("C:\\repo\\src");
		require(folder != null && folder.badge == "A" && folder.sourcePath == "C:/repo/src/new.hx" && folder.inherited,
			"folder roll-up did not choose the highest-priority descendant decoration");
		var revision = registry.revision;
		registry.removeOwner("test-high");
		folder = registry.forPath("C:/repo/src");
		require(registry.revision > revision && folder != null && folder.badge == "M",
			"owner cleanup did not recompute inherited folder decorations");
	}

	static function resourceDecorationRendering(fonts:haxeon.ui.FontCollection):Void {
		var theme = ui.ExosuitPalette.theme(true);
		var registry = new PluginResourceDecorationRegistry();
		registry.add("smoke", "modified", "C:/repo/src/old.hx", "M", Accent, "Modified", true, 10);
		registry.add("smoke", "added", "C:/repo/src/new.hx", "A", Success, "Added", true, 20);
		var model = new ui.DirectoryTreeModel("C:/repo", theme);
		model.setResourceDecorations(registry);
		var atlas = new ui.SetiIconAtlas();
		var context = new UiContext(null, fonts, theme);
		function row():RenderNode
			return context.submit(model.buildItemWithIcons("C:/repo/src", false, atlas, true), new LayoutFrame(500, 28));
		var root = row(), highestBadge = false, tintedName = false;
		root.walk(function(node) {
			if (node.layout.text == "A") highestBadge = true;
			if (node.layout.text == "src" && sameColor(node.layout.textColor, theme.tokens.success)) tintedName = true;
		});
		require(highestBadge && tintedName, "explorer row did not render the highest-priority child badge and tint");
		var before = model.revision();
		registry.removeOwner("smoke");
		root = row();
		var badgeRemains = false, restoredName = false;
		root.walk(function(node) {
			if (node.layout.text == "A" || node.layout.text == "M") badgeRemains = true;
			if (node.layout.text == "src" && sameColor(node.layout.textColor, theme.tokens.text)) restoredName = true;
		});
		require(model.revision() > before && !badgeRemains && restoredName,
			"explorer decoration did not clear its badge and tint after owner removal");
		model.dispose(); atlas.dispose(); context.dispose();
	}

	static function folderIconRendering(fonts:haxeon.ui.FontCollection):Void {
		for (dark in [false, true]) {
			var theme = ui.ExosuitPalette.theme(dark), context = new UiContext(null, fonts, theme);
			var atlas = new ui.SetiIconAtlas();
			var local = new ui.DirectoryTreeModel(Sys.getCwd(), theme);
			var remote = new ui.WorkspaceFileTreeModel(function() return null, "workspace", "root", "Project", theme, function() {});
			var models:Array<ui.ExplorerTreeModel> = [local, remote];
			var keys = [Sys.getCwd(), remote.rootKeyAt(0)];
			for (index in 0...models.length) for (width in [120.0, 320.0]) {
				var closed = context.submit(models[index].buildItemWithIcons(keys[index], false, atlas, dark), new LayoutFrame(width, 30));
				var icon = closed.children[0];
				require(!icon.hitTestSelf && icon.semantics == null && icon.globalBounds().width == 16, "Folder icon changed hit testing or size");
				var closedPaint = icon.paintCacheKeys[0];
				var opened = context.submit(models[index].buildItemWithIcons(keys[index], true, atlas, dark), new LayoutFrame(width, 30));
				require(opened.children[0].paintCacheKeys[0] != closedPaint, "Folder icon did not reflect expansion");
				require(opened.globalBounds().width <= width + 0.1, "Folder row overflowed its viewport");
			}
			var tree = new haxeon.ui.widgets.collections.TreeView("folder-rename-tree", local);
			var rename = new ui.ExplorerRename(Sys.getCwd(), true, function(_) return true, function(_) {}, function() {}, function(_) {});
			var renameRoot = context.submit(new ui.ExplorerTreeView(tree, local, dark, null, rename), new LayoutFrame(160, 160));
			var renameField:RenderNode = null;
			renameRoot.walk(function(node) { if (node.semantics != null && node.semantics.label == "Rename file or folder") renameField = node; });
			require(renameField != null && renameField.globalBounds().width > 20 && renameField.globalBounds().x + renameField.globalBounds().width <= 160.1,
				"Folder rename field was clipped by its icon");
			local.dispose(); remote.dispose(); context.dispose(); atlas.dispose();
		}
	}

	static function sameColor(a:Null<haxeon.ui.Color>, b:haxeon.ui.Color):Bool
		return a != null && a.red == b.red && a.green == b.green && a.blue == b.blue && a.alpha == b.alpha;

	static function editorTabResourceDecoration(fonts:haxeon.ui.FontCollection):Void {
		var theme = ui.ExosuitPalette.theme(true);
		var registry = new PluginResourceDecorationRegistry();
		registry.add("smoke", "new-file", "C:/repo/src/new.hx", "A", PluginResourceDecorationColor.Success,
			"Added", false, 10);
		var decoration = registry.forPath("C:/repo/src/new.hx");
		require(decoration != null, "resource decoration registry lost the editor-tab fixture");
		var colors = new Map<String, haxeon.ui.Color>();
		colors.set("new-file", ui.ResourceDecorationBadge.colorFor(decoration, theme));
		var item = new haxeon.ui.widgets.controls.TabItem("new-file", "new.hx",
			new haxeon.ui.widgets.text.Text("fixture"));
		var view = new ui.EditorTabsView(new haxeon.ui.widgets.controls.Tabs("resource-tabs", [item], item.key),
			new Map<String, String>(), true, 0.0, colors, registry.revision);
		var context = new UiContext(null, fonts, theme);
		var root = context.submit(view, new LayoutFrame(500, 120));
		var tintedTitle = false;
		root.walk(function(node) {
			if (node.layout.text == item.label && sameColor(node.layout.textColor, theme.tokens.success)) tintedTitle = true;
		});
		require(tintedTitle, "resource decoration color did not tint the editor tab title");
		context.dispose();
	}

	static function statusContributions(fonts:haxeon.ui.FontCollection):Void {
		var registry = new PluginStatusRegistry();
		var low = registry.add("scm", "low", "low", 5, Left, null, "Low priority", "scm:low");
		var high = registry.add("scm", "high", "main", 50, Left, IconName.Activity, "Current branch", "sidebar:scm");
		registry.add("other", "right", "build", 20, Right, null, "Build status", "build:open");
		var ordered = registry.items();
		require(ordered[0] == high && ordered[1].owner == "other" && ordered[2] == low,
			"status contributions were not ordered by descending priority");
		var context = new UiContext(null, fonts, ui.ExosuitPalette.theme(true));
		var commands:Array<String> = [];
		var view = new StatusBarView({
			document: "file.hx", status: "Haxe", remoteDetails: "", notification: null,
			notificationsVisible: false, unread: 0, viewport: function() return new Rect(0, 0, 1000, 600),
			openRemote: function() {}, showNotification: function(_) {}, dismissNotification: function() {},
			toggleNotifications: function() {}, items: ordered, runCommand: function(command) commands.push(command)
		});
		var root = context.submit(new StatusFixture(view), new LayoutFrame(1000, 200)).children[1];
		var highNode:RenderNode = null, lowNode:RenderNode = null;
		root.walk(function(node) {
			if (node.styleType != "button") return;
			if (node.styleKey == "status-item:scm:high") highNode = node;
			if (node.styleKey == "status-item:scm:low") lowNode = node;
		});
		require(highNode != null && lowNode != null && highNode.globalBounds().x < lowNode.globalBounds().x,
			"status bar did not render same-side items in priority order");
		var bounds = highNode.globalBounds();
		context.pointerDown(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
		context.pointerUp(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
		require(commands.length == 1 && commands[0] == "sidebar:scm",
			"status contribution command did not dispatch: " + commands.join(",") +
			" bounds=" + bounds.x + "," + bounds.y + "," + bounds.width + "," + bounds.height);
		var revision = registry.revision;
		registry.removeOwner("scm");
		require(registry.revision > revision && registry.items().length == 1,
			"status owner cleanup did not remove its items or advance the revision");
		context.dispose();
	}
}
