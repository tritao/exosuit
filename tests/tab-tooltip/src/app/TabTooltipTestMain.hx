package app;

import haxeon.ui.widgets.overlays.TooltipHoverDelay;
import ui.TabTooltip;
import haxeon.ui.Rect;
import haxeon.ui.animation.AnimationScheduler;
import config.Settings;

private class ExplorerInputModel implements haxeon.ui.widgets.collections.TreeViewModel {
	public function new() {}
	public function rootCount():Int return 2;
	public function rootRange(start:Int, count:Int):Array<haxeon.ui.widgets.collections.TreeRootMetadata>
		return [for (i in start...Std.int(Math.min(2, start + count))) new haxeon.ui.widgets.collections.TreeRootMetadata("file" + i)];
	public function rootKeyAt(index:Int):String return "file" + index;
	public function childCount(key:String):Int return 0;
	public function childKeyAt(key:String, index:Int):String return "";
	public function initiallyExpanded(key:String):Bool return false;
	public function estimatedExtent():Float return 24;
	public function extentIsUniform():Bool return true;
	public function extentAt(key:String):Float return 24;
	public function buildItem(key:String):haxeon.ui.core.View return new haxeon.ui.widgets.text.Text(key);
	public function revision():Int return 0;
}

private class ToolbarTooltipFixture implements haxeon.ui.core.View {
	final offset:Float;
	public function new(offset:Float) this.offset = offset;
	public function build(context:haxeon.ui.core.BuildContext):haxeon.ui.core.RenderNode {
		var style = new haxeon.ui.LayoutStyle();
		style.width = haxeon.ui.LayoutAxis.fixed(24);
		style.height = haxeon.ui.LayoutAxis.fixed(24);
		var anchor = new haxeon.ui.widgets.controls.Button("+", style, function() {}, "fixture-toolbar-button");
		var tooltip = new haxeon.ui.widgets.overlays.Tooltip("fixture-standard-tooltip", anchor,
			new haxeon.ui.widgets.text.Text("New Codex"), offset, 36);
		var container = new haxeon.ui.LayoutStyle();
		container.width = haxeon.ui.LayoutAxis.grow();
		container.height = haxeon.ui.LayoutAxis.grow();
		container.padding = new haxeon.ui.Insets(80, 40, 0, 0);
		return new haxeon.ui.widgets.layout.Column("toolbar-fixture",
			[new haxeon.ui.widgets.KeyedView("tooltip", tooltip)], container).build(context);
	}
}

private class TooltipTypographyFixture implements haxeon.ui.core.View {
	final standard:Bool;
	public function new(standard:Bool) this.standard = standard;
	public function build(context:haxeon.ui.core.BuildContext):haxeon.ui.core.RenderNode {
		var anchorStyle = new haxeon.ui.LayoutStyle();
		anchorStyle.width = haxeon.ui.LayoutAxis.fixed(32); anchorStyle.height = haxeon.ui.LayoutAxis.fixed(32);
		var anchor = new haxeon.ui.widgets.controls.Button("+", anchorStyle, null, "typography-trigger");
		var content = new haxeon.ui.widgets.layout.Column("typography-content", [
			new haxeon.ui.widgets.KeyedView("plain", new haxeon.ui.widgets.text.Text("Plain tooltip")),
			new haxeon.ui.widgets.KeyedView("wrapped", new haxeon.ui.widgets.text.Text("Wrapped tooltip", null, null,
				haxeon.ui.core.TextStyleOverride.paragraph(haxeon.ui.TextWrap.WordCharacter))),
			new haxeon.ui.widgets.KeyedView("rich", new haxeon.ui.widgets.text.Text("Rich tooltip", null, null,
				haxeon.ui.core.TextStyleOverride.text(17)))
		]);
		var tooltip:haxeon.ui.core.View;
		if (standard) tooltip = new haxeon.ui.widgets.overlays.Tooltip("typography-tooltip", anchor, content, 0, 36);
		else tooltip = new TabTooltip("typography-tab-tooltip", anchor, content,
			function() return new Rect(0, 0, context.viewportWidth, context.viewportHeight), 0,
			Below, new haxeon.ui.widgets.overlays.TooltipHoverGroup(context.animations, function(_) {}, 0), true);
		return new haxeon.ui.widgets.layout.Column("typography-fixture", [
			new haxeon.ui.widgets.KeyedView("outside", new haxeon.ui.widgets.text.Text("Outside text")),
			new haxeon.ui.widgets.KeyedView("tooltip", tooltip)
		]).build(context);
	}
}

