package app;

import ui.TabHoverDelay;
import ui.TabTooltip;
import haxeon.ui.Rect;
import haxeon.ui.animation.AnimationScheduler;
import config.Settings;

private class NarrowTooltipFixture implements haxeon.ui.core.View {
	final placement:haxeon.ui.widgets.overlays.TooltipPlacement;
	public function new(placement:haxeon.ui.widgets.overlays.TooltipPlacement = Below) this.placement = placement;
	public function build(context:haxeon.ui.core.BuildContext):haxeon.ui.core.RenderNode {
		var anchorStyle = new haxeon.ui.LayoutStyle();
		anchorStyle.width = haxeon.ui.LayoutAxis.fixed(24);
		anchorStyle.height = haxeon.ui.LayoutAxis.fixed(24);
		var group = new ui.TooltipHoverGroup(context.animations, function(_) {}, 0);
		return new TabTooltip("narrow-tooltip", new haxeon.ui.widgets.text.Text("+", anchorStyle),
			new haxeon.ui.widgets.text.Text("Open", null, null,
				new haxeon.ui.core.TextStyleOverride(null, 13, null, haxeon.ui.TextWrap.WordCharacter)),
			function() return new Rect(0, 0, 800, 600), 0, placement, group, true).build(context);
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
	static function main():Int {
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
		var delay = new TabHoverDelay(scheduler, function(value) { visible = value; if (value) reveals++; });
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
		var viewport = new Rect(0, 0, 800, 600);
		var activity = TabTooltip.placeRight(new Rect(0, 80, 40, 40), 100, 30, viewport);
		require(activity.x == 48 && activity.y == 5, "activity tooltip must prefer right and center vertically");
		var edge = TabTooltip.placeRight(new Rect(760, 580, 40, 40), 100, 30, viewport);
		require(edge.x == -108 && 580 + edge.y + 30 <= 594, "right tooltip did not flip or clamp at viewport edges");
		var fonts = haxeon.ui.FontCollection.create();
		fonts.add(Sys.getCwd() + "/../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
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
		var clippedRoot = context.submit(new ClippedToolbarFixture(), new haxeon.ui.LayoutFrame(800, 600));
		var escapedTip:haxeon.ui.core.RenderNode = null;
		clippedRoot.walk(function(node) { if (node.styleType == "tooltip") escapedTip = node; });
		require(escapedTip != null && escapedTip.globalBounds().width > 40,
			"toolbar tooltip did not cross its clipped ancestor");
		var escapedGeometry:haxeon.ui.ResolvedLayoutItem = cast escapedTip.resolved;
		require(escapedGeometry.clipBounds.width == 800 && escapedGeometry.clipBounds.height == 600,
			"unclipped tooltip inherited sidebar clipping instead of viewport clipping");

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
		trace("PASS: tooltip timing and placement, text fit, ellipsis boundaries, and fractional editor measurement");
		return 0;
	}
}