private class NarrowTooltipFixture implements haxeon.ui.core.View {
	final placement:haxeon.ui.widgets.overlays.TooltipPlacement;
	final midpoint:Bool;
	public function new(placement:haxeon.ui.widgets.overlays.TooltipPlacement = Below, midpoint:Bool = false) {
		this.placement = placement; this.midpoint = midpoint;
	}
	public function build(context:haxeon.ui.core.BuildContext):haxeon.ui.core.RenderNode {
		var anchorStyle = new haxeon.ui.LayoutStyle();
		anchorStyle.width = haxeon.ui.LayoutAxis.fixed(24);
		anchorStyle.height = haxeon.ui.LayoutAxis.fixed(24);
		var group = new haxeon.ui.widgets.overlays.TooltipHoverGroup(context.animations, function(_) {}, 0);
		var tooltip = new TabTooltip("narrow-tooltip", new haxeon.ui.widgets.text.Text("+", anchorStyle),
			new haxeon.ui.widgets.text.Text("Open", null, null,
				new haxeon.ui.core.TextStyleOverride(null, 13, null, haxeon.ui.TextWrap.WordCharacter)),
			function() return new Rect(0, 0, 800, 600), 0, placement, group, true);
		tooltip.startAtAnchorMiddle = midpoint;
		return tooltip.build(context);
	}
}

private class ClippedToolbarFixture implements haxeon.ui.core.View {
	public function new() {}
	public function build(context:haxeon.ui.core.BuildContext):haxeon.ui.core.RenderNode {
		var style = new haxeon.ui.LayoutStyle();
		style.width = haxeon.ui.LayoutAxis.fixed(40);
		style.height = haxeon.ui.LayoutAxis.fixed(40);
		style.clipHorizontal = true;
		style.clipVertical = true;
		var root = new haxeon.ui.core.RenderNode(context.id("clipped-toolbar"), haxeon.ui.LayoutVisualKind.Box, style);
		root.add(new NarrowTooltipFixture().build(context));
		return root;
	}
}

private class EllipsisFixture implements haxeon.ui.core.View {
	public var width:Float;
	public var value:String;
	public var middle:Bool;
	public final label:haxeon.ui.widgets.text.MiddleEllipsisText;
	public function new(width:Float, value:String, middle:Bool, fontSize:Float) {
		this.width = width; this.value = value; this.middle = middle;
		label = new haxeon.ui.widgets.text.MiddleEllipsisText("boundary-label", value, middle,
			new haxeon.ui.core.TextStyleOverride(null, fontSize, null, haxeon.ui.TextWrap.None));
	}
	public function build(context:haxeon.ui.core.BuildContext):haxeon.ui.core.RenderNode {
		var style = new haxeon.ui.LayoutStyle();
		style.width = haxeon.ui.LayoutAxis.fixed(width);
		return new haxeon.ui.widgets.layout.Row("ellipsis-boundary", [new haxeon.ui.widgets.KeyedView("label", label)], style).build(context);
	}
}

private class FeedbackFixture implements haxeon.ui.core.View {
	public var passes:Int = 0;
	final changes:Int;
	public function new(changes:Int) this.changes = changes;
	public function build(context:haxeon.ui.core.BuildContext):haxeon.ui.core.RenderNode {
		var style = new haxeon.ui.LayoutStyle();
		style.width = haxeon.ui.LayoutAxis.fixed(20);
		style.height = haxeon.ui.LayoutAxis.fixed(20);
		var node = new haxeon.ui.core.RenderNode(context.id("feedback-fixture"), haxeon.ui.LayoutVisualKind.Box, style);
		node.onResolved(function(_) {
			passes++;
			if (changes < 0 || passes <= changes) {
				node.layout.style.width = haxeon.ui.LayoutAxis.fixed(20 + passes % 2);
				context.requestLayoutFeedback();
			}
		});
		return node;
	}
}

@:access(haxeon.ui.widgets.WindowFrame)
@:access(haxeon.ui.LayoutMeasureConstraints)

class TabTooltipTestMain {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }
	static function checkTooltipTypography(fonts:haxeon.ui.FontCollection):Void {
		for (dark in [false, true]) for (standard in [false, true]) for (size in [13.0, 15.0]) for (density in [1.0, 2.0]) {
			var theme = ui.ExosuitPalette.theme(dark);
			if (size != 13) theme.tokens.tooltipFontSize = size;
			var context = new haxeon.ui.core.UiContext(null, fonts, theme);
			context.buildContext.environment.pixelDensity = density;
			var fixture = new haxeon.ui.widgets.overlays.TooltipOverlayHost(new TooltipTypographyFixture(standard));
			var root = context.submit(fixture, new haxeon.ui.LayoutFrame(320, 240));
			var anchor:haxeon.ui.core.RenderNode = null;
			root.walk(function(node) { if (node.styleKey == "typography-trigger") anchor = node; });
			var bounds = anchor.globalBounds();
			context.pointerMove(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
			root = context.submit(fixture, new haxeon.ui.LayoutFrame(320, 240));
			var labels = 0;
			root.walk(function(node) {
				if (node.styleType == "tooltip") {
					var border = node.computedStyle.get(haxeon.ui.style.StyleProperty.BorderColor);
					require(border.red == theme.tokens.border.red && border.green == theme.tokens.border.green && border.blue == theme.tokens.border.blue,
						"tooltip border is not the subtle theme border");
				}
				if (node.layout.text == null) return;
				var expected = switch node.layout.text {
					case "Plain tooltip", "Wrapped tooltip": size;
					case "Rich tooltip": 17.0;
					case "Outside text": 16.0;
					case _: return;
				};
				require(node.layout.textStyle.fontSize == expected, "tooltip typography lost inheritance or an explicit override: " + node.layout.text + " actual=" + node.layout.textStyle.fontSize + " expected=" + expected + " standard=" + standard);
				labels++;
			});
			require(labels == 4, "tooltip typography fixture lost labels");
			context.dispose();
		}
	}

	static function sharedControlTiming():Void {
		var scheduler=new AnimationScheduler();
		var visible:Null<String>=null;
		var group=new haxeon.ui.widgets.overlays.TooltipHoverGroup(scheduler,function(key) visible=key,Settings.DEFAULT_TOOLTIP_DELAY);
		group.enter("terminal");scheduler.advance(0.4);
		require(visible==null,"Workbench control tooltip opened before the configured delay");
		group.leave("terminal");scheduler.advance(1);
		require(visible==null && scheduler.activeCount==0,"Passing over a control left a pending tooltip");
		group.enter("terminal");scheduler.advance(0.81);
		require(visible=="terminal","Deliberate hover did not reveal the control tooltip");
		group.leave("terminal");group.enter("agent");
		require(visible=="agent","Adjacent control restarted the delay after the group was warm");
		group.cancel();scheduler.advance(1);
		require(visible==null && scheduler.activeCount==0,"Click dismissal left a visible or pending tooltip");
		group.enter("actions");scheduler.advance(0.4);
		require(visible==null,"A click did not reset the group's initial delay");
		group.cancel();group.delaySeconds=1.2;
		group.enter("actions");scheduler.advance(0.9);
		require(visible==null,"Control tooltips ignored a customized delay");
		scheduler.advance(0.31);require(visible=="actions","Custom control tooltip delay never completed");
		group.cancel();group.delaySeconds=0;group.enter("terminal");
		require(visible=="terminal","Zero delay preference was not honored");
		group.cancel();group.delaySeconds=1.2;group.enter("agent");group.dispose();scheduler.advance(2);
		require(visible==null && scheduler.activeCount==0,"Unmounted controls left a hover timer running");
	}

	static function main():Int {
		sharedControlTiming();
		// Every rim point has one resize direction, including the wider corner
		// arms; inset controls remain client space even close to a corner.
		for (size in [[900, 600], [32, 24], [8, 8]]) {
			var regions = haxeon.ui.widgets.WindowFrame.resizeRegions(size[0], size[1]);
			for (y in 0...size[1]) for (x in 0...size[0]) {
				var count = 0;
				for (region in regions) {
					require(region.x >= 0 && region.y >= 0 && region.x + region.width <= size[0] && region.y + region.height <= size[1],
						"resize region escaped a small window");
					if (x >= region.x && y >= region.y && x < region.x + region.width && y < region.y + region.height) count++;
				}
				var rim = x < Math.min(6, size[0] / 2) || x >= size[0] - Math.min(6, size[0] / 2)
					|| y < Math.min(6, size[1] / 2) || y >= size[1] - Math.min(6, size[1] / 2);
				require(count == (rim ? 1 : 0), "resize rim has gaps, overlaps, or covers interior controls");
			}
		}
		var corners = haxeon.ui.widgets.WindowFrame.resizeRegions(900, 600);
		for (point in [[18, 2], [2, 18]]) {
			var diagonal = false;
			for (region in corners) if (point[0] >= region.x && point[1] >= region.y && point[0] < region.x + region.width && point[1] < region.y + region.height)
				diagonal = region.kind == nativekit.ffi.NativeKitTypes.WindowDecorationRegionKind.ResizeNorthwest;
			require(diagonal, "expanded corner arm did not select diagonal resize");
		}
		var scheduler = new AnimationScheduler();
		var visible = false;
		var reveals = 0;
		var delay = new TooltipHoverDelay(scheduler, function(value) { visible = value; if (value) reveals++; });
		delay.start(); scheduler.advance(0.4);
		require(!visible, "tooltip appeared before the delay");
		delay.cancel(); scheduler.advance(1);
		require(!visible && scheduler.activeCount == 0, "leaving a tab did not cancel its pending tooltip");
		delay.start(); scheduler.advance(0.4); delay.cancel(); delay.start(); scheduler.advance(0.5);
		require(!visible, "reentering reused the previous hover's elapsed time");
		scheduler.advance(0.31);
		require(visible && reveals == 1 && scheduler.activeCount == 0, "deliberate hover did not reveal exactly once");
		delay.cancel(); require(!visible, "click/leave did not hide visible tooltip");
		delay.delaySeconds = 0.2; delay.start(); scheduler.advance(0.21);
		require(visible, "configured delay was ignored");
		delay.cancel(); delay.start(); delay.dispose(); scheduler.advance(2); delay.start();
		require(!visible && scheduler.activeCount == 0 && reveals == 2, "removed tab retained or restarted its timer");
		var left = TabTooltip.place(-50, 40, 0, 400);
		require(left.x == 56 && left.y == 44, "clipped tab tooltip was not anchored inside the rail");
		var right = TabTooltip.place(390, 52, 0, 400);
		require(right.x + 390 + right.width + 20 <= 394 && right.y == 56, "tooltip ignored rail edge or tab height");
		var narrow = TabTooltip.place(20, 40, 20, 100);
		require(narrow.width == 68 && narrow.x == 6, "tooltip padding was not included in width clamping");
		var middle = TabTooltip.place(100, 40, 0, 800, 80, 100);
		require(middle.x == 80, "tooltip did not start at tab midpoint when space was available");
		var middleEdge = TabTooltip.place(700, 40, 0, 800, 60, 180);
		require(middleEdge.x == -86, "midpoint tooltip did not shift left to stay inside the rail");
		var viewport = new Rect(0, 0, 800, 600);
		var activity = TabTooltip.placeRight(new Rect(0, 80, 40, 40), 100, 30, viewport);
		require(activity.x == 48 && activity.y == 5, "activity tooltip must prefer right and center vertically");
		var edge = TabTooltip.placeRight(new Rect(760, 580, 40, 40), 100, 30, viewport);
		require(edge.x == -108 && 580 + edge.y + 30 <= 594, "right tooltip did not flip or clamp at viewport edges");
		var fonts = haxeon.ui.FontCollection.create();
		fonts.add(Sys.getCwd() + "/../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
		checkTooltipTypography(fonts);
		var session = haxeon.ui.LayoutSession.create();
		var context = new haxeon.ui.core.UiContext(session, fonts, ui.ExosuitPalette.theme(false));
		var fixture = new NarrowTooltipFixture();
		var root:haxeon.ui.core.RenderNode = null;
		for (_ in 0...4) root = context.submit(fixture, new haxeon.ui.LayoutFrame(800, 600));
		var open:haxeon.ui.core.RenderNode = null;
		root.walk(function(node) { if (node.layout.text == "Open") open = node; });
		var paintedTooltip = false;
		root.walk(function(node) {
			if (node.styleType != "tooltip") return;
			require(node.layout.visualKind == haxeon.ui.LayoutVisualKind.Custom,
				"tooltip surface cannot host its themed paint decorations");
			var decorations = node.computedStyle.get(haxeon.ui.style.StyleProperty.Decorations);
			require(decorations != null && decorations.decorations.length == 2
				&& decorations.decorations[1].kind == haxeon.ui.style.DecorationKind.Border,
				"tooltip theme did not attach a painted border");
			var effects = node.computedStyle.get(haxeon.ui.style.StyleProperty.Effects);
			require(effects != null && effects.effects.length == 1
				&& effects.effects[0].kind == haxeon.ui.style.EffectKind.DropShadow,
				"tooltip theme did not attach a painted drop shadow");
			paintedTooltip = true;
		});
		require(paintedTooltip, "tooltip fixture did not build a styled tooltip");
		require(open != null && open.globalBounds().width > 25 && open.globalBounds().height < 25,
			"short tooltip wrapped to its narrow anchor: " + (open == null ? "missing" : open.globalBounds().width + " x " + open.globalBounds().height));
		var midpointRoot = context.submit(new haxeon.ui.widgets.overlays.TooltipOverlayHost(new NarrowTooltipFixture(Below, true)),
			new haxeon.ui.LayoutFrame(800, 600));
		var midpointTip:haxeon.ui.core.RenderNode = null;
		midpointRoot.walk(function(node) { if (node.styleType == "tooltip") midpointTip = node; });
		require(midpointTip != null && midpointTip.globalBounds().x == 12,
			"lifted tooltip did not resolve at the 24px anchor midpoint");
		var clippedRoot = context.submit(new ClippedToolbarFixture(), new haxeon.ui.LayoutFrame(800, 600));
		var escapedTip:haxeon.ui.core.RenderNode = null;
		clippedRoot.walk(function(node) { if (node.styleType == "tooltip") escapedTip = node; });
		require(escapedTip != null && escapedTip.globalBounds().width > 40,
			"toolbar tooltip did not cross its clipped ancestor");
		var escapedGeometry:haxeon.ui.ResolvedLayoutItem = cast escapedTip.resolved;
		require(escapedGeometry.clipBounds.width == 800 && escapedGeometry.clipBounds.height == 600,
			"unclipped tooltip inherited sidebar clipping instead of viewport clipping");

		var overlayFixture = new haxeon.ui.widgets.overlays.TooltipOverlayHost(new ClippedToolbarFixture());
		for (_ in 0...3) {
			var overlayRoot = context.submit(overlayFixture, new haxeon.ui.LayoutFrame(800, 600));
			var liftedTip:haxeon.ui.core.RenderNode = null;
			overlayRoot.walk(function(node) { if (node.styleType == "tooltip") liftedTip = node; });
			require(liftedTip != null && liftedTip.parent == overlayRoot,
				"tooltip remained inside the clipped toolbar stacking context");
			require(liftedTip.globalBounds().y >= 28 && liftedTip.globalBounds().x >= 6,
				"lifted tooltip lost its anchor placement");
		}

		for (offset in [-32.0, -200.0, 900.0]) {
			var toolbarFixture = new haxeon.ui.widgets.overlays.TooltipOverlayHost(new ToolbarTooltipFixture(offset));
			context.submit(toolbarFixture, new haxeon.ui.LayoutFrame(800, 600));
			context.pointerMove(90, 50);
			var toolbarRoot = context.submit(toolbarFixture, new haxeon.ui.LayoutFrame(800, 600));
			var toolbarTip:haxeon.ui.core.RenderNode = null;
			toolbarRoot.walk(function(node) { if (node.styleType == "tooltip") toolbarTip = node; });
			require(toolbarTip != null && toolbarTip.layout.style.visible, "toolbar tooltip did not open on hover");
			var tipBounds = toolbarTip.globalBounds();
			require(tipBounds.x >= 6 && tipBounds.x + tipBounds.width <= 794 && tipBounds.y == 76,
				"lifted toolbar tooltip lost its anchor or escaped the window");
			if (offset == -32) require(tipBounds.x == 48, "toolbar tooltip used window coordinates for an anchor offset");
			context.pointerMove(790, 590);
		}

		var sideRoot = context.submit(new NarrowTooltipFixture(Right), new haxeon.ui.LayoutFrame(800, 600));
		var sideTip:haxeon.ui.core.RenderNode = null;
		sideRoot.walk(function(node) { if (node.styleType == "tooltip") sideTip = node; });
		require(sideTip != null && sideTip.globalBounds().x >= 32,
			"right tooltip resolved below its anchor: " + (sideTip == null ? "missing" : Std.string(sideTip.globalBounds().x)));
		for (fontSize in [11.0, 13.0, 13.5, 17.25]) {
			var style = new haxeon.ui.TextStyle(fontSize);
			var paragraph = new haxeon.ui.ParagraphStyle(haxeon.ui.TextWrap.None);
			var layout = haxeon.ui.TextLayout.createStyled(fonts, "Open", 10000, style, paragraph);
			var fullWidth = layout.measure().width;
			for (middle in [false, true]) {
				for (available in [fullWidth + 0.5, fullWidth, fullWidth - 0.5, 1.0, 0.0]) {
					var ellipsis = new EllipsisFixture(available, "Open", middle, fontSize);
					for (_ in 0...4) root = context.submit(ellipsis, new haxeon.ui.LayoutFrame(800, 600));
					var shown = "";
					root.walk(function(node) { if (node.layout.text != null) shown = node.layout.text; });
					require(ellipsis.label.truncated == (available < fullWidth), "ellipsis ignored subpixel overflow");
					layout.setText(shown);
					require(layout.measure().width <= available + 0.0001, "ellipsis itself exceeded available width");
					if (available <= 1) require(shown == "", "unfittable ellipsis must not paint a clipped marker");
				}
			}
			layout.dispose();
			var editor = new haxeon.ui.widgets.text.TextEditorLayout(fonts, "Open", 200.5, style, paragraph);
			var metrics = editor.measure();
			require(editor.hitTest(0, metrics.height + 40).offset == 4 && editor.hitTest(100, metrics.height + 40).offset == 4,
				"blank space below document must hit its end independently of x");
			require(editor.hitTest(0, metrics.height / 2).offset == 0,
				"document-end clamping changed hit testing inside the last line");
			var measured = editor.measureForConstraints(new haxeon.ui.LayoutMeasureConstraints(0, 200.5, 0, 100));
			require(measured.width == metrics.width && measured.height == metrics.height,
				"editor measurement changed fractional shaping geometry");
			var bounded = editor.measureForConstraints(new haxeon.ui.LayoutMeasureConstraints(0, 10.5, 0, 8.5));
			require(bounded.width <= 10.5 && bounded.height <= 8.5, "editor measurement exceeded hard constraints");
			editor.dispose();
		}
		var treeStyle = new haxeon.ui.LayoutStyle();
		treeStyle.width = haxeon.ui.LayoutAxis.fixed(200);
		treeStyle.height = haxeon.ui.LayoutAxis.fixed(150);
		var tree = new haxeon.ui.widgets.collections.TreeView("focus-tree", new ExplorerInputModel(), treeStyle);
		var treeFocused = false;
		var commands:Array<String> = [];
		tree.onItemClicked = function(_, _) { /* Preview presentation preserves focus. */ };
		var treeInput = new ui.ExplorerTreeInput(tree, function() { treeFocused = true; }, function(command) { commands.push(command); });
		var treeRoot = context.submit(treeInput, new haxeon.ui.LayoutFrame(800, 600));
		var row:haxeon.ui.core.RenderNode = null;
		treeRoot.walk(function(node) {
			if (node.semantics != null && node.semantics.role == haxeon.ui.semantics.AccessibilityRole.TreeItem && node.semantics.label == "file0") row = node;
		});
		require(row != null, "missing explorer fixture row");
		var rowBounds = row.globalBounds();
		context.pointerDown(rowBounds.x + 50, rowBounds.y + 12, 0);
		context.pointerUp(rowBounds.x + 50, rowBounds.y + 12, 0);
		context.submit(treeInput, new haxeon.ui.LayoutFrame(800, 600));
		require(treeFocused, "preview click retained editor command focus");
		context.key(haxeon.ui.core.UiEventKind.KeyDown, haxeon.ui.core.UiKey.Delete);
		context.key(haxeon.ui.core.UiEventKind.KeyDown, haxeon.ui.core.UiKey.F2);
		require(commands.join(",") == "file:delete,file:rename", "explorer file operation keys escaped the tree");
		context.key(haxeon.ui.core.UiEventKind.KeyDown, haxeon.ui.core.UiKey.Down);
		require(tree.selectedKey == "file1", "explorer arrow navigation lost keyboard focus");

		var feedback = new FeedbackFixture(3);
		context.submit(feedback, new haxeon.ui.LayoutFrame(800, 600));
		require(feedback.passes == 4, "layout published a frame before dependent geometry settled");
		var rejected = false;
		try context.submit(new FeedbackFixture(-1), new haxeon.ui.LayoutFrame(800, 600))
		catch (error:Dynamic) rejected = Std.string(error).indexOf("did not converge") >= 0;
		require(rejected, "oscillating layout feedback was silently discarded");
		context.dispose(); session.dispose(); fonts.dispose();
		var settings = new Settings(); settings.tabTooltipDelay = 1.2;
		require(settings.copy().tabTooltipDelay == 1.2, "settings copy lost tooltip delay");
		trace("PASS: shared tooltip typography, inheritance and overrides; tooltip timing/placement, text fit and fractional measurement");
		return 0;
	}
}
